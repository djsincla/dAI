import Foundation
import Hub
import MLX
import Tokenizers
import MLXEmbedders

/// Vectors, locally, on the same model the fleet runs.
///
/// **Every decision here is copied from the agent's `EmbedRuntime` rather than
/// made again**, because a notebook embedded here and queried there must land
/// in the same space. The two are verified against one shared fixture, and the
/// list of what has to agree is short and unforgiving:
///
///     the model          Qwen3-Embedding-0.6B-8bit
///     pooling            last token, from each row's real length
///     prefixes           none for this model, query/document for nomic and E5
///     normalisation      applied here, so a dot product is a cosine
///
/// Getting any of them wrong produces vectors of the right width, in the right
/// range, comparable by cosine, that rank a corpus as noise. Nothing raises.
public actor Embedder {

    private final class Container {
        let raw: ModelContainer
        init(raw: ModelContainer) { self.raw = raw }
    }

    private var container: Container?
    public let modelId: String
    public let maxTokens: Int
    private let pooled: Pooled
    private let prefixes: Prefixes

    public init(modelId: String = NotebookPackage.Manifest.defaultModel,
                maxTokens: Int = 32768) {
        self.modelId = modelId
        self.maxTokens = maxTokens
        self.pooled = Pooled.forModel(modelId)
        self.prefixes = Prefixes.forModel(modelId)
    }

    // ------------------------------------------------------------ conventions

    /// How a sequence of token vectors becomes one vector.
    ///
    /// Chosen by model family rather than read from the model, because the
    /// model does not say. MLXEmbedders reads `1_Pooling/config.json` and falls
    /// back to no pooling when it is absent, and the mlx-community conversions
    /// ship no such directory: the library then returns raw hidden states,
    /// which are one vector per token rather than one per passage.
    public enum Pooled: String, Sendable {
        case mean, lastToken, cls

        public static func forModel(_ id: String) -> Pooled {
            id.lowercased().contains("qwen3") ? .lastToken : .mean
        }
    }

    /// What a model wants prepended to say what the text is for.
    ///
    /// Also not readable from the model. Sentence-transformers records these in
    /// `config_sentence_transformers.json`, and the MLX conversion of nomic's
    /// embedder ships `"prompts": {}` while still being a model that needs
    /// them. The strings match `examples/python/rag_embed.py` exactly.
    public struct Prefixes: Sendable, Equatable {
        public let query: String
        public let document: String
        public static let none = Prefixes(query: "", document: "")
        public static let nomic = Prefixes(query: "search_query: ",
                                           document: "search_document: ")
        public static let e5 = Prefixes(query: "query: ", document: "passage: ")

        public static func forModel(_ id: String) -> Prefixes {
            let name = id.lowercased()
            if name.contains("nomic") { return .nomic }
            if name.contains("e5") { return .e5 }
            return .none
        }

        func apply(_ text: String, intent: Intent) -> String {
            intent == .query ? query + text : document + text
        }
    }

    public enum Intent: String, Sendable { case query, document }

    public enum EmbedError: Error, CustomStringConvertible, Equatable {
        case tooLong(index: Int, tokens: Int, limit: Int)
        case noHiddenStates

        public var description: String {
            switch self {
            case let .tooLong(index, tokens, limit):
                return "input \(index) is \(tokens) tokens and the limit is "
                     + "\(limit). It is refused rather than truncated: a vector "
                     + "of the first \(limit) tokens is indistinguishable from a "
                     + "correct one and wrong."
            case .noHiddenStates:
                return "the model returned no hidden states to pool"
            }
        }
    }

    // ------------------------------------------------------------- lifecycle

    /// How much freed GPU memory MLX may keep for reuse.
    ///
    /// MLX holds on to buffers it has finished with, so the next allocation is
    /// cheap. That is right on a machine doing one thing and wrong on this one:
    /// a laptop embedding a corpus while its fleet agent serves a 30B model has
    /// no spare gigabytes, and an unbounded cache is indistinguishable from a
    /// leak from the outside. Half a gigabyte keeps batches cheap without
    /// competing with the model somebody is actually being served by.
    public static let gpuCacheLimit = 512 * 1024 * 1024

    /// Apply the cache limit before anything allocates.
    ///
    /// Called at launch as well as from ``load()``, because the limit only
    /// governs allocations that come after it and the first model load is a
    /// large one. Cheap and idempotent, so calling it twice costs nothing.
    public static func configureMemory() {
        MLX.GPU.set(cacheLimit: gpuCacheLimit)
    }

    /// MLX's own accounting of what it holds.
    ///
    /// `active` is memory inside live MLXArrays; `cache` is memory MLX has
    /// finished with and kept so the next allocation is cheap. **They are
    /// reported separately because they have different causes and different
    /// fixes**: active growth means something is holding arrays, cache growth
    /// means the limit is not taking effect. A single resident-size figure
    /// cannot tell them apart, and during the 8,894 page import it did not:
    /// footprint climbed 65 MB a minute and said nothing about which half.
    public struct Memory: Sendable, Equatable {
        public var active: Int
        public var cache: Int
        public var peak: Int

        public var resident: Int { active + cache }

        public var summary: String {
            func mb(_ bytes: Int) -> Int { bytes / 1_048_576 }
            return "\(mb(active)) MB active, \(mb(cache)) MB cached"
        }
    }

    public static func memory() -> Memory {
        let snapshot = MLX.GPU.snapshot()
        return Memory(active: snapshot.activeMemory,
                      cache: snapshot.cacheMemory,
                      peak: snapshot.peakMemory)
    }

    /// Hand MLX's recycling cache back to the system, now.
    ///
    /// **Defensive, not a fix for anything observed.** Measurement showed the
    /// cache limit already holding: through the 8,894 page import MLX sat at
    /// 603 MB active and 512 MB cached, exactly the limit, while the process
    /// footprint climbed by gigabytes for reasons that had nothing to do with
    /// MLX. It is kept because the limit is applied on deallocation rather than
    /// continuously, so a run that allocates faster than it frees could still
    /// overshoot, and because it returns the cache between documents rather
    /// than holding it for the life of the app.
    public func trim() {
        MLX.GPU.clearCache()
    }

    @discardableResult
    public func load() async throws -> TimeInterval {
        if container != nil { return 0 }
        Self.configureMemory()
        let started = Date()
        container = Container(raw: try await MLXEmbedders.loadModelContainer(
            configuration: ModelConfiguration(id: modelId)))
        return Date().timeIntervalSince(started)
    }

    public func unload() {
        container = nil
        MLX.GPU.clearCache()
    }

    public var isLoaded: Bool { container != nil }

    // ------------------------------------------------------------- embedding

    public func embed(_ texts: [String], intent: Intent = .document,
                      batch: Int = 16) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        if container == nil { try await load() }
        guard let container else { return [] }

        let prepared = texts.map { prefixes.apply($0, intent: intent) }

        // Sorted by length before batching, and put back afterwards.
        //
        // A batch is padded to its longest member, so mixing a short passage
        // with a long one makes the short one cost what the long one costs.
        // Restoring the order matters more than the speed: a permuted result
        // attaches every vector to the wrong text and nothing raises.
        let order = prepared.indices.sorted { prepared[$0].count < prepared[$1].count }
        var out = [[Float]](repeating: [], count: prepared.count)

        for start in stride(from: 0, to: order.count, by: batch) {
            let window = Array(order[start ..< min(start + batch, order.count)])
            let vectors = try await container.raw.perform { model, tokenizer, _ in
                try Self.vectors(for: window.map { prepared[$0] },
                               model: model, tokenizer: tokenizer,
                               pooled: pooled, limit: maxTokens)
            }
            for (offset, index) in window.enumerated() { out[index] = vectors[offset] }
        }
        return out
    }

    private static func vectors(for texts: [String], model: EmbeddingModel,
                                tokenizer: any Tokenizer, pooled: Pooled,
                                limit: Int) throws -> [[Float]] {
        var encoded: [[Int]] = []
        for (index, text) in texts.enumerated() {
            let ids = tokenizer.encode(text: text)
            guard ids.count <= limit else {
                throw EmbedError.tooLong(index: index, tokens: ids.count, limit: limit)
            }
            encoded.append(ids)
        }

        let width = encoded.map(\.count).max() ?? 0
        let pad = tokenizer.eosTokenId ?? 0
        let padded = encoded.map { $0 + Array(repeating: pad, count: width - $0.count) }
        let mask = encoded.map {
            Array(repeating: Int32(1), count: $0.count)
                + Array(repeating: Int32(0), count: width - $0.count)
        }

        let input = MLXArray(padded.flatMap { $0.map(Int32.init) },
                             [padded.count, width])
        let maskArray = MLXArray(mask.flatMap { $0 }, [mask.count, width])
        let output = model(input, positionIds: nil, tokenTypeIds: nil,
                           attentionMask: maskArray)
        guard let hidden = output.hiddenStates else { throw EmbedError.noHiddenStates }

        var out: [[Float]] = []
        for (row, ids) in encoded.enumerated() {
            let sequence = hidden[row]
            let vector: MLXArray
            switch pooled {
            // Pooled from this row's real length, not the padded end. The
            // library's own `.last` takes the final position of a padded
            // sequence, which for a short input in a long batch is padding.
            case .lastToken: vector = sequence[ids.count - 1]
            case .cls: vector = sequence[0]
            case .mean:
                vector = MLX.sum(sequence[0 ..< ids.count], axis: 0)
                       / MLXArray(Float(ids.count))
            }
            let norm = MLX.sqrt(MLX.sum(vector * vector))
            let unit = vector / MLX.maximum(norm, MLXArray(Float(1e-12)))
            unit.eval()
            out.append(unit.asArray(Float.self))
        }
        return out
    }
}
