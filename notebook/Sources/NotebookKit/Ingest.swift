import Foundation

/// Dropped file to stored vectors.
///
/// One document at a time, reporting as it goes, and cancellable at every step.
/// The steps are cheap until the last one: reading an 8,894 page PDF takes
/// forty seconds and embedding its chunks takes minutes, so a caller that
/// cannot see progress or stop it has an app that looks hung.
public actor Ingest {

    public enum Stage: Sendable, Equatable {
        case copying
        case extracting
        case chunking
        case embedding(done: Int, total: Int)
        case done(chunks: Int)
        case failed(String)
    }

    public struct Progress: Sendable, Equatable {
        public let document: String
        public let stage: Stage
    }

    private let package: NotebookPackage
    private let embedder: Embedder
    private let settings: Extraction.Settings

    public init(package: NotebookPackage, embedder: Embedder,
                settings: Extraction.Settings = .init()) {
        self.package = package
        self.embedder = embedder
        self.settings = settings
    }

    /// Add one document, reporting each stage.
    ///
    /// The original is copied into the package first, before anything can fail.
    /// A notebook that extracted a file and then lost it could never re-chunk,
    /// and re-chunking is the reason the originals are kept at all.
    public func add(_ url: URL, batch: Int = 16,
                    report: @Sendable @escaping (Progress) -> Void) async throws -> Int {
        let name = url.lastPathComponent
        func say(_ stage: Stage) { report(Progress(document: name, stage: stage)) }

        do {
            say(.copying)
            let stored = package.originalsURL.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: stored.path) {
                try FileManager.default.copyItem(at: url, to: stored)
            }
            try Task.checkCancellation()

            say(.extracting)
            let content = try DocumentReader.read(stored)
            try Task.checkCancellation()

            say(.chunking)
            let chunks = try chunks(from: content, name: name)
            guard !chunks.isEmpty else {
                throw Extraction.Failure.empty(name)
            }
            try Task.checkCancellation()

            // Embedded in batches so progress means something and cancelling
            // costs at most one batch. Writing per batch rather than at the end
            // also means an interrupted import leaves a shorter notebook rather
            // than an empty one.
            let store = try VectorStore(path: package.indexURL)
            var written = 0
            for start in stride(from: 0, to: chunks.count, by: batch) {
                try Task.checkCancellation()
                let window = Array(chunks[start ..< min(start + batch, chunks.count)])
                say(.embedding(done: written, total: chunks.count))
                let vectors = try await embedder.embed(window.map(\.text),
                                                       intent: .document)
                try await store.add(window.map(Self.stored), vectors: vectors)
                written += window.count
            }

            try await store.setMeta("backend", "mlx")
            try await store.setMeta("backend_state",
                                    BackendState(model: embedder.modelId,
                                                 max_length: embedder.maxTokens))
            try await store.setMeta("chunks", try await store.count())
            say(.done(chunks: written))
            return written
        } catch is CancellationError {
            // Not a failure. The chunks written so far are real and stay; the
            // document is simply not finished, which the caller can see.
            say(.failed("cancelled"))
            throw CancellationError()
        } catch {
            say(.failed("\(error)"))
            throw error
        }
    }

    /// The meta rag_ask.py reads to decide how to embed a question.
    ///
    /// Typed rather than a dictionary of strings: written as [String: String]
    /// once, which put max_length in the file as "32768" and made the reference
    /// client call the model with a string.
    struct BackendState: Encodable {
        let model: String
        let max_length: Int
    }

    private func chunks(from content: DocumentReader.Content,
                        name: String) throws -> [Extraction.Chunk] {
        switch content {
        case let .prose(text, pages):
            if pages.isEmpty {
                return try Extraction.prose(text, title: name, locator: name,
                                            settings: settings)
            }
            // Chunked per page so a citation can name one, which is the whole
            // reason the original is kept. A page too short to stand alone is
            // still its own chunk here: merging pages would produce a citation
            // that points at two places.
            var out: [Extraction.Chunk] = []
            for number in pages.keys.sorted() {
                guard let text = pages[number],
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                let pieces = (try? Extraction.prose(
                    text, title: "\(name) p\(number)",
                    locator: "\(name)#page=\(number)", settings: settings)) ?? []
                out.append(contentsOf: pieces)
            }
            return out

        case let .tables(tables):
            return try tables.flatMap { table in
                try Extraction.rows(of: table, locator: name)
            }
        }
    }

    private static func stored(_ chunk: Extraction.Chunk) -> VectorStore.Chunk {
        VectorStore.Chunk(citation: chunk.citation, section: chunk.section,
                          chapterName: "", url: chunk.locator,
                          part: chunk.part, parts: chunk.parts, text: chunk.text)
    }
}
