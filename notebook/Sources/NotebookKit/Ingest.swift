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
        /// Streaming a paged document: the total number of chunks is not known
        /// until the end, but the number of pages is known at the start, and
        /// that is the number somebody waiting an hour actually wants.
        case embeddingPage(page: Int, pages: Int, chunks: Int)
        case done(chunks: Int)
        case failed(String)
    }

    public struct Progress: Sendable, Equatable {
        public let document: String
        public let stage: Stage
        /// What MLX held when this was reported.
        ///
        /// Carried on every progress line rather than logged separately so that
        /// an import which grows can be seen growing, and seen in the two
        /// numbers that distinguish a leak from a cache. Watching Activity
        /// Monitor climb tells you something is wrong an hour after it started
        /// and never tells you what.
        public let memory: Embedder.Memory
    }

    /// Batches embedded between handing MLX's cache back.
    ///
    /// Not every batch: trimming makes the next batch re-allocate its buffers,
    /// which is the cost the cache exists to avoid. Every 32 batches is roughly
    /// every 500 chunks, about ten seconds on the VCF import.
    ///
    /// The memory that import actually lost was PDFKit's, not MLX's, and the
    /// fix for it is in `DocumentReader.reopenEvery`. This is the cheap belt to
    /// that braces.
    public static let trimEvery = 32

    /// Whether this flush is one of the ones that trims.
    ///
    /// Pure and separate so the cadence is testable, because nothing else here
    /// is: MLX will not run under `swift test`, so the only part of this fix a
    /// test can reach is the arithmetic that decides when to act.
    static func shouldTrim(afterFlushes flushes: Int,
                           every: Int = trimEvery) -> Bool {
        every > 0 && flushes > 0 && flushes.isMultiple(of: every)
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
        func say(_ stage: Stage) {
            report(Progress(document: name, stage: stage,
                            memory: Embedder.memory()))
        }

        do {
            say(.copying)
            let stored = package.originalsURL.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: stored.path) {
                try FileManager.default.copyItem(at: url, to: stored)
            }
            try Task.checkCancellation()

            say(.extracting)
            let store = try VectorStore(path: package.indexURL)
            var written = 0

            if DocumentReader.isPaged(stored) {
                // Streamed, so one page of text exists at a time rather than
                // the whole document plus its pages plus every chunk.
                //
                // Read whole, the VCF PDF is 21.7M characters held twice by the
                // reader and a third time as chunks, which is most of a
                // gigabyte of strings before anything is embedded and is what
                // exhausted a machine that was also serving a 30B model.
                var buffer: [Extraction.Chunk] = []
                var pagesSeen = 0
                var flushes = 0
                try DocumentReader.eachPage(of: stored) { number, pageCount, text in
                    try Task.checkCancellation()
                    pagesSeen = number
                    let pieces = (try? Extraction.prose(
                        text, title: "\(name) p\(number)",
                        locator: "\(name)#page=\(number)",
                        settings: settings)) ?? []
                    buffer.append(contentsOf: pieces)
                    if buffer.count >= batch {
                        let window = buffer
                        buffer = []
                        // Embedding is async and this closure is not, so the
                        // work is handed to the actor and waited for. Pages are
                        // read faster than they are embedded, and without this
                        // the buffer would grow to the whole document again.
                        written += try Self.flush(window, store: store,
                                                  embedder: embedder)
                        flushes += 1
                        if Self.shouldTrim(afterFlushes: flushes) {
                            Self.trim(embedder)
                        }
                        say(.embeddingPage(page: number, pages: pageCount,
                                           chunks: written))
                    }
                }
                if !buffer.isEmpty {
                    written += try Self.flush(buffer, store: store,
                                              embedder: embedder)
                }
                guard written > 0 else { throw Extraction.Failure.empty(name) }
            } else {
                let content = try DocumentReader.read(stored)
                try Task.checkCancellation()
                say(.chunking)
                let chunks = try chunks(from: content, name: name)
                guard !chunks.isEmpty else { throw Extraction.Failure.empty(name) }
                var flushes = 0
                for start in stride(from: 0, to: chunks.count, by: batch) {
                    try Task.checkCancellation()
                    let window = Array(chunks[start ..< min(start + batch, chunks.count)])
                    say(.embedding(done: written, total: chunks.count))
                    let vectors = try await embedder.embed(window.map(\.text),
                                                           intent: .document)
                    try await store.add(window.map(Self.stored), vectors: vectors)
                    written += window.count
                    flushes += 1
                    if Self.shouldTrim(afterFlushes: flushes) {
                        await embedder.trim()
                    }
                }
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

    /// Embed one buffer and write it, synchronously from the page walk.
    ///
    /// Blocking here is deliberate: pages are read far faster than they are
    /// embedded, and letting the walk run ahead would rebuild in the buffer
    /// exactly the whole-document copy this streaming exists to avoid.
    private static func flush(_ chunks: [Extraction.Chunk], store: VectorStore,
                              embedder: Embedder) throws -> Int {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result<Int, Error>?
        Task.detached {
            do {
                let vectors = try await embedder.embed(chunks.map(\.text),
                                                       intent: .document)
                try await store.add(chunks.map(Self.stored), vectors: vectors)
                outcome = .success(chunks.count)
            } catch {
                outcome = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try outcome!.get()
    }

    /// Trim from the page walk, which is not async.
    ///
    /// The same hop through a detached task that `flush` makes, and for the same
    /// reason: `DocumentReader.eachPage` hands back a plain closure and the
    /// embedder is an actor.
    private static func trim(_ embedder: Embedder) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await embedder.trim()
            semaphore.signal()
        }
        semaphore.wait()
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
