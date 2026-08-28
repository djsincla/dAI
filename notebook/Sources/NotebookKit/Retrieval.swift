import Foundation

/// Asking a notebook, which is embedding a question and scoring it.
///
/// Separate from the store so the settings that shape an answer live in one
/// place and get recorded with it: k, the per-section cap, and which model
/// produced the vectors. Two turns are only comparable if all three are known,
/// which is the difference between a record and a transcript.
public struct Retrieval: Sendable {

    public struct Settings: Sendable, Equatable {
        public var k: Int
        public var perSection: Int

        public init(k: Int = 6, perSection: Int = 2) {
            self.k = k
            self.perSection = perSection
        }
    }

    public struct Hit: Sendable, Equatable {
        public let chunk: VectorStore.Chunk
        public let score: Float
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case modelMismatch(notebook: String, asked: String)
        case emptyNotebook
        case emptyQuestion

        public var description: String {
            switch self {
            case let .modelMismatch(notebook, asked):
                return "This notebook was embedded with \(notebook) and the "
                     + "question was embedded with \(asked). Vectors from two "
                     + "models are not comparable: the scores would look "
                     + "ordinary and the ranking would be noise."
            case .emptyNotebook:
                return "This notebook has no chunks yet. Add a document first."
            case .emptyQuestion:
                return "Ask something."
            }
        }
    }

    /// Retrieve for one question.
    ///
    /// The model is checked against the notebook before anything is embedded.
    /// It is the one error in this file that cannot be seen in the output:
    /// a mismatch produces scores in the ordinary range and a ranking that is
    /// unrelated to the question, which reads as a bad model rather than a bug.
    public static func search(question: String, in package: NotebookPackage,
                              using embedder: Embedder,
                              settings: Settings = .init()) async throws -> [Hit] {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyQuestion }

        let manifest = try package.manifest()
        guard manifest.embeddingModel == embedder.modelId else {
            throw Failure.modelMismatch(notebook: manifest.embeddingModel,
                                        asked: embedder.modelId)
        }

        let store = try VectorStore(path: package.indexURL, create: false)
        guard try await store.count() > 0 else { throw Failure.emptyNotebook }

        let vector = try await embedder.embed([trimmed], intent: .query)[0]
        return try await store.search(vector, k: settings.k,
                                      perSection: settings.perSection)
            .map { Hit(chunk: $0.chunk, score: $0.score) }
    }
}
