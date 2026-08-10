import DaiAgent
import Foundation
import MLX
import MLXLLM
import Hub
import MLXLMCommon

/// MLX runtime for `generate` work.
///
/// E4 measured model load at 1.4s warm and 2.8s cold for a 14B, roughly 20x
/// cheaper than the plan assumed, because unified memory has no host-to-device
/// transfer step. That is what makes preemption affordable and why this releases
/// eagerly rather than holding a model against a possible return.
public actor MLXRuntime {
    private let modelId: String
    private var container: ModelContainer?

    public init(modelId: String) { self.modelId = modelId }

    /// Whether the node may reach the hub for weights it does not have.
    ///
    /// Off by default, for two reasons that happen to agree.
    ///
    /// The measured one: consulting the hub costs 99s on a model already
    /// present on disk, against 3.85s offline. E4 sized the entire preemption
    /// design around a 1-3s reload, and 99s does not merely miss that, it
    /// inverts it - a yield would cost more than the work it protects. The
    /// number is a network round trip per file, on every load, forever.
    ///
    /// The other is the product's premise. A fleet sold on data never leaving
    /// the building should not have every node fetching weights from the
    /// internet on first use. Models belong in the control plane's catalogue,
    /// staged deliberately and verified by hash.
    public static var fetchAllowed: Bool {
        ProcessInfo.processInfo.environment["DAI_ALLOW_MODEL_FETCH"] == "1"
    }

    /// Where model weights live.
    ///
    /// Overridable so the daemon can be pointed at its own state directory,
    /// which it must be: a service account has no usable home.
    /// The hub's base directory, which is not where the weights sit.
    ///
    /// HubApi appends `models/<repo>` to whatever base it is given, so pointing
    /// this at the directory the weights are in produces `models/models/...`
    /// and a config.json that cannot be found. DAI_MODEL_DIR names the base;
    /// ``modelDirectory`` is where the files actually land.
    public static var hubBase: URL {
        if let dir = ProcessInfo.processInfo.environment["DAI_MODEL_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return URL.cachesDirectory
    }

    /// Where a model's files are, which is what reads config.json and
    /// tokenizer_config.json.
    public static var modelDirectory: URL {
        hubBase.appendingPathComponent("models")
    }

    public var isLoaded: Bool { container != nil }
    public var name: String { modelId }

    @discardableResult
    public func load() async throws -> TimeInterval {
        if container != nil { return 0 }
        let t0 = Date()
        // Told explicitly where models live, rather than left to the default.
        //
        // swift-transformers does not read HF_HOME or HUGGINGFACE_HUB_CACHE:
        // those are Python conventions, and it uses its own location under the
        // running user's Library/Caches. Under the daemon's service account
        // that resolves to /var/empty, so the download fails on a path no
        // configuration appeared to control. Setting downloadBase is the only
        // thing that actually moves it.
        container = try await LLMModelFactory.shared.loadContainer(
            hub: HubApi(downloadBase: Self.hubBase,
                        useOfflineMode: !Self.fetchAllowed),
            configuration: ModelConfiguration(id: modelId))
        return Date().timeIntervalSince(t0)
    }

    public func unload() -> TimeInterval {
        let t0 = Date()
        container = nil
        // Releasing the container is not enough on its own: MLX keeps a buffer
        // cache that would otherwise stay resident on a machine whose owner has
        // just come back.
        MLX.GPU.clearCache()
        return Date().timeIntervalSince(t0)
    }

    public var residentGb: Double {
        Double(MLX.GPU.snapshot().activeMemory) / 1_073_741_824
    }

    /// Generate a completion.
    ///
    /// The streaming overload is used rather than the batch one because it
    /// yields per token, which is what a mid-generation stop will need: a single
    /// request has no seam to yield at, and `maxCompletionTokens` bounds the
    /// worst case only because the loop can be cut short here.
    /// A completion and what it cost.
    ///
    /// The counts are not decoration. An interactive client drives its context
    /// gauge and its compaction from them, so reporting zero tells it the
    /// conversation is never filling up, and it will happily run past what the
    /// model accepts.
    public struct Completion: Sendable {
        public let text: String
        public let promptTokens: Int
        public let completionTokens: Int
        /// Calls the model asked for, parsed out of its output.
        ///
        /// Qualified because MLXLMCommon has its own `ToolCall`, and an
        /// unqualified name here would silently mean whichever the compiler
        /// preferred.
        public var toolCalls: [DaiAgent.ToolCall] = []
        /// Time spent reading the prompt, as MLX reports it. Kept for the log
        /// rather than for sizing, since it excludes tokenisation and template
        /// application and so understates the wait by two orders of magnitude.
        public var promptSeconds: Double = 0
        public var generateSeconds: Double = 0
    }

    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        try await complete(prompt: prompt, maxTokens: maxTokens).text
    }

    public func complete(prompt: String, maxTokens: Int,
                         tools: [DaiAgent.JSONValue]? = nil,
                         messages: [[String: String]]? = nil) async throws -> Completion {
        let started = Date()
        let out = try await generateCompletion(prompt: prompt, maxTokens: maxTokens,
                                               tools: tools, messages: messages)
        let elapsed = Date().timeIntervalSince(started)

        // Measured here rather than taken from MLX's promptTime, which reports
        // 0.36s for a request that took thirty seconds: it times the final
        // prefill step and not the tokenisation and template application around
        // it. The caller waits for the whole thing, so the whole thing is what
        // sizes the window.
        //
        // Generation is subtracted at the rate this model actually achieved, so
        // a long answer is not charged to the prompt.
        let generation = out.completionTokens > 0 && generationTokensPerSecond > 0
            ? Double(out.completionTokens) / generationTokensPerSecond
            : 0
        recordGenerationRate(tokens: out.completionTokens, seconds: out.generateSeconds)
        recordPromptRate(tokens: out.promptTokens, seconds: max(0.05, elapsed - generation))
        return out
    }

    private func generateCompletion(prompt: String, maxTokens: Int,
                                    tools: [DaiAgent.JSONValue]? = nil,
                                    messages: [[String: String]]? = nil) async throws -> Completion {
        guard let container else { throw Failure.notLoaded }
        let dialect = toolDialect
        let conversation = messages ?? [["role": "user", "content": prompt]]
        // Converted inside, because [[String: Any]] is not Sendable and cannot
        // cross into the closure.
        let hasTools = !(tools?.isEmpty ?? true)
        return try await container.perform { context in
            // Tools go through the model's own chat template rather than being
            // formatted here. Every family spells this differently, and the
            // template in the model directory is the authority on its own
            // format - hand-writing Llama's would be guessing at something the
            // model already ships.
            let specs = tools?.compactMap { $0.anyValue as? [String: Any] }
            let input = try await context.processor.prepare(
                input: .init(messages: conversation, tools: specs))
            // Greedy. Determinism matters for batch work, where the same item
            // dispatched to a different node after a requeue should not produce
            // a different answer.
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
                context: context)

            var text = ""
            var promptTokens = 0
            var completionTokens = 0
            var promptSeconds = 0.0
            var generateSeconds = 0.0
            for await item in stream {
                switch item {
                case let .chunk(chunk):
                    text += chunk
                case let .info(info):
                    // Reported by MLX at the end of the stream rather than
                    // estimated from the text, so the numbers are the model's
                    // own rather than a guess about its tokeniser.
                    promptTokens = info.promptTokenCount
                    completionTokens = info.generationTokenCount
                    promptSeconds = info.promptTime
                    generateSeconds = info.generateTime
                default:
                    break
                }
            }
            guard let dialect, hasTools else {
                return Completion(text: text, promptTokens: promptTokens,
                                  completionTokens: completionTokens,
                                  promptSeconds: promptSeconds,
                                  generateSeconds: generateSeconds)
            }
            let parsed = dialect.parseCalls(from: text)
            return Completion(text: parsed.text, promptTokens: promptTokens,
                              completionTokens: completionTokens,
                              toolCalls: parsed.calls, promptSeconds: promptSeconds,
                              generateSeconds: generateSeconds)
        }
    }

    /// The model's context window, read from its own configuration.
    ///
    /// Advertised so a client does not have to assume. A client guessing high
    /// runs a conversation past what the model accepts; guessing low wastes
    /// most of the window it paid for.
    /// The tool-call dialect this model speaks, chosen from its chat template.
    ///
    /// Read from disk rather than held on the loaded model, so it is available
    /// before the first generation and does not depend on the model being
    /// resident.
    public var toolDialect: ToolDialect? {
        let config = Self.modelDirectory
            .appendingPathComponent(modelId)
            .appendingPathComponent("tokenizer_config.json")
        let template = (try? Data(contentsOf: config))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0?["chat_template"] as? String }
        return ToolDialects.select(template: template, modelId: modelId)
    }

    /// Read from the model's own config.json rather than the loaded object,
    /// which does not expose it. That file is the source of truth every runtime
    /// reads, and it is on disk next to the weights whether or not the model is
    /// currently loaded.
    /// The window worth advertising, which is not the same as the one the
    /// model was built with.
    ///
    /// config.json reports the architectural maximum. A quantised 3B was
    /// bisected as coherent to about 8k and degrading from there: echoing its
    /// prompt by 10k, looping by 12k, collapsing to punctuation by 20k. Telling
    /// a client 131072 invites it to fill a window the model cannot use, and
    /// the failure then looks like a server fault rather than a model limit.
    ///
    /// So the advertised figure is capped by DAI_USABLE_CONTEXT when set. It is
    /// a judgement about a specific model on specific weights, which is why it
    /// is configuration rather than something inferred: nothing in the model
    /// directory records where it stops being coherent.
    public var contextLength: Int? {
        guard let architectural = architecturalContextLength else { return nil }
        var limit = architectural
        if let cap = ProcessInfo.processInfo.environment["DAI_USABLE_CONTEXT"],
           let usable = Int(cap), usable > 0 {
            limit = min(limit, usable)
        }
        if let measured = observedContextLimit {
            limit = min(limit, measured)
        }
        return limit
    }

    /// Prompt tokens this node can actually process inside the answer budget.
    ///
    /// Measured rather than configured, because it is a property of these
    /// weights on this hardware and nothing on disk records it. A 32B on an M2
    /// Max processes prompt at roughly 105 tokens/sec, so its 32k architectural
    /// window is about five minutes of prompt processing: the request times out
    /// long before the model runs out of context. Advertising 32768 there is
    /// not a small overstatement, it is a number no caller can reach.
    ///
    /// Nil until something has actually been generated. A guess before the
    /// first measurement would be the same mistake in a different direction.
    public var observedContextLimit: Int? {
        guard promptTokensPerSecond > 0 else { return nil }
        // Rounded down to something legible, and floored: a window too small to
        // hold a system prompt is not worth advertising at all.
        // Halved, because the rate keeps falling as the prompt grows and the
        // measurement always comes from a shorter one than the limit it is
        // being used to set.
        let affordable = Int(promptTokensPerSecond * Self.answerBudgetSeconds * 0.5)
        return max(2048, (affordable / 1024) * 1024)
    }

    /// How long an answer may take before the control plane gives up on it.
    ///
    /// Deliberately less than the dispatch timeout: the budget has to cover
    /// generating the reply as well as reading the prompt, and a window sized
    /// to the whole timeout leaves nothing for the answer.
    static let answerBudgetSeconds: Double = {
        let timeout = ProcessInfo.processInfo.environment["DAI_ANSWER_BUDGET_SECONDS"]
            .flatMap(Double.init) ?? 90
        return max(10, timeout)
    }()

    /// The slowest rate seen, not the average.
    ///
    /// Prompt processing is not linear in length: attention cost grows with it,
    /// and this model measured 155 tokens/sec on an 1.8k prompt against 104 on
    /// a 8.9k one. Averaging those, or taking the recent one, extrapolates a
    /// short prompt into a window the node cannot actually read - which is the
    /// same overstatement as advertising the architectural maximum, arrived at
    /// by arithmetic instead of by not looking.
    ///
    /// Taking the worst observed rate errs toward offering less than the node
    /// can do, and corrects upward only in the sense that longer prompts
    /// produce more honest samples as they arrive.
    private var promptTokensPerSecond: Double = 0

    /// Samples below this are too short to say anything about a long prompt.
    private static let minimumSampleTokens = 256

    /// Tracked only to subtract generation from the measured wall time, so a
    /// long answer is not mistaken for a slow prompt.
    private var generationTokensPerSecond: Double = 0

    private func recordGenerationRate(tokens: Int, seconds: Double) {
        guard tokens > 4, seconds > 0.05 else { return }
        let sample = Double(tokens) / seconds
        generationTokensPerSecond = generationTokensPerSecond == 0
            ? sample : generationTokensPerSecond * 0.7 + sample * 0.3
    }

    private func recordPromptRate(tokens: Int, seconds: Double) {
        guard tokens >= Self.minimumSampleTokens, seconds > 0.05 else { return }
        let sample = Double(tokens) / seconds
        promptTokensPerSecond = promptTokensPerSecond == 0
            ? sample
            : min(promptTokensPerSecond, sample)
    }

    private var architecturalContextLength: Int? {
        let config = Self.modelDirectory
            .appendingPathComponent(modelId)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Ordered by how much they can be trusted. text_config appears on
        // multimodal models, where the top level describes the wrapper rather
        // than the language model doing the generating.
        if let text = json["text_config"] as? [String: Any],
           let n = text["max_position_embeddings"] as? Int { return n }
        for key in ["max_position_embeddings", "max_sequence_length", "n_positions"] {
            if let n = json[key] as? Int { return n }
        }
        return nil
    }

    public enum Failure: Error, CustomStringConvertible {
        case notLoaded
        public var description: String { "MLX runtime not loaded" }
    }
}
