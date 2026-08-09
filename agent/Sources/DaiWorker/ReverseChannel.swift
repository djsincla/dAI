import DaiAgent
import Foundation

/// Serves interactive requests pushed down from the control plane.
///
/// Batch work is pulled: the node asks when it is ready, which suits a queue.
/// Interactive requests cannot wait for the next poll, so the node dials out and
/// parks on a long-lived request, and the scheduler pushes down the open
/// connection. Outbound, so no inbound firewall rules and no NAT traversal;
/// pushed, so routing costs milliseconds rather than a poll interval.
///
/// It runs alongside the batch loop rather than inside it. A request arriving
/// while a batch unit is mid-flight must not wait for that unit to finish, and
/// folding both into one loop would make the interactive latency depend on the
/// batch size.
///
/// **This is not for harvested machines.** A conversation needs a resident model
/// and a node that will still be there in a minute, and preemption is fatal to
/// both. The control plane decides where to route; the agent's part is to be
/// honest about what it can serve and to release the model the moment its
/// presence state stops permitting GPU work.
public actor ReverseChannel {
    private let controlPlane: ControlPlane
    private let gpu: MLXRuntime?
    private let source: SignalSource
    private let monitor: PresenceMonitor
    private let pauseSwitch = PauseSwitch()

    private var policy: [PresenceState: StatePolicy] = defaultPolicy
    /// Set from the control plane's view of this node, not assumed.
    private var isCluster = false
    private var lastHeartbeat: TimeInterval = 0

    public init(controlPlane: ControlPlane, gpu: MLXRuntime?,
                source: SignalSource = MacSignalSource(),
                promoteAfter: TimeInterval = idlePromoteSeconds) {
        self.controlPlane = controlPlane
        self.gpu = gpu
        self.source = source
        self.monitor = PresenceMonitor(promoteAfter: promoteAfter)
    }

    public func setPolicy(_ policy: [PresenceState: StatePolicy]) {
        self.policy = policy
    }

    public func setCluster(_ isCluster: Bool) {
        self.isCluster = isCluster
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).suffix(9).prefix(8)
        print("[\(stamp)] serve: \(message)")
    }

    /// Whether this node may answer an interactive request right now.
    ///
    /// The same gate as batch GPU work, deliberately. A request served while
    /// somebody is using the machine is exactly the intrusion the whole design
    /// exists to prevent, and being interactive does not make it more welcome.
    private func mayServe() -> (ok: Bool, state: PresenceState, maxTokens: Int) {
        let reading = monitor.update(source.read(), now: Date().timeIntervalSince1970)
        let p = policy[reading.state] ?? reading.policy

        // The owner's pause still applies, on every tier. It is the one control
        // with no override, and a dedicated box is still somebody's machine.
        if pauseSwitch.read().paused { return (false, reading.state, 0) }

        // A cluster node is a dedicated box that is never preempted, so
        // presence does not gate it: nobody is sitting at it, and a
        // conversation needs a model that will still be resident a minute from
        // now, which the harvest tier cannot promise by design.
        if isCluster {
            return (gpu != nil, reading.state,
                    defaultPolicy[.absent]!.maxCompletionTokens)
        }
        return (p.gpu && p.dutyMax > 0 && gpu != nil, reading.state, p.maxCompletionTokens)
    }

    public func run(maxSeconds: TimeInterval = .infinity) async {
        let deadline = Date().addingTimeInterval(maxSeconds)
        log("holding the reverse channel open")

        while Date() < deadline {
            let gate = mayServe()
            // A serving node has to heartbeat like any other. The scheduler
            // only considers nodes it has heard from recently, so a node that
            // holds the channel open and says nothing else is invisible to
            // routing: connected, willing, and never chosen.
            await heartbeatIfDue(gate.state)
            guard gate.ok else {
                // Not connecting at all is the honest signal: the control plane
                // only routes to nodes holding the channel open, so dropping it
                // takes this machine out of rotation rather than having it
                // accept a request and refuse.
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            do {
                guard let dispatch = try await controlPlane.awaitDispatch() else {
                    continue  // 204, reconnect
                }
                await handle(dispatch, maxTokens: gate.maxTokens)
            } catch {
                // A control plane that has gone away must not become a busy
                // loop against a dead socket.
                log("channel error: \(error)")
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func heartbeatIfDue(_ state: PresenceState) async {
        let now = Date().timeIntervalSince1970
        guard now - lastHeartbeat >= 20 else { return }
        lastHeartbeat = now
        let signals = source.read()
        let resident: [String: Double] = await (gpu?.isLoaded ?? false)
            ? [await gpu!.name: await gpu!.residentGb] : [:]
        // Advertised whether or not the model is loaded right now: the window a
        // model accepts does not depend on whether it happens to be resident,
        // and a client asking what this node can serve wants the answer either
        // way.
        var info: [String: Int] = [:]
        if let gpu, let context = await gpu.contextLength { info[await gpu.name] = context }
        try? await controlPlane.heartbeat(
            state: state, onACPower: signals.onACPower, thermalOK: signals.thermalOK,
            userPaused: pauseSwitch.read().paused,
            residentModels: resident, modelInfo: info)
    }

    private func handle(_ dispatch: ControlPlane.Dispatch, maxTokens: Int) async {
        guard let gpu else {
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil, error: "no GPU runtime on this node")
            return
        }

        let started = Date()
        do {
            if await !gpu.isLoaded {
                let seconds = try await gpu.load()
                log(String(format: "loaded model in %.2fs", seconds))
            }

            // Capped by the node's own policy as well as the control plane's.
            // The server applies the same ceiling, and this is the second of the
            // two: a single request has no seam to yield at, so its length is
            // the only thing bounding how long a returning user waits.
            let requested = dispatch.body["max_tokens"]?.intValue ?? 512
            let out = try await gpu.complete(prompt: promptFrom(dispatch.body),
                                             maxTokens: min(requested, maxTokens))
            let elapsed = Date().timeIntervalSince(started)
            log(String(format: "answered in %.2fs (%d prompt, %d generated)",
                       elapsed, out.promptTokens, out.completionTokens))
            try await controlPlane.reportDispatch(
                id: dispatch.id, text: out.text, error: nil,
                promptTokens: out.promptTokens, completionTokens: out.completionTokens)
        } catch {
            log("failed: \(error)")
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil, error: String(describing: error))
        }
    }

    /// Flatten a messages array into a prompt.
    ///
    /// The runtime takes a single string, so the conversation is rendered here.
    /// A model's own chat template would be better and is what
    /// `MLXLMCommon` applies for the simple case; this keeps the shape the
    /// control plane sends without pretending to more fidelity than it has.
    private func promptFrom(_ body: JSONValue) -> String {
        guard case let .array(messages)? = body["messages"] else {
            return body["prompt"]?.stringValue ?? ""
        }
        return messages.compactMap { message -> String? in
            let role = message["role"]?.stringValue ?? "user"
            guard let content = textOf(message["content"]) else { return nil }
            return "\(role): \(content)"
        }.joined(separator: "\n\n")
    }

    /// Content is a string in the OpenAI shape and an array of blocks in the
    /// Anthropic one. Both arrive here, so both are handled.
    private func textOf(_ content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let text = content.stringValue { return text }
        if case let .array(blocks) = content {
            let parts = blocks.compactMap { $0["text"]?.stringValue }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }
}
