import Foundation
import NotebookKit
import Observation

/// The embedding model, loaded once and shared by every window.
///
/// Cold loading Qwen3-Embedding-0.6B measured 68 seconds. Paying that on the
/// first question would make the app feel broken exactly when somebody is
/// deciding whether it works, so it is paid when a notebook opens instead,
/// while they are reading it.
///
/// Shared rather than per window because it is one model in memory. Two windows
/// onto two notebooks that use the same model should not load it twice, and on
/// a machine that is also serving the fleet, holding two copies is the
/// difference between polite and rude.
@Observable
@MainActor
final class EmbeddingService {

    enum State: Equatable {
        case idle
        case warming(model: String)
        case ready(model: String, seconds: TimeInterval)
        case unsupported(model: String, why: String)
        case failed(model: String, why: String)

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    private(set) var state: State = .idle
    private var embedder: Embedder?
    private var loading: Task<Void, Never>?

    /// Whether this app can query a notebook embedded with the given backend.
    ///
    /// bm25 is not a model: its state is a vocabulary and an idf table built by
    /// `rag_embed.py`, and this app has no lexical backend. Such a notebook is
    /// readable and searchable by `rag_ask.py` and not by this window, which is
    /// worth saying plainly rather than leaving a question box that never
    /// returns anything.
    /// The architectures Swift MLXEmbedders actually registers.
    ///
    /// bert, roberta, xlm-roberta, distilbert, nomic_bert and qwen3. Notably
    /// **not modernbert**, which the Python package does have: the two
    /// implementations support almost disjoint sets, and the VCF corpus was
    /// embedded with nomic's ModernBERT before that was known. An index built
    /// there cannot be queried here, and finding that out as
    /// `EmbedderError("Unsupported model type.")` at the bottom of a window is
    /// worse than being told.
    static func architecture(of model: String) -> String? {
        let name = model.lowercased()
        if name.contains("modernbert") {
            return "ModernBERT, which Swift MLXEmbedders does not implement. "
                 + "The Python package does, so rag_ask.py can query this "
                 + "notebook. Re-embedding it with Qwen3 would make it "
                 + "queryable here and would replace the index."
        }
        return nil
    }

    static func support(for model: String) -> String? {
        if let why = architecture(of: model) {
            return "This notebook was embedded with \(why)"
        }
        switch model {
        case "bm25", "lexical", "hashed":
            return "This notebook was indexed with bm25, which is a vocabulary "
                 + "rather than a model. rag_ask.py can query it; this app "
                 + "cannot, and re-embedding it would replace the index."
        case let m where m.contains("MiniLM") || m.contains("sentence-transformers"):
            return "This notebook was embedded by sentence-transformers, which "
                 + "runs under Python. Its vectors are fine and rag_ask.py can "
                 + "query them; this app embeds with MLX and cannot reproduce "
                 + "them, and a query from a different model would rank the "
                 + "corpus as noise."
        default:
            return nil
        }
    }

    /// Load the model a notebook needs, if it is not already loaded.
    ///
    /// Cancels a warm that is still running for a different model: opening two
    /// notebooks quickly should end with the second one's model loaded, not
    /// with whichever finished last.
    func warm(for model: String) {
        if case .ready(let loaded, _) = state, loaded == model { return }
        if case .warming(let loading) = state, loading == model { return }

        if let why = Self.support(for: model) {
            state = .unsupported(model: model, why: why)
            return
        }

        loading?.cancel()
        state = .warming(model: model)
        loading = Task { [weak self] in
            let embedder = Embedder(modelId: model)
            do {
                let seconds = try await embedder.load()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.embedder = embedder
                    self?.state = .ready(model: model, seconds: seconds)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    // Named rather than swallowed. The usual cause is weights
                    // that are not on this machine, and a question box that
                    // silently does nothing would send somebody looking at the
                    // notebook instead of at the model.
                    self?.state = .failed(model: model,
                                          why: "\(error)")
                }
            }
        }
    }

    /// The loaded embedder, or nil while it is still warming.
    func ready(for model: String) -> Embedder? {
        guard case .ready(let loaded, _) = state, loaded == model else { return nil }
        return embedder
    }

    /// What to show while this is happening.
    var summary: String? {
        switch state {
        case .idle: return nil
        case let .warming(model): return "Loading \(Self.short(model))…"
        case let .ready(model, seconds):
            return String(format: "%@ ready in %.0fs", Self.short(model), seconds)
        case let .unsupported(model, _): return "\(Self.short(model)): read only"
        case let .failed(model, _): return "\(Self.short(model)) failed to load"
        }
    }

    var detail: String? {
        switch state {
        case let .unsupported(_, why): return why
        case let .failed(_, why): return why
        default: return nil
        }
    }

    static func short(_ model: String) -> String {
        String(model.split(separator: "/").last ?? "")
    }
}
