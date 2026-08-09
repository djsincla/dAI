import DaiAgent
import DaiWorker
import Foundation

// Subcommands while the port proceeds. `presence` is the one worth having first:
// if presence is wrong, everything downstream is wrong in a way that disturbs
// somebody.
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "presence"

func fmt(_ v: TimeInterval?) -> String { v.map { String(format: "%.1f", $0) } ?? "unreadable" }

switch command {
case "presence":
    let signals = MacSignalSource().read()
    let monitor = PresenceMonitor()
    let reading = monitor.update(signals, now: Date().timeIntervalSince1970)
    print("""
    presence   \(reading.state.rawValue)  (observed \(reading.observed.rawValue))
    hid idle   \(fmt(signals.hidIdleSeconds))s
    locked     \(signals.screenLocked.map(String.init(describing:)) ?? "unknown")
    console    \(signals.consoleUser ?? "nobody")
    ac power   \(signals.onACPower)
    thermal    \(signals.thermalOK ? "ok" : "pressure")
    policy     gpu=\(reading.policy.gpu) ane=\(reading.policy.ane) qos=\(reading.policy.qos.rawValue)
    limits     duty=\(reading.policy.dutyMax) mem=\(reading.policy.memFrac) maxTokens=\(reading.policy.maxCompletionTokens)
    permits    \(permittedKinds(reading.state, policy: reading.policy).map(\.rawValue).joined(separator: ", "))
    """)

case "verify-ane":
    // Placement verification is the safety property, so it gets its own command:
    // Core ML falls back to CPU silently, and a model that is not ANE-resident
    // would disturb the very user this runtime exists to avoid.
    guard args.count > 2 else {
        print("usage: dai-agent verify-ane <model.mlpackage>"); exit(2)
    }
    let url = URL(fileURLWithPath: args[2])
    let runtime = ANERuntime(modelURL: url)
    do {
        let seconds = try await runtime.load()
        guard let p = await runtime.placement else { print("no placement"); exit(1) }
        print(String(format: "loaded in %.2fs", seconds))
        for (device, n) in p.devices.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-34s %4d ops  (%.0f%%)",
                         (device as NSString).utf8String!, n,
                         Double(n) / Double(p.totalOps) * 100))
        }
        print(String(format: "ANE share: %.0f%% of %d compute ops", p.aneShare * 100, p.totalOps))
        print("VERDICT: ANE-resident. Safe to run while someone is using the machine.")
    } catch {
        print("REFUSED: \(error)")
        exit(1)
    }

case "enroll":
    // usage: dai-agent enroll <control-plane-url> <join-token> [server-ca.pem] [waitSeconds]
    guard args.count > 3 else {
        print("usage: dai-agent enroll <url> <join-token> [server-ca.pem] [wait-seconds]")
        exit(2)
    }
    let url = URL(string: args[2])!
    let ca = args.count > 4 && !args[4].isEmpty ? args[4] : nil
    let wait = args.count > 5 ? Double(args[5]) ?? 0 : 0
    do { try await Enroll.run(controlPlane: url, joinToken: args[3], caPath: ca, waitSeconds: wait) }
    catch { print("enrollment failed: \(error)"); exit(1) }

case "timing":
    // Written to find where a 61s stall was going, which turned out to be a
    // keychain prompt nobody could answer. Kept because "the request timed out"
    // points at the network, and the phase breakdown is what showed it was not.
    guard args.count > 2 else { print("usage: dai-agent timing <url>"); exit(2) }
    let dir0 = Enroll.identityDir()
    var t = Date()
    let id0 = try? NodeIdentity.load(certificate: dir0.appendingPathComponent("node.crt"),
                                     enclaveKey: Enroll.keyPath(dir0))
    print(String(format: "identity load: %.2fs (ok=%@)", Date().timeIntervalSince(t),
                 id0 != nil ? "yes" : "no"))
    t = Date()
    let ca0 = try? String(contentsOf: dir0.appendingPathComponent("ca.crt"), encoding: .utf8)
    print(String(format: "ca load:       %.2fs (ok=%@)", Date().timeIntervalSince(t),
                 ca0 != nil ? "yes" : "no"))
    t = Date()
    guard let cp0 = try? ControlPlane(base: URL(string: args[2])!,
                                      identity: id0, serverCAPEM: ca0) else {
        print("client init failed"); exit(1)
    }
    print(String(format: "client init:   %.2fs", Date().timeIntervalSince(t)))

    // Server trust only, no client certificate: separates "TLS and HTTP work"
    // from "the mutual-auth path works".
    t = Date()
    if let anon = try? ControlPlane(base: URL(string: args[2])!,
                                    identity: nil, serverCAPEM: ca0) {
        do {
            let ok = try await anon.healthz()
            print(String(format: "healthz:       %.2fs %@", Date().timeIntervalSince(t), ok))
        } catch {
            print(String(format: "healthz:       %.2fs FAILED %@",
                         Date().timeIntervalSince(t), String(describing: error)))
        }
        await anon.shutdown()
    }

    t = Date()
    do {
        _ = try await cp0.fetchPolicy()
        print(String(format: "fetchPolicy:   %.2fs OK", Date().timeIntervalSince(t)))
    } catch {
        print(String(format: "fetchPolicy:   %.2fs FAILED %@",
                     Date().timeIntervalSince(t), String(describing: error)))
    }
    await cp0.shutdown()

