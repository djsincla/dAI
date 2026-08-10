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
    }

    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        try await complete(prompt: prompt, maxTokens: maxTokens).text
    }

    public func complete(prompt: String, maxTokens: Int,
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
                default:
                    break
                }
            }
            guard let dialect, hasTools else {
                return Completion(text: text, promptTokens: promptTokens,
                                  completionTokens: completionTokens)
            }
            let parsed = dialect.parseCalls(from: text)
            return Completion(text: parsed.text, promptTokens: promptTokens,
                              completionTokens: completionTokens,
                              toolCalls: parsed.calls)
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
        guard let cap = ProcessInfo.processInfo.environment["DAI_USABLE_CONTEXT"],
              let usable = Int(cap), usable > 0 else { return architectural }
        return min(architectural, usable)
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
