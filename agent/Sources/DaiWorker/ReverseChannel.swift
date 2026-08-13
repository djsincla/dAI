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
    private var controlPlane: any ControlPlaneClient
    private let gpu: MLXRuntime?
    private let source: SignalSource
    private let monitor: PresenceMonitor
    private let pauseSwitch = PauseSwitch()

    /// What the machine's owner is shown.
    ///
    /// Serving published nothing, so a machine answering requests all day told
    /// its owner nothing was installed - the exact failure the panel exists to
    /// prevent. Serving is also not the same activity as overnight batch work,
    /// and saying which matters more to the person at the desk than to anyone
    /// else: "answering requests for the studio" and "running batch work" are
    /// different bargains.
    private let status: StatusPublisher
    private var served = 0

    private var policy: [PresenceState: StatePolicy] = defaultPolicy
    /// Set from the control plane's view of this node, not assumed.
    private var isCluster = false

    /// The identity this machine joins a split with, and the CA it trusts its
    /// peer against.
    ///
    /// Passed in rather than read from disk here. The credential belongs to the
    /// process that enrolled and already holds it, and a worker that goes
    /// looking for one would need to know where enrolment put it - which is the
    /// CLI's business, not the loop's. Nil on a machine that cannot join a
    /// split, which is reported rather than crashed on.
    ///
    /// The peer CA is the *node* CA, not the server CA used everywhere else.
    /// The other end of a split is a node, and pinning the wrong root fails the
    /// handshake with "unknown CA" - which reads as a broken network rather
    /// than the wrong trust anchor.
    private var splitIdentity: (identity: NodeIdentity, peerCAPEM: String)?

    public init(controlPlane: any ControlPlaneClient, gpu: MLXRuntime?,
                source: SignalSource = MacSignalSource(),
                status: StatusPublisher = StatusPublisher(),
                promoteAfter: TimeInterval = idlePromoteSeconds,
                splitIdentity: (identity: NodeIdentity, peerCAPEM: String)? = nil) {
        self.status = status
        self.controlPlane = controlPlane
        self.gpu = gpu
        self.source = source
        self.monitor = PresenceMonitor(promoteAfter: promoteAfter)
        self.splitIdentity = splitIdentity
    }

    public func setPolicy(_ policy: [PresenceState: StatePolicy]) {
        self.policy = policy
    }

    public func setCluster(_ isCluster: Bool) {
        self.isCluster = isCluster
    }

    /// Start presenting a renewed certificate.
    ///
    /// The batch loop owns renewal and this one does not, but they are two
    /// loops in one process holding two references to the same identity. The
    /// first renewal on real hardware showed what that costs: the batch loop
    /// swapped its client and carried on, and this loop went on presenting the
    /// certificate the control plane had just retired, reconnecting every five
    /// seconds to be told "unknown certificate" - for as long as the process
    /// lived, since nothing here ever reloads.
    ///
    /// Both credentials, because renewal replaces both. The node certificate is
    /// also what this machine joins a split with, and a node acquires its node
    /// CA by renewing - so a machine that could not join a split before the
    /// renewal can afterwards, and only if it is told.
    public func adopt(controlPlane: any ControlPlaneClient,
                      splitIdentity: (identity: NodeIdentity, peerCAPEM: String)?) {
        self.controlPlane = controlPlane
        // Kept rather than cleared when the new one is nil. Losing the ability
        // to join a split because a reload failed is worse than running on the
        // previous credential, which is still valid until it expires.
        if let splitIdentity { self.splitIdentity = splitIdentity }
        log("now presenting the renewed certificate")
    }

    /// What this loop is presenting, and what it would join a split with.
    ///
    /// Reachable only from a test. The loop touches its client nowhere a test
    /// can see without a GPU on the machine - it refuses to connect at all when
    /// there is none - so proving that a renewal actually landed here needs a
    /// way to ask.
    func presenting() -> (client: any ControlPlaneClient,
                          split: (identity: NodeIdentity, peerCAPEM: String)?) {
        (controlPlane, splitIdentity)
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

        // Heartbeats run on their own task, not in the request loop.
        //
        // A large prompt takes minutes to read - 19,243 tokens measured at 377
        // seconds - and for all of that the loop is inside a single call. With
        // the heartbeat inline the node went silent while it worked, the
        // scheduler dropped it for being stale, and it looked exactly like a
        // crash: gone from the fleet, no error anywhere, back a few minutes
        // later. It was answering the whole time.
        let beating = Task { [weak self] in
            while !Task.isCancelled {
                await self?.heartbeatNow()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        defer { beating.cancel() }

        defer { log("serve loop returning; deadline was \(deadline)") }

        while Date() < deadline {
            let gate = mayServe()

            // nil means "nothing to say": the batch loop's activity stands,
            // rather than this one claiming the panel while idle.
            await publish(gate.state, activity: nil)
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

    /// Report in, whatever the request loop is doing.
    private func publish(_ state: PresenceState, activity: String?) async {
        status.updateServing(
            ready: gpu != nil && !pauseSwitch.read().paused,
            activity: activity,
            requestsAnswered: served,
            residentGb: await (gpu?.isLoaded ?? false) ? (await gpu?.residentGb ?? 0) : 0)
    }

    private func heartbeatNow() async {
        let signals = source.read()
        let state = monitor.update(signals, now: Date().timeIntervalSince1970).state
        // nil: a heartbeat is not an activity, and claiming one here would
        // overwrite whatever the loop last said it was doing.
        await publish(state, activity: nil)
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

    /// Be one rank of a split model.
    ///
    /// Rank 0 listens and holds the output head, so it is the one with an
    /// answer to report. The others hold earlier layers, hand their hidden state
    /// across, and report that they did their share - the control plane takes
    /// rank 0's reply as the completion and needs the rest only to know they
    /// did not fail.
    ///
    /// The dial retries, because the ranks are dispatched at the same instant
    /// and the listener is frequently not up when the first attempt arrives.
    /// That is ordinary rather than a failure; a peer that never comes is
    /// separated from one that is slow by giving up after a bounded time.
    private func runSplit(_ split: SplitDispatch,
                          dispatch: ControlPlane.Dispatch) async {
        let directory = MLXRuntime.modelDirectory
            .appendingPathComponent(split.model)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil,
                error: "rank \(split.rank) does not hold \(split.model)")
            return
        }

        guard let credentials = splitIdentity else {
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil,
                error: "this machine has no enrolled identity to join a split with")
            return
        }
        let identity = credentials.identity
        let ca = credentials.peerCAPEM

        await publish(mayServe().state, activity: "rank \(split.rank) of a split model")
        let channel = PipelineChannel()
        let started = Date()
        do {
            switch split.role {
            case .listen:
                _ = try await channel.listen(port: split.port,
                                             identity: identity, peerCAPEM: ca)
                log("rank \(split.rank) listening on \(split.port)")
            case .dial:
                try await channel.connectWithRetry(
                    host: split.peer!, port: split.port, identity: identity,
                    peerCAPEM: ca, serverName: split.peer!)
                log("rank \(split.rank) connected to \(split.peer!)")
            }

            let runner = SplitRunner(
                plan: .init(modelId: split.model, rank: split.rank, size: split.size),
                channel: channel)
            // The cap the control plane already applied, computed from the
            // presence of the machine holding the head. Read rather than
            // recomputed, so the decision lives in one place.
            let budget = dispatch.body["max_tokens"]?.intValue ?? 256
            let done = try await runner.run(directory: directory,
                                            prompt: promptFrom(dispatch.body),
                                            maxTokens: budget)

            let seconds = Date().timeIntervalSince(started)
            log(String(format: "rank %d (layers %d..<%d) finished %d tokens in %.1fs",
                       split.rank, done.layers.lowerBound, done.layers.upperBound,
                       done.outcome.tokens, seconds))
            // Only the rank holding the head has text. The others report a
            // completion with none, which is what tells the control plane they
            // did not fail.
            try await controlPlane.reportDispatch(
                id: dispatch.id,
                text: done.isHead ? done.outcome.text : nil,
                error: nil, completionTokens: done.outcome.tokens)
        } catch {
            log("rank \(split.rank) failed: \(error)")
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil,
                error: "rank \(split.rank) failed: \(error)")
        }
    }

    private func handle(_ dispatch: ControlPlane.Dispatch, maxTokens: Int) async {
        guard let gpu else {
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil, error: "no GPU runtime on this node")
            return
        }

        // Watch for the caller giving up while this runs. Two seconds is a
        // compromise: often enough that a cancel is felt as immediate, rare
        // enough to be free next to the work it is interrupting.
        let cancelled = CancelFlag()
        // Detached, and that detail is the whole thing.
        //
        // A plain Task created inside an actor inherits its isolation, so this
        // would queue behind the very call it is meant to interrupt: the actor
        // is occupied for the length of the generation, and a watcher that can
        // only run when the actor is free never runs at all. Detaching gives it
        // its own executor.
        let watching = Task.detached { [controlPlane] in
            while !Task.isCancelled {
                if await controlPlane.isDispatchCancelled(id: dispatch.id) {
                    cancelled.set()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { watching.cancel() }

        // A rank of a split model, which is a different piece of work from a
        // completion: two machines, one answer, and a channel between them that
        // has to exist before either can start.
        if let split = SplitDispatch(body: dispatch.body) {
            await runSplit(split, dispatch: dispatch)
            return
        }

        // Counting is not generating: no cancellation watch, no policy cap, no
        // tool parsing. It exists so a client can decide what to send, so it
        // has to be cheap enough to ask before every turn.
        if dispatch.body["operation"]?.stringValue == "count_tokens" {
            do {
                if await !gpu.isLoaded { _ = try await gpu.load() }
                let count = try await gpu.countTokens(
                    messages: chatFrom(dispatch.body, dialect: await gpu.toolDialect)
                        ?? [["role": "user", "content": promptFrom(dispatch.body)]],
                    tools: dispatch.body["tools"]?.arrayValue)
                log("counted \(count) tokens")
                try await controlPlane.reportDispatch(
                    id: dispatch.id, text: nil, error: nil, promptTokens: count)
            } catch {
                try? await controlPlane.reportDispatch(
                    id: dispatch.id, text: nil, error: String(describing: error))
            }
            return
        }

        await publish(mayServe().state, activity: "answering a request")
        let started = Date()
        do {
            // Refuse early rather than time out. A prompt beyond what this node
            // can read inside the budget produces the same failure either way,
            // but one takes two minutes to say so and gives the caller nothing
            // to act on.
            if MLXRuntime.adaptiveContextEnabled, let limit = await gpu.contextLength {
                let approximate = approximatePromptTokens(dispatch.body)
                if approximate > limit {
                    log("refusing ~\(approximate) prompt tokens; this node can read \(limit)")
                    try await controlPlane.reportDispatch(
                        id: dispatch.id, text: nil,
                        // Phrased so the control plane can recognise it: this
                        // is the caller's request being too large, not the node
                        // failing, and the two need different status codes.
                        error: "prompt is too long: about \(approximate) tokens, and this "
                             + "node can process \(limit) within the answer budget")
                    return
                }
            }
            if await !gpu.isLoaded {
                let seconds = try await gpu.load()
                log(String(format: "loaded model in %.2fs", seconds))
            }

            // Capped by the node's own policy as well as the control plane's.
            // The server applies the same ceiling, and this is the second of the
            // two: a single request has no seam to yield at, so its length is
            // the only thing bounding how long a returning user waits.
            let requested = dispatch.body["max_tokens"]?.intValue ?? 512
            let out = try await gpu.complete(
                prompt: promptFrom(dispatch.body),
                maxTokens: min(requested, maxTokens),
                tools: dispatch.body["tools"]?.arrayValue,
                messages: chatFrom(dispatch.body, dialect: await gpu.toolDialect),
                forceTool: forcedTool(dispatch.body),
                cancelled: cancelled)

            if cancelled.isSet {
                // Nothing to report. The control plane has already answered the
                // caller and closed the dispatch, so posting a partial result
                // here only earns a 409 and puts a failure in the log for a
                // request that did exactly what it was asked to.
                log(String(format: "cancelled by the caller after %.1fs",
                           Date().timeIntervalSince(started)))
                return
            }

            served += 1

            let elapsed = Date().timeIntervalSince(started)
            // The prompt rate is logged because it is what sizes the advertised
            // window, and a window nobody can explain is one nobody trusts.
            log(String(format: "prompt %d tokens in %.1fs wall%@; window %@",
                       out.promptTokens, elapsed,
                       out.reusedTokens > 0
                         ? String(format: ", %d of them reused (%.0f%% cached)",
                                  out.reusedTokens,
                                  Double(out.reusedTokens) / Double(max(out.promptTokens, 1)) * 100)
                         : "",
                       (await gpu.contextLength).map(String.init) ?? "unknown"))
            log(String(format: "answered in %.2fs (%d prompt, %d generated%@)",
                       elapsed, out.promptTokens, out.completionTokens,
                       out.toolCalls.isEmpty ? ""
                         : ", \(out.toolCalls.count) tool call"
                           + (out.toolCalls.count == 1 ? "" : "s")))
            // Coerced against the schema the caller declared, so a field the
            // model spelled as a string ("24" for an integer) does not make the
            // client reject a call it otherwise got right.
            let schemas = toolSchemas(dispatch.body)
            let calls = out.toolCalls.map { call in
                ToolCall(name: call.name,
                         arguments: ToolSchema.coerce(call.arguments, to: schemas[call.name]))
            }
            try await controlPlane.reportDispatch(
                id: dispatch.id, text: out.text, error: nil,
                promptTokens: out.promptTokens, completionTokens: out.completionTokens,
                cachedTokens: out.reusedTokens, toolCalls: calls)
        } catch {
            log("failed: \(error)")
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil, error: String(describing: error))
        }
    }

    /// The tool the caller insisted on, if it named one.
    private func forcedTool(_ body: JSONValue) -> String? {
        guard let choice = body["tool_choice"] else { return nil }
        guard choice["type"]?.stringValue == "tool" else { return nil }
        return choice["name"]?.stringValue
    }

    /// A rough token count, for deciding whether to attempt a request at all.
    ///
    /// Four characters per token is crude and known to be crude; it is used
    /// only to catch prompts far beyond what this node can read, where being
    /// wrong by a fifth changes nothing. The exact count comes from the
    /// tokeniser afterwards.
    private func approximatePromptTokens(_ body: JSONValue) -> Int {
        var characters = 0
        for message in body["messages"]?.arrayValue ?? [] {
            characters += (textOf(message["content"]) ?? "").count
        }
        for tool in body["tools"]?.arrayValue ?? [] {
            characters += String(describing: tool.anyValue).count
        }
        return characters / 4
    }

    /// Declared input schemas, keyed by tool name.
    private func toolSchemas(_ body: JSONValue) -> [String: JSONValue] {
        guard let tools = body["tools"]?.arrayValue else { return [:] }
        var out: [String: JSONValue] = [:]
        for tool in tools {
            guard let name = tool["name"]?.stringValue else { continue }
            // Both spellings: Anthropic calls it input_schema, OpenAI parameters.
            out[name] = tool["input_schema"] ?? tool["parameters"]
        }
        return out
    }

    /// The conversation as roles and content, for the chat template.
    ///
    /// Preferred over the flattened prompt whenever the template can be
    /// applied: the template is what renders tool definitions and tool results
    /// in the form the model was trained on, and flattening throws that away.
    private func chatFrom(_ body: JSONValue, dialect: ToolDialect?) -> [[String: String]]? {
        guard case let .array(messages)? = body["messages"] else { return nil }
        let mapped = messages.compactMap { message -> [String: String]? in
            guard let role = message["role"]?.stringValue else { return nil }

            // A message carrying tool results is not a user turn, whatever the
            // client labelled it. Llama's template branches on `ipython` and
            // most others on `tool`; sent as `user` the result renders as
            // ordinary prose, the model sees its call still unanswered, and it
            // calls again - forever, when the conversation ends on a tool
            // result, which is every agentic turn.
            if let results = toolResults(message["content"]), !results.isEmpty {
                return ["role": dialect?.toolResultRole ?? "tool",
                        "content": results.joined(separator: "\n")]
            }
            guard let content = textOf(message["content"]) else { return nil }
            return ["role": role, "content": content]
        }
        return mapped.isEmpty ? nil : mapped
    }

    /// The bodies of any tool_result blocks, unwrapped.
    ///
    /// Returned bare rather than annotated: the template supplies whatever
    /// framing the model was trained on, and adding a label of our own puts
    /// text in front of the model it has never seen in that position.
    private func toolResults(_ content: JSONValue?) -> [String]? {
        guard case let .array(blocks)? = content else { return nil }
        let results = blocks.compactMap { block -> String? in
            guard block["type"]?.stringValue == "tool_result" else { return nil }
            return textOf(block["content"]) ?? ""
        }
        return results.isEmpty ? nil : results
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
            let parts = blocks.compactMap { block -> String? in
                if let text = block["text"]?.stringValue { return text }
                // A tool result comes back as its own block type. Rendering it
                // as text is what lets the loop continue: the model has to see
                // what its call returned or it will simply ask again.
                if block["type"]?.stringValue == "tool_result" {
                    let body = textOf(block["content"]) ?? ""
                    let id = block["tool_use_id"]?.stringValue ?? ""
                    return "[tool_result \(id)]\n\(body)"
                }
                if block["type"]?.stringValue == "tool_use" {
                    let name = block["name"]?.stringValue ?? ""
                    let input = block["input"].map { String(describing: $0.anyValue) } ?? ""
                    return "[tool_use \(name)] \(input)"
                }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if case .object = content { return String(describing: content.anyValue) }
        return nil
    }
}