case "status":
    // Proves the identity works: fetches policy over mTLS and merges it with the
    // local table, taking the stricter of the two.
    guard args.count > 2 else { print("usage: dai-agent status <url>"); exit(2) }
    let dir = Enroll.identityDir()
    do {
        let identity = try NodeIdentity.load(
            certificate: dir.appendingPathComponent("node.crt"),
            enclaveKey: Enroll.keyPath(dir))
        let ca = try String(contentsOf: dir.appendingPathComponent("ca.crt"), encoding: .utf8)
        let cp = try ControlPlane(base: URL(string: args[2])!, identity: identity, serverCAPEM: ca)

        let served = try await cp.fetchPolicy()
        let merged = mergePolicy(local: defaultPolicy, served: served)
        print("authenticated by client certificate")
        print("served policy states: \(served.keys.map(\.rawValue).sorted().joined(separator: ", "))")
        for state in PresenceState.allCases {
            let p = merged[state]!
            print(String(format: "  %-8s gpu=%-5s ane=%-5s qos=%-10s duty=%.2f mem=%.2f",
                         (state.rawValue as NSString).utf8String!,
                         (String(p.gpu) as NSString).utf8String!,
                         (String(p.ane) as NSString).utf8String!,
                         (p.qos.rawValue as NSString).utf8String!, p.dutyMax, p.memFrac))
        }

        let signals = MacSignalSource().read()
        let monitor = PresenceMonitor()
        let reading = monitor.update(signals, now: Date().timeIntervalSince1970)
        try await cp.heartbeat(state: reading.state, onACPower: signals.onACPower,
                               thermalOK: signals.thermalOK)
        print("heartbeat sent: \(reading.state.rawValue)")
        await cp.shutdown()
    } catch { print("status failed: \(error)"); exit(1) }

case "work":
    // usage: dai-agent work <url> <model> [ane-model] [seconds]
    guard args.count > 3 else {
        print("usage: dai-agent work <url> <model-id> [ane-model.mlpackage] [seconds]"); exit(2)
    }
    let dir = Enroll.identityDir()
    do {
        let identity = try NodeIdentity.load(
            certificate: dir.appendingPathComponent("node.crt"),
            enclaveKey: Enroll.keyPath(dir))
        let ca = try String(contentsOf: dir.appendingPathComponent("ca.crt"), encoding: .utf8)
        let cp = try ControlPlane(base: URL(string: args[2])!, identity: identity, serverCAPEM: ca)

        var ane: ANERuntime?
        if args.count > 4, !args[4].isEmpty, args[4] != "-" {
            let runtime = ANERuntime(modelURL: URL(fileURLWithPath: args[4]))
            do {
                _ = try await runtime.load()
                if let p = await runtime.placement {
                    print(String(format: "ANE model loaded (%.0f%% of %d ops on ANE)",
                                 p.aneShare * 100, p.totalOps))
                }
                ane = runtime
            } catch {
                // Refuse rather than silently disturb the user from the CPU.
                print("ANE model REJECTED: \(error)")
            }
        }
        let seconds = args.count > 5 ? Double(args[5]) ?? .infinity : .infinity
        let worker = Worker(controlPlane: cp, gpu: MLXRuntime(modelId: args[3]),
                            ane: ane, promoteAfter: 15)
        await worker.run(maxSeconds: seconds)
        await cp.shutdown()
    } catch { print("worker failed: \(error)"); exit(1) }

case "qos":
    // Demonstrates the control that E1 measured at 2.4x on sustained work and
    // the worker at ~26x on bursty work.
    print("enter background: \(ProcessQoS.setBackground(true))")
    print("leave background: \(ProcessQoS.setBackground(false))")

default:
    print("usage: dai-agent [presence|verify-ane <model>|enroll|status|work|qos]")
    exit(2)
}
