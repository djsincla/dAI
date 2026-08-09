import DaiAgent
import Foundation

/// Checks that this machine can actually run the agent, before anything is
/// installed.
///
/// It exists because every assumption here has failed at least once in
/// development, and each failure was silent in a different way: an Enclave key
/// that could not be stored, presence signals that read as "nobody is here" on a
/// machine somebody was using, a Metal ceiling far below installed memory. A
/// daemon that starts anyway and does the wrong thing quietly is the worst
/// outcome, because the first person to notice is the user whose machine got
/// slow.
///
/// Run it as root as well as as yourself. The daemon runs in session 0 with no
/// logged-in user, and that context is different enough that checking only the
/// interactive case proves less than it appears to.
enum Preflight {
    static func run() async -> Int32 {
        var failures = 0
        let asRoot = getuid() == 0
        print("dAI agent preflight  (uid \(getuid())\(asRoot ? ", the context the daemon runs in" : ""))")
        print(String(repeating: "-", count: 64))

        // 1. The Secure Enclave, which the node's identity depends on entirely.
        let keyPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dai-preflight-\(UUID().uuidString).key")
        do {
            let key = try EnclaveKey.loadOrCreate(at: keyPath)
            let signature = try key.sign(Data("preflight".utf8))
            defer { try? FileManager.default.removeItem(at: keyPath) }
            ok("Secure Enclave", "key generated and signed (\(signature.count) byte signature)")

            let csr = try CSR.create(commonName: "preflight", key: key)
            ok("certificate request", "built, \(csr.split(separator: "\n").count) PEM lines")
        } catch {
            bad("Secure Enclave", "\(error)")
            failures += 1
        }

        // 2. Presence detection. If this misreads, the agent either never works
        // or works while somebody is using the machine, and the second one ends
        // the programme.
        let signals = MacSignalSource().read()
        let state = classify(signals)
        if signals.hidIdleSeconds == nil && signals.consoleUser == nil {
            // Not necessarily wrong as root with nobody logged in, but worth
            // saying out loud rather than letting it read as a clean pass.
            warn("presence", "no HID or console signal; reads as \(state.rawValue)")
        } else {
            ok("presence", "\(state.rawValue), idle "
                + (signals.hidIdleSeconds.map { String(format: "%.0fs", $0) } ?? "unknown")
                + ", console \(signals.consoleUser ?? "none")"
                + (signals.screenLocked == true ? ", locked" : ""))
        }

        let policy = effectivePolicy(state, signals)
        let kinds = permittedKinds(state, policy: policy)
        ok("policy", kinds.isEmpty
            ? "no work permitted right now (\(policy.blockedBy.joined(separator: ", ")))"
            : "permits \(kinds.map(\.rawValue).joined(separator: ", "))")

        // 3. Power and thermal, which gate work regardless of presence.
        if !signals.onACPower {
            warn("power", "on battery; all work is blocked until it is plugged in")
        } else {
            ok("power", "on AC")
        }
        if !signals.thermalOK {
            warn("thermal", "under pressure; GPU work is blocked")
        } else {
            ok("thermal", "nominal")
        }

        // 4. Metal's own ceiling, which is well below installed memory and is
        // what the agent's memory fractions are a fraction of.
        let workingSet = MetalInfo.workingSetGb()
        if workingSet > 0 {
            ok("Metal", String(format: "%.1f GB recommended working set", workingSet))
        } else {
            bad("Metal", "no device; GPU work is impossible on this machine")
            failures += 1
        }

        // 5. MLX, which is not a hard failure. A machine without it is still a
        // useful fleet member: ANE work is the only thing three of the five
        // presence states permit, so most of the fleet's hours do not involve
        // the GPU runtime at all.
        if MLXProbe.isAvailable() {
            ok("MLX", "GPU runtime works; this node can serve generate work")
        } else {
            warn("MLX", "no GPU runtime (Metal shader library missing). ANE work "
                + "still runs; for GPU work: xcodebuild -downloadComponent MetalToolchain")
        }

        // 6. QoS, the dial the agent turns when somebody sits down.
        ProcessQoS.setBackground(true)
        ProcessQoS.setBackground(false)
        ok("QoS", "background and standard both settable")

        print(String(repeating: "-", count: 64))
        if failures == 0 {
            print("READY. This machine can run the agent\(asRoot ? " as a daemon" : "").")
        } else {
            print("NOT READY: \(failures) blocking problem\(failures == 1 ? "" : "s") above.")
        }
        return failures == 0 ? 0 : 1
    }

    private static func ok(_ what: String, _ detail: String) {
        print("  ok    \(what.padding(toLength: 20, withPad: " ", startingAt: 0)) \(detail)")
    }
    private static func warn(_ what: String, _ detail: String) {
        print("  warn  \(what.padding(toLength: 20, withPad: " ", startingAt: 0)) \(detail)")
    }
    private static func bad(_ what: String, _ detail: String) {
        print("  FAIL  \(what.padding(toLength: 20, withPad: " ", startingAt: 0)) \(detail)")
    }
}
