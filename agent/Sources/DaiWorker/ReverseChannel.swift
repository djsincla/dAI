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

        while Date() < deadline {
            let gate = mayServe()

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
    private func heartbeatNow() async {
        let signals = source.read()
        let state = monitor.update(signals, now: Date().timeIntervalSince1970).state
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
                forceTool: forcedTool(dispatch.body))
            let elapsed = Date().timeIntervalSince(started)
            // The prompt rate is logged because it is what sizes the advertised
            // window, and a window nobody can explain is one nobody trusts.
            log(String(format: "prompt %d tokens in %.1fs wall; window now %@",
                       out.promptTokens, elapsed,
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
                toolCalls: calls)
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
