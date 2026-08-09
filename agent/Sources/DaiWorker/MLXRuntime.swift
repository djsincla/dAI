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
    public static var modelDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["DAI_MODEL_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return URL.cachesDirectory
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
            hub: HubApi(downloadBase: Self.modelDirectory,
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
    }

    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        try await complete(prompt: prompt, maxTokens: maxTokens).text
    }

    public func complete(prompt: String, maxTokens: Int) async throws -> Completion {
        guard let container else { throw Failure.notLoaded }
        return try await container.perform { context in
            let input = try await context.processor.prepare(
                input: .init(messages: [["role": "user", "content": prompt]]))
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
            return Completion(text: text, promptTokens: promptTokens,
                              completionTokens: completionTokens)
        }
    }

    /// The model's context window, read from its own configuration.
    ///
    /// Advertised so a client does not have to assume. A client guessing high
    /// runs a conversation past what the model accepts; guessing low wastes
    /// most of the window it paid for.
    /// Read from the model's own config.json rather than the loaded object,
    /// which does not expose it. That file is the source of truth every runtime
    /// reads, and it is on disk next to the weights whether or not the model is
    /// currently loaded.
    public var contextLength: Int? {
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
