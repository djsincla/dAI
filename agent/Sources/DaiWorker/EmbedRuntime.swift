import DaiAgent
import Foundation
import Hub
import MLX
import MLXEmbedders

/// Embedding models on the GPU through MLX, for `/v1/embeddings`.
///
/// Shaped like `MLXRuntime` deliberately: an actor holding one model, loaded on
/// demand and released on request, so the worker can treat both the same way
/// when a machine's owner comes back.
///
/// It is a different proposition from generation in two ways that make it
/// easier to schedule, and the dispatch side should use both. There is no KV
/// cache and no session, so any node holding the model can answer any request
/// and nothing is warm. And a preempted request costs a retry rather than a
/// conversation, which makes embedding the ideal harvest workload even on the
/// GPU.
///
/// See docs/EMBEDDINGS_PLAN.md for why this exists before the Core ML path,
/// and for what the Core ML path still buys that this does not.
public actor EmbedRuntime {
    private let modelId: String
    private var container: ModelContainer?

    /// Longest input this model can read, in tokens.
    ///
    /// Defaults to Qwen3-Embedding's 32,768. A caller staging a different model
    /// must set this: the number is a property of the weights, and a default
    /// that is too generous turns the refusal below into silent truncation
    /// inside the model, which is the one outcome this is here to prevent.
    ///
    /// Not a truncation limit. Over-length input is refused, because embedding
    /// the first 8,192 tokens of a longer passage returns a vector of the right
    /// shape, in the right range, cosine comparable, and wrong. The caller
    /// cannot see that happened and neither can anything downstream: it
    /// surfaces weeks later as bad retrieval. Truncating quietly is the exact
    /// class of defect the 404 was protecting against, so the limit is a
    /// refusal with the measured length in it.
    public let maxTokens: Int

    private let prefixes: Prefixes

    public init(modelId: String, maxTokens: Int = 32768,
                prefixes: Prefixes? = nil) {
        self.modelId = modelId
        self.maxTokens = maxTokens
        self.prefixes = prefixes ?? Prefixes.forModel(modelId)
    }

    public var name: String { modelId }

    // ------------------------------------------------------------- prefixes

    /// What a model wants prepended to say whether text is a query or a passage.
    ///
    /// **This cannot be read from the model, which is the surprising part.**
    /// Nomic and E5 models are trained with a prefix declaring the text's role,
    /// and the same words embedded as a query and as a document land in
    /// measurably different places: 0.80 cosine, not 1.0, for one string put
    /// through both. Get it backwards and retrieval degrades with no error and
    /// nothing visible in the vector.
    ///
    /// Sentence-transformers records these in `config_sentence_transformers.json`
    /// under `prompts`, so reading the model's own config is the obvious answer
    /// and it does not work. The MLX conversion of nomic's ModernBERT embedder
    /// ships `"prompts": {}` - the conversion dropped them - while still being a
    /// model that requires them. A server trusting that config would apply no
    /// prefix to a model that needs one, silently.
    ///
    /// So the convention is carried here, keyed by model family, and an index
    /// built by one implementation is only comparable to queries from another if
    /// both agree. `examples/python/rag_embed.py` uses these same two strings;
    /// changing one without the other invalidates every index built with it.
    public struct Prefixes: Sendable, Equatable {
        public let query: String
        public let document: String

        public static let none = Prefixes(query: "", document: "")
        public static let nomic = Prefixes(query: "search_query: ",
                                           document: "search_document: ")
        /// E5 and BGE use a different pair, and only on the query side.
        public static let e5 = Prefixes(query: "query: ", document: "passage: ")

        public init(query: String, document: String) {
            self.query = query
            self.document = document
        }

        /// Matched on the model id, since the weights do not say.
        public static func forModel(_ id: String) -> Prefixes {
            let name = id.lowercased()
            if name.contains("nomic") { return .nomic }
            if name.contains("e5") { return .e5 }
            return .none
        }

        public func apply(_ text: String, intent: Intent) -> String {
            switch intent {
            case .query: return query + text
            case .document: return document + text
            }
        }
    }

    /// What the text is for. A request that does not say is a document, because
    /// a corpus is embedded far more often than a question is.
    public enum Intent: String, Sendable {
        case query
        case document
    }

    // ------------------------------------------------------------- lifecycle

    @discardableResult
    public func load() async throws -> TimeInterval {
        if container != nil { return 0 }
        let t0 = Date()
        // Same hub arrangement and the same reasons as MLXRuntime: swift
        // transformers ignores the Python cache variables and resolves to a
        // path the daemon's account cannot write, and a fleet sold on data
        // staying in the building should not fetch weights from the internet on
        // first use.
        container = try await MLXEmbedders.loadModelContainer(
            hub: HubApi(downloadBase: MLXRuntime.hubBase,
                        useOfflineMode: !MLXRuntime.fetchAllowed),
            configuration: ModelConfiguration(id: modelId))
        return Date().timeIntervalSince(t0)
    }

    @discardableResult
    public func unload() -> TimeInterval {
        let t0 = Date()
        container = nil
        MLX.GPU.clearCache()
        return Date().timeIntervalSince(t0)
    }

    public var isLoaded: Bool { container != nil }

    // ------------------------------------------------------------- embedding

    public enum EmbedError: Error, CustomStringConvertible, Equatable {
        case notLoaded
        case empty
        case tooLong(index: Int, tokens: Int, limit: Int)

        public var description: String {
            switch self {
            case .notLoaded:
                return "the embedding model is not loaded"
            case .empty:
                return "input is empty"
            case let .tooLong(index, tokens, limit):
                return "input \(index) is \(tokens) tokens and the limit is "
                     + "\(limit). It is refused rather than truncated: a vector "
                     + "of the first \(limit) tokens is indistinguishable from a "
                     + "correct one and wrong. Split the text and embed the parts."
            }
        }
    }

    /// Vectors for each input, in the order given.
    ///
    /// Normalised to unit length, so a caller scoring with a dot product gets
    /// cosine. An unnormalised vector turns that dot product into something
    /// that is not cosine and quietly favours longer passages, which is another
    /// failure that looks like a working system returning poor answers.
    public func embed(_ texts: [String], intent: Intent = .document)
        async throws -> [[Float]]
    {
        guard let container else { throw EmbedError.notLoaded }
        if texts.isEmpty { throw EmbedError.empty }

        let prepared = texts.map { prefixes.apply($0, intent: intent) }

        return try await container.perform { model, tokenizer, pooling in
            var encoded: [[Int]] = []
            for (i, text) in prepared.enumerated() {
                let ids = tokenizer.encode(text: text)
                guard ids.count <= maxTokens else {
                    throw EmbedError.tooLong(index: i, tokens: ids.count,
                                             limit: maxTokens)
                }
                encoded.append(ids)
            }

            // Padded to the longest in the batch, with a mask so the padding
            // takes no part in the pooling. Without the mask, mean pooling
            // averages the padding in and a short input in a batch with a long
            // one gets a different vector than it would alone, which makes a
            // result depend on what it was batched with.
            let width = encoded.map(\.count).max() ?? 0
            let padId = tokenizer.eosTokenId ?? 0
            let padded = encoded.map { $0 + Array(repeating: padId,
                                                  count: width - $0.count) }
            let mask = encoded.map {
                Array(repeating: Int32(1), count: $0.count)
                    + Array(repeating: Int32(0), count: width - $0.count)
            }

            let input = MLXArray(padded.flatMap { $0.map(Int32.init) },
                                 [padded.count, width])
            let maskArray = MLXArray(mask.flatMap { $0 }, [mask.count, width])

            let output = model(input, positionIds: nil, tokenTypeIds: nil,
                               attentionMask: maskArray)
            let pooled = pooling(output, mask: maskArray, normalize: true,
                                 applyLayerNorm: false)
            pooled.eval()

            let dims = pooled.shape[1]
            let flat = pooled.asArray(Float.self)
            return (0 ..< texts.count).map { row in
                Array(flat[(row * dims) ..< ((row + 1) * dims)])
            }
        }
    }
}
