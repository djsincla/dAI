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

/// What this machine would actually attempt, and why that is less than what the
/// policy permits.
///
/// Printed beside `permits` rather than instead of it, because a machine doing
/// nothing has two entirely different causes and only one line to tell them
/// apart. "Policy forbids it" is fixed by waiting or by locking the screen;
/// "there is no runtime for it" is fixed by installing one. Naming the missing
/// piece saves the reader from concluding the presence detection is broken.
func describeRunnable(_ policy: StatePolicy) -> String {
    let hasGPU = MLXProbe.isAvailable()
    // A node with no configured ANE model is an ordinary node, not a broken
    // one: a 16GB Mac carries an embedding model and nothing larger.
    let runnable = runnableKinds(policy, hasGPU: hasGPU, hasANE: true)
    let permitted = permittedKinds(policy: policy)
    let missing = permitted.filter { !runnable.contains($0) }
    let why = missing.map { kind -> String in
        kind.isImplemented ? "\(kind.rawValue): no runtime on this machine"
                           : "\(kind.rawValue): not implemented"
    }
    let head = runnable.isEmpty ? "nothing" : runnable.map(\.rawValue).joined(separator: ", ")
    return why.isEmpty ? head : head + "  (" + why.joined(separator: "; ") + ")"
}

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
    // The daemon's state, not this process's. A monitor constructed here begins
    // at ACTIVE and promotion needs the condition held for five minutes, so a
    // single sample can only ever print ACTIVE - which it did, on a machine
    // that had been locked for five minutes, while the daemon three feet away
    // had it right. A diagnostic that cannot report the truth is worse than no
    // diagnostic, because it gets believed.
    let daemon = AgentStatus.read()
    let live = daemon.flatMap { $0.isFresh ? PresenceState(rawValue: $0.presenceState) : nil }
    let state = live ?? reading.state
    let source = live != nil ? "daemon"
        : (daemon != nil ? "stale daemon status; this sample only" : "no daemon; this sample only")
    let policy = live.map { effectivePolicy($0, signals) } ?? reading.policy
    print("""
    presence   \(state.rawValue)  (observed \(reading.observed.rawValue), from \(source))
    hid idle   \(fmt(signals.hidIdleSeconds))s
    locked     \(signals.screenLocked.map(String.init(describing:)) ?? "unknown")
    console    \(signals.consoleUser ?? "nobody")
    ac power   \(signals.onACPower)
    thermal    \(signals.thermalOK ? "ok" : "pressure")
    policy     gpu=\(policy.gpu) ane=\(policy.ane) qos=\(policy.qos.rawValue)
    limits     duty=\(policy.dutyMax) mem=\(policy.memFrac) maxTokens=\(policy.maxCompletionTokens)
    permits    \(permittedKinds(state, policy: policy).map(\.rawValue).joined(separator: ", "))
    runs here  \(describeRunnable(policy))
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

case "renew":
    // usage: dai-agent renew <control-plane-url> [--force]
    //
    // The daemon does this on its own. The command exists for the machine that
    // has been off for a month, for a fleet that has just changed what it puts
    // in a certificate, and because "renew it now and tell me what happened" is
    // the first thing anybody wants when a node stops authenticating.
    guard args.count > 2 else {
        print("usage: dai-agent renew <url> [--force]")
        print("  Renews when the certificate is two thirds through its life.")
        print("  --force renews regardless, which is what to use after the")
        print("  fleet has changed what a node certificate has to contain.")
        exit(2)
    }
    do {
        let dir = Enroll.identityDir()
        let certPath = dir.appendingPathComponent("node.crt")
        let identity = try NodeIdentity.load(certificate: certPath,
                                             enclaveKey: Enroll.keyPath(dir))
        let ca = try String(contentsOf: dir.appendingPathComponent("ca.crt"), encoding: .utf8)
        let cp = try ControlPlane(base: URL(string: args[2])!, identity: identity, serverCAPEM: ca)

        let window = try Renewal.validity(certificatePEM: identity.certificatePEM)
        let force = args.contains("--force")
        let due = Renewal.due(notBefore: window.notBefore, notAfter: window.notAfter, now: Date())
        print("current certificate expires \(window.notAfter)")
        guard force || due else {
            print("not due yet; renews at two thirds of its life, or use --force")
            await cp.shutdown()
            exit(0)
        }

        let key = try EnclaveKey.loadOrCreate(at: Enroll.keyPath(dir))
        let csr = try CSR.create(commonName: MachineName.current(), key: key)
        let renewed: ControlPlane.Renewed
        do {
            renewed = try await cp.renew(csrPEM: csr)
        } catch {
            // Shut the client down before reporting. Letting it fall out of
            // scope during error handling aborts the process on a deinit
            // assertion, and the message that reaches the operator is about a
            // leaked HTTP client rather than about their certificate.
            await cp.shutdown()
            print("renewal refused: \(error)")
            exit(1)
        }
        try renewed.certPEM.write(to: certPath, atomically: true, encoding: .utf8)
        if let serverCA = renewed.serverCAPEM {
            try serverCA.write(to: dir.appendingPathComponent("ca.crt"),
                               atomically: true, encoding: .utf8)
        }
        if let nodeCA = renewed.nodeCAPEM {
            try nodeCA.write(to: dir.appendingPathComponent("node-ca.crt"),
                             atomically: true, encoding: .utf8)
        }
        let now = try Renewal.validity(certificatePEM: renewed.certPEM)
        print("renewed; expires \(now.notAfter)\(renewed.rekeyed ? " (new key)" : "")")
        // The running daemon is still presenting the certificate that has just
        // been retired, and will not notice until its own renewal check comes
        // round. Said rather than done: restarting somebody's daemon as a side
        // effect of a read-out command is not this command's business.
        print("restart the daemon to pick it up: "
            + "sudo launchctl kickstart -k system/com.dai.agent")
        await cp.shutdown()
    } catch {
        print("renewal failed: \(error)")
        exit(1)
    }

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

        // Shut the client down before reporting a failure. Letting it fall out
        // of scope during error handling trips a deinit assertion, and what
        // reaches the operator is a message about a leaked HTTP client instead
        // of the reason their node was refused - which is the whole point of
        // running this command.
        let served: [PresenceState: StatePolicy]
        do {
            served = try await cp.fetchPolicy()
        } catch {
            await cp.shutdown()
            print("status failed: \(error)")
            exit(1)
        }
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
        // Enrol here rather than in the installer. The Enclave will not generate
        // a key in an ssh session even as root, which is where an installer
        // usually runs, but will in a daemon - so the machine joins the fleet
        // on first start and nobody has to be sitting at it.
        let caPath = dir.appendingPathComponent("server-ca.crt").path
        guard await Enroll.ensureIdentity(controlPlane: URL(string: args[2])!,
                                          caPath: FileManager.default.fileExists(atPath: caPath)
                                            ? caPath : nil) else {
            print("no identity; waiting for approval or a join token")
            exit(1)
        }

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
        let gpuModel = args[3] == "-" ? "" : args[3]
        if gpuModel.isEmpty {
            // A node with no GPU weights is a node, not a broken install: a
            // 16GB Mac carries an embedding model and nothing larger. It does
            // ANE work and is not offered generate work.
            print("no GPU model configured; running ANE work only")
        } else if MLXProbe.isAvailable() {
            gpu = MLXRuntime(modelId: gpuModel)
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
        // Weights arrive here rather than being copied in by hand. The base is
        // the same directory the runtime reads from, so a fetched model is
        // loadable without anything moving it afterwards.
        let modelSync = ModelSync(controlPlane: cp, base: MLXRuntime.hubBase, status: status)
        // Certificates last thirty days, so a daemon that runs for longer than
        // that has to renew or stop being a fleet member. The address and the
        // CA are known here and nowhere else, which is why the renewer is given
        // a way to build its replacement client rather than the ingredients.
        let base = URL(string: args[2])!
        let renewer = CertificateRenewer(
            directory: dir, keyPath: Enroll.keyPath(dir), client: cp,
            rebuild: { identity, serverCA in
                try ControlPlane(base: base, identity: identity,
                                 serverCAPEM: serverCA ?? ca)
            },
            log: { print($0) })
        // Rendering, when this machine has a renderer. A machine without one is
        // an ordinary fleet member that does AI work and never offers the kind,
        // so nil here is a configuration rather than a fault.
        let renderer = RenderRuntime()
        let scenes = renderer == nil ? nil
            : SceneSync(controlPlane: cp, base: SceneSync.defaultBase(), log: { print($0) })
        let attachments = renderer == nil ? nil
            : AttachmentSync(controlPlane: cp, base: AttachmentSync.defaultBase(),
                             log: { print($0) })
        if let renderer {
            print("renderer: \(await renderer.rendererPath)")
        } else {
            print("no renderer on this machine; render work will not be offered")
        }

        // The serving loop, when there is one, so a renewal can be handed to it.
        // Declared before the worker because the worker's renewal callback
        // closes over it, and assigned below once the runtime is known.
        let serving = ServingHandle()  // see the type below

        let worker = Worker(controlPlane: cp, gpu: gpu, ane: ane,
                            status: status, modelSync: modelSync,
                            renderer: renderer, scenes: scenes, attachments: attachments,
                            renewer: renewer,
                            onRenewed: { replacement in
                                // Read from disk rather than passed along: the
                                // renewal has just written both files, and this
                                // is the one place that knows where enrolment
                                // put them. A node that had no node CA before
                                // renewing has one now, which is the whole
                                // reason an operator asks for a renewal.
                                let identity = try? NodeIdentity.load(
                                    certificate: dir.appendingPathComponent("node.crt"),
                                    enclaveKey: Enroll.keyPath(dir))
                                let peerCA = try? String(
                                    contentsOf: dir.appendingPathComponent("node-ca.crt"),
                                    encoding: .utf8)
                                let credentials = (identity != nil && peerCA != nil)
                                    ? (identity: identity!, peerCAPEM: peerCA!) : nil
                                await serving.get()?.adopt(controlPlane: replacement,
                                                           splitIdentity: credentials)
                            },
                            onServingModelChanged: { runtime, named in
                                // The group decides what this machine serves,
                                // so both loops have to be holding the same
                                // runtime. The batch loop swapped its own; this
                                // hands the serving loop the very same one,
                                // rather than a second runtime for the same
                                // model - two of those would load the weights
                                // twice on a machine that can hold them once.
                                await serving.get()?.adopt(runtime: runtime,
                                                           named: named)
                            },
                            promoteAfter: promote)

        // Batch and serving run side by side in one process, because a node
        // does both and they cannot share a loop: an interactive request must
        // not wait for a batch unit to finish, and a batch unit must not be
        // held behind a conversation. Keeping them in separate commands meant
        // installing the daemon quietly turned serving off, which is how a
        // machine ended up harvesting all day while reporting no chat model.
        if gpu != nil {
            // The credentials a split needs, loaded here because this is where
            // enrolment put them. The peer CA is the node CA: the other end of
            // a split is a node, and pinning the server CA fails the handshake
            // with "unknown CA", which reads as a broken network.
            let peerCA = try? String(
                contentsOf: dir.appendingPathComponent("node-ca.crt"), encoding: .utf8)
            let splitCredentials = peerCA.map { (identity: identity, peerCAPEM: $0) }
            let channel = ReverseChannel(controlPlane: cp, gpu: gpu,
                                         status: status, promoteAfter: promote,
                                         splitIdentity: splitCredentials)
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
            await serving.set(channel)
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
            print("serving as \(me.hostname) (\(me.tiers.joined(separator: " and ")))"
                + (me.isCluster
                   ? ": never preempted, so presence does not gate this node"
                   : ": harvested, so this node only serves when nobody is using it"))
        }
        let seconds = args.count > 4 ? Double(args[4]) ?? .infinity : .infinity
        await channel.run(maxSeconds: seconds)
        print("serve command finished after \(seconds)s")
        await cp.shutdown()
    } catch { print("serve failed: \(error)"); exit(1) }

case "render":
    // Held outside the do block so the failure path can close it.
    var renderClient: ControlPlane?
    // usage: dai-agent render <url> [seconds]
    //
    // Takes one render unit and does it, now, regardless of who is sitting at
    // the machine. The daemon will not do that - rendering is GPU work and
    // waits for the machine to be free - and that is exactly why this exists:
    // proving a machine can render should not require waiting until nobody is
    // using it. An operator ran this deliberately; the presence rule protects
    // them from the fleet, not from themselves.
    guard args.count > 2 else {
        print("usage: dai-agent render <url> [seconds]")
        print("  Leases one render unit and renders it, ignoring presence.")
        exit(2)
    }
    do {
        let dir = Enroll.identityDir()
        let identity = try NodeIdentity.load(
            certificate: dir.appendingPathComponent("node.crt"),
            enclaveKey: Enroll.keyPath(dir))
        let ca = try String(contentsOf: dir.appendingPathComponent("ca.crt"), encoding: .utf8)
        let cp = try ControlPlane(base: URL(string: args[2])!, identity: identity,
                                  serverCAPEM: ca)
        renderClient = cp
        guard let renderer = RenderRuntime() else {
            print("no renderer on this machine"); await cp.shutdown(); exit(1)
        }
        print("renderer: \(await renderer.rendererPath)")

        let scenes = SceneSync(controlPlane: cp, base: SceneSync.defaultBase(),
                               log: { print($0) })
        let attachments = AttachmentSync(controlPlane: cp, base: AttachmentSync.defaultBase(),
                                         log: { print($0) })
        let deadline = Date().addingTimeInterval(args.count > 3 ? Double(args[3]) ?? 120 : 120)
        var done = 0
        while Date() < deadline {
            guard let lease = try await cp.leaseWork(kinds: [.render]) else {
                print("no render work: \(await cp.lastLeaseReason ?? "unknown")")
                break
            }
            // Content comes with the job. A queue that spans the change still
            // drains: a unit submitted against the old scene catalogue is
            // fetched the old way.
            let ready: (entry: URL, root: URL)
            if let jobId = lease.jobId {
                let got = try await attachments.ensure(jobId: jobId)
                ready = (got.entry, got.root)
            } else if let sceneId = lease.sceneId {
                let got = try await scenes.ensure(sceneId: sceneId)
                ready = (got.entry, got.root)
            } else {
                print("unit \(lease.unitId) names no content"); break
            }
            var completed: [WorkItem] = []
            let started = Date()
            for item in lease.items {
                guard let frame = item["frame"]?.intValue else { continue }
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dai-render-\(lease.unitId)")
                defer { try? FileManager.default.removeItem(at: out) }
                let outcome = try await renderer.render(scene: ready.entry, frame: frame,
                                                        into: out,
                                                        samples: item["samples"]?.intValue)
                let bytes = try await cp.uploadOutput(unitId: lease.unitId,
                                                      name: outcome.file.lastPathComponent,
                                                      file: outcome.file)
                print(String(format: "frame %d in %.1fs, %.1fMB returned",
                             frame, outcome.seconds, Double(bytes) / 1_048_576))
                completed.append(.object(["id": item["id"] ?? .null]))
                done += 1
            }
            let outcome = try await cp.report(
                unitId: lease.unitId, completed: completed, unfinished: [],
                seconds: Date().timeIntervalSince(started))
            if outcome.jobFinished, let jobId = lease.jobId {
                await attachments.release(jobId: jobId)
            }
        }
        print("rendered \(done) frame(s)")
        await cp.shutdown()
    } catch {
        // Shut the client down before reporting. Letting it fall out of scope
        // while an error unwinds trips a deinit assertion, and what reaches the
        // operator is a message about a leaked HTTP client rather than the
        // reason their render did not happen.
        await renderClient?.shutdown()
        print("render failed: \(error)")
        exit(1)
    }

case "split":
    // usage: dai-agent split <model-dir> <rank> <size> <listen-port|peer-host:port> [prompt]
    //
    // Run by hand for now: one process per machine, the higher rank connecting
    // to the lower. Wiring this into the fleet needs gang admission, which does
    // not exist yet, and starting a pipeline without it would hand out work that
    // hangs when one machine is missing.
    guard args.count > 5 else {
        print("""
        usage: dai-agent split <model-dir> <rank> <size> <port-or-peer> [prompt]
          rank 0 holds the last layers and the output head, and listens.
          higher ranks hold earlier layers and connect to rank-1.
        """)
        exit(2)
    }
    do {
        let directory = URL(fileURLWithPath: args[2])
        let rank = Int(args[3]) ?? 0
        let size = Int(args[4]) ?? 2
        let where_ = args[5]
        let prompt = args.count > 6 ? args[6] : "Explain what a Merkle tree is, briefly."

        let dir = Enroll.identityDir()
        let identity = try? NodeIdentity.load(
            certificate: dir.appendingPathComponent("node.crt"),
            enclaveKey: Enroll.keyPath(dir))
        // The *node* CA, not the server CA used everywhere else in this file.
        // The peer on the other end of a split is a node, and its certificate
        // is signed by the CA that signs nodes. Pinning the server CA here
        // fails the handshake with "unknown CA", which reads like a
        // misconfigured network rather than the wrong trust root.
        let ca = try? String(contentsOf: dir.appendingPathComponent("node-ca.crt"),
                             encoding: .utf8)

        let channel = PipelineChannel(log: { print($0) })
        // Nothing to connect when the model is not split. Useful as a baseline:
        // the same code path, the same loop, one machine.
        if size == 1 {
            print("running whole on one machine, no peer")
        } else if rank == 0 {
            guard let identity, let ca else {
                print("rank 0 listens over mTLS and needs an enrolled identity"); exit(1)
            }
            let port = try await channel.listen(port: Int(where_) ?? 7710,
                                                identity: identity, peerCAPEM: ca)
            print("listening on \(port), waiting for rank 1")
        } else {
            guard let identity, let ca else {
                print("this machine needs an enrolled identity to join a split"); exit(1)
            }
            let parts = where_.split(separator: ":")
            try await channel.connect(host: String(parts[0]),
                                      port: Int(parts.count > 1 ? parts[1] : "7710") ?? 7710,
                                      identity: identity, peerCAPEM: ca,
                                      serverName: String(parts[0]))
            print("connected to \(where_)")
        }

        let runner = SplitRunner(plan: .init(modelId: directory.lastPathComponent,
                                             rank: rank, size: size),
                                 channel: channel)
        let loaded = try await runner.load(directory: directory)
        print("rank \(rank)/\(size): layers \(loaded.split.startIndex)"
            + "..<\(loaded.split.endIndex) loaded")

        let outcome = try await runner.generate(loaded, prompt: prompt, maxTokens: 60)
        if loaded.split.isLast {
            print("---")
            print(outcome.text)
            print("---")
            print(String(format: "%d tokens, %.2fs to first, %.1f tok/s, %.2fGB",
                         outcome.tokens, outcome.promptSeconds,
                         Double(outcome.tokens - 1) / max(outcome.decodeSeconds, 0.001),
                         outcome.residentGb))
        } else {
            print(String(format: "rank %d finished %d tokens, %.2fGB resident",
                         rank, outcome.tokens, outcome.residentGb))
        }
        await channel.close()
    } catch {
        print("split failed: \(error)")
        exit(1)
    }

case "update":
    // usage: dai-agent update <control-plane-url> [binary-path] [wait-seconds]
    //
    // Run as root from its own launchd job. The agent cannot do this itself:
    // it runs as a service account that cannot write to the directory its own
    // binary lives in, and giving it that ability would let a process that
    // executes fleet-supplied payloads rewrite itself.
    guard args.count > 2 else {
        print("usage: dai-agent update <url> [binary-path] [wait-seconds]"); exit(2)
    }
    await Updater.run(
        controlPlane: URL(string: args[2])!,
        binaryPath: args.count > 3 ? args[3] : "/usr/local/libexec/dai/dai-agent",
        waitSeconds: args.count > 4 ? (Double(args[4]) ?? 300) : 300)

case "qos":
    // Demonstrates the control that E1 measured at 2.4x on sustained work and
    // the worker at ~26x on bursty work.
    print("enter background: \(ProcessQoS.setBackground(true))")
    print("leave background: \(ProcessQoS.setBackground(false))")

default:
    print("usage: dai-agent [pause|resume|preflight|presence|verify-ane <model>|generate|enroll|status|timing|lease-probe|work|serve|qos]")
    exit(2)
}


/// A place to put the serving loop so the batch loop can reach it.
///
/// The two loops are built in the wrong order for a direct reference: the
/// worker's renewal callback has to exist before the worker does, and the
/// serving channel is only built afterwards and only on a machine with a GPU.
/// An actor rather than a variable because the callback runs on whichever loop
/// renewed, and this is shared mutable state between them.
actor ServingHandle {
    private var channel: ReverseChannel?
    func set(_ channel: ReverseChannel) { self.channel = channel }
    func get() -> ReverseChannel? { channel }
}
