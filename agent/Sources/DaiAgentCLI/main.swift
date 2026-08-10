import DaiAgent
import DaiWorker
import Foundation

// Line buffering, because stdout to a file is block buffered by default and the
// daemon's log stayed empty for the first 4 KB. A log that appears only in
// arrears is worse than no log: the first thing anyone does when a machine
// misbehaves is look at it, and finding it empty says the agent never ran.
setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

// Subcommands while the port proceeds. `presence` is the one worth having first:
// if presence is wrong, everything downstream is wrong in a way that disturbs
// somebody.
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "presence"

func fmt(_ v: TimeInterval?) -> String { v.map { String(format: "%.1f", $0) } ?? "unreadable" }

switch command {
case "verify-mlx-child":
    // Runs in a child process so that an MLX abort cannot take the agent with
    // it. Not meant to be called directly.
    exit(MLXProbe.runChild())

case "pause":
    // No arguments, no privilege, no control plane. Someone reaching for this
    // is already annoyed; anything else to get right first is a failure.
    do {
        let reason = args.count > 2 ? args[2...].joined(separator: " ") : nil
        try PauseSwitch().pause(reason: reason)
        print("Paused. Nothing will run on this machine until you resume.")
        print("The fleet will be told within a few seconds, and cannot override it.")
        print("Resume with: dai-agent resume")
    } catch { print("could not pause: \(error)"); exit(1) }

case "resume":
    do {
        try PauseSwitch().resume()
        print("Resumed. Work may run again when nobody is using this machine.")
    } catch { print("could not resume: \(error)"); exit(1) }

case "preflight":
    // Whether this machine can run the agent at all. Worth running as root too:
    // the daemon runs in session 0, which is a different enough context that
    // checking only the interactive case proves less than it looks like.
    exit(await Preflight.run())

case "presence":
    if PauseSwitch().read().paused {
        print("PAUSED by the machine owner - nothing will run here until `dai-agent resume`")
    }
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

    // Where the time goes, since "slow" and "slow at inference" are different
    // problems with different fixes.
    if let b = try? await runtime.benchmark() {
        print(String(format: "  input shape     %@ (%d floats)",
                     b.shape.map(String.init).joined(separator: "x"),
                     b.shape.reduce(1, *)))
        print(String(format: "  prepare input   %.1f ms", b.fill * 1000))
        print(String(format: "  predict         %.1f ms", b.predict * 1000))
        print(String(format: "  ceiling         %.1f items/s", 1 / (b.fill + b.predict)))
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
        // Checked out of process, because a missing Metal shader library is a
        // C++ abort rather than an error: probing it in-process would take the
        // agent down and stop the ANE work that does not need MLX at all.
        var gpu: MLXRuntime?
        if MLXProbe.isAvailable() {
            gpu = MLXRuntime(modelId: args[3])
        } else {
            print("no GPU runtime on this machine; running ANE work only "
                + "(xcodebuild -downloadComponent MetalToolchain enables GPU work)")
        }

        let seconds = args.count > 5 ? Double(args[5]) ?? .infinity : .infinity
        // 300s by default, and long on purpose: E4 showed a false "they have
        // gone" costs a model load and an immediate preemption. Overridable
        // because that wait makes the behaviour untestable by hand, and a test
        // constant left in the daemon path would quietly ship as the default.
        let promote = ProcessInfo.processInfo.environment["DAI_PROMOTE_SECONDS"]
            .flatMap(Double.init) ?? idlePromoteSeconds
        // One writer, fed by both loops: each was overwriting the other's view
        // of the same file, and the batch loop writes far more often, so a
        // machine answering requests reported "waiting for work" throughout.
        let status = StatusPublisher()
        let worker = Worker(controlPlane: cp, gpu: gpu, ane: ane,
                            status: status, promoteAfter: promote)

        // Batch and serving run side by side in one process, because a node
        // does both and they cannot share a loop: an interactive request must
        // not wait for a batch unit to finish, and a batch unit must not be
        // held behind a conversation. Keeping them in separate commands meant
        // installing the daemon quietly turned serving off, which is how a
        // machine ended up harvesting all day while reporting no chat model.
        if gpu != nil {
            let channel = ReverseChannel(controlPlane: cp, gpu: gpu,
                                         status: status, promoteAfter: promote)
            if let servedPolicy = try? await cp.fetchPolicy() {
                await channel.setPolicy(mergePolicy(local: defaultPolicy, served: servedPolicy))
            }
            // Both loops need to know: they share one runtime, and a loop that
            // thinks it must release the model will release it out from under
            // the other.
            if let me = try? await cp.whoami() {
                await channel.setCluster(me.isCluster)
                await worker.setCluster(me.isCluster)
            }
            Task { await channel.run(maxSeconds: seconds) }
        }

        await worker.run(maxSeconds: seconds)
        await cp.shutdown()
    } catch { print("worker failed: \(error)"); exit(1) }

case "generate":
    // Exercises the GPU runtime directly, outside the presence gate.
    //
    // Needed because generate work is only permitted in LOCKED and ABSENT, so
    // sitting at the machine makes it unreachable through the worker: the very
    // situation in which someone wants to know whether a node can serve it.
    // This answers "does this model run here" without waiting for the machine
    // to be free.
    guard args.count > 3 else {
        print("usage: dai-agent generate <model-id> <prompt> [max-tokens]"); exit(2)
    }
    guard MLXProbe.isAvailable() else {
        print("no GPU runtime: MLX cannot load its Metal shader library.")
        print("install it with: xcodebuild -downloadComponent MetalToolchain")
        exit(1)
    }
    do {
        let runtime = MLXRuntime(modelId: args[2])
        let loaded = try await runtime.load()
        print(String(format: "loaded in %.2fs, %.1f GB resident",
                     loaded, await runtime.residentGb))

        let maxTokens = args.count > 4 ? Int(args[4]) ?? 128 : 128
        let started = Date()
        let text = try await runtime.generate(prompt: args[3], maxTokens: maxTokens)
        let elapsed = Date().timeIntervalSince(started)
        print("---")
        print(text)
        print("---")
        // Roughly, since the token count is not returned. Enough to tell a
        // working GPU path from one that has silently fallen back.
        print(String(format: "%.2fs, ~%.1f tok/s (%.1f GB resident)",
                     elapsed, Double(text.split(separator: " ").count) / elapsed,
                     await runtime.residentGb))
        let freed = await runtime.unload()
        print(String(format: "released in %.0f ms", freed * 1000))
    } catch { print("generate failed: \(error)"); exit(1) }

case "lease-probe":
    // Asks the control plane for work of the given kinds and prints the answer.
    //
    // Read-only, and it cannot be used to run work a machine's presence
    // forbids: the server enforces that against its own copy of the state and
    // refuses regardless of what is asked for. It exists because "this node is
    // idle" had two indistinguishable causes, and telling them apart otherwise
    // meant locking the screen and waiting.
    guard args.count > 3 else {
        print("usage: dai-agent lease-probe <url> <kind[,kind]>"); exit(2)
    }
    do {
        let dir = Enroll.identityDir()
        let identity = try NodeIdentity.load(
            certificate: dir.appendingPathComponent("node.crt"),
            enclaveKey: Enroll.keyPath(dir))
        let ca = try String(contentsOf: dir.appendingPathComponent("ca.crt"), encoding: .utf8)
        let cp = try ControlPlane(base: URL(string: args[2])!, identity: identity, serverCAPEM: ca)
        let kinds = args[3].split(separator: ",").compactMap { WorkKind(rawValue: String($0)) }
        if let lease = try await cp.leaseWork(kinds: kinds) {
            print("leased \(lease.kind.rawValue) unit \(lease.unitId), \(lease.items.count) items")
            // Hand it straight back: this is a probe, not a worker.
            try await cp.report(unitId: lease.unitId, completed: [],
                                unfinished: lease.items, seconds: 0)
            print("returned it to the queue")
        } else {
            print("no work: \(await cp.lastLeaseReason ?? "unknown")")
        }
        await cp.shutdown()
    } catch { print("lease probe failed: \(error)"); exit(1) }

case "serve":
    // Holds the reverse channel open for interactive requests, alongside the
    // batch loop rather than inside it: a conversation must not wait for a
    // batch unit to finish, and folding them together would make interactive
    // latency depend on the batch size.
    guard args.count > 3 else {
        print("usage: dai-agent serve <url> <model-id> [seconds]"); exit(2)
    }
    do {
        let dir = Enroll.identityDir()
        let identity = try NodeIdentity.load(
            certificate: dir.appendingPathComponent("node.crt"),
            enclaveKey: Enroll.keyPath(dir))
        let ca = try String(contentsOf: dir.appendingPathComponent("ca.crt"), encoding: .utf8)
        let cp = try ControlPlane(base: URL(string: args[2])!, identity: identity, serverCAPEM: ca)

        guard MLXProbe.isAvailable() else {
            print("no GPU runtime: this node cannot serve completions."); exit(1)
        }
        let channel = ReverseChannel(controlPlane: cp, gpu: MLXRuntime(modelId: args[3]),
                                     promoteAfter: ProcessInfo.processInfo
                                        .environment["DAI_PROMOTE_SECONDS"]
                                        .flatMap(Double.init) ?? idlePromoteSeconds)
        if let served = try? await cp.fetchPolicy() {
            await channel.setPolicy(mergePolicy(local: defaultPolicy, served: served))
        }
        if let me = try? await cp.whoami() {
            await channel.setCluster(me.isCluster)
            print("serving as \(me.hostname) (\(me.tier) tier)"
                + (me.isCluster
                   ? ": never preempted, so presence does not gate this node"
                   : ": harvested, so this node only serves when nobody is using it"))
        }
        let seconds = args.count > 4 ? Double(args[4]) ?? .infinity : .infinity
        await channel.run(maxSeconds: seconds)
        print("serve command finished after \(seconds)s")
        await cp.shutdown()
    } catch { print("serve failed: \(error)"); exit(1) }

case "qos":
    // Demonstrates the control that E1 measured at 2.4x on sustained work and
    // the worker at ~26x on bursty work.
    print("enter background: \(ProcessQoS.setBackground(true))")
    print("leave background: \(ProcessQoS.setBackground(false))")

default:
    print("usage: dai-agent [pause|resume|preflight|presence|verify-ane <model>|generate|enroll|status|timing|lease-probe|work|serve|qos]")
    exit(2)
}
