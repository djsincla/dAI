import Foundation
import NotebookKit
import Observation

/// What the window is looking at.
///
/// `@Observable` rather than `ObservableObject`: observation is per property, so
/// appending a turn does not redraw the source list and adding a source does not
/// redraw the record. That matters here because both lists are long and the
/// record grows for as long as the notebook is useful.
@Observable
@MainActor
final class NotebookModel {
    private(set) var package: NotebookPackage?
    private(set) var manifest: NotebookPackage.Manifest?
    private(set) var turns: [NotebookPackage.Turn] = []
    private(set) var sources: [Source] = []
    private(set) var chunkCount = 0

    /// What went wrong, phrased for somebody who did not write this.
    var problem: String?

    /// A document in the notebook, and how far through the pipeline it is.
    struct Source: Identifiable, Hashable {
        enum State: Hashable {
            case pending
            case extracting
            case embedding(done: Int, total: Int)
            case ready(chunks: Int)
            case failed(String)
        }
        let id = UUID()
        var name: String
        var kind: Kind
        var bytes: Int
        var state: State
        /// Off means its chunks are skipped at query time. They stay in the
        /// index, so this costs nothing and is instantly reversible.
        var enabled: Bool = true

        enum Kind: String {
            case text, pdf, csv, excel
            /// SF Symbol. Chosen per kind because the table and prose split is
            /// the thing worth seeing at a glance in this list.
            var symbol: String {
                switch self {
                case .text: return "doc.text"
                case .pdf: return "doc.richtext"
                case .csv: return "tablecells"
                case .excel: return "tablecells.badge.ellipsis"
                }
            }
        }
    }

    var isOpen: Bool { package != nil }
    var title: String { manifest?.name ?? "No notebook" }

    /// What the window says under its title.
    ///
    /// The embedding model is here rather than in a settings pane: a notebook
    /// is only comparable with vectors from the model that made it, and two
    /// windows open side by side is exactly when that matters.
    var subtitle: String {
        guard let manifest else { return "" }
        let short = manifest.embeddingModel.split(separator: "/").last ?? ""
        return "\(chunkCount) chunks  ·  \(short)"
    }

    // ------------------------------------------------------------- opening

    func open(_ url: URL) {
        do {
            let package = NotebookPackage(root: url)
            guard package.isValid else {
                problem = "\(url.lastPathComponent) is not a notebook: it has no "
                        + "notebook.json."
                return
            }
            self.package = package
            self.manifest = try package.manifest()
            self.turns = try package.turns()
            self.sources = try Self.readSources(package)
            self.chunkCount = (try? Self.countChunks(package)) ?? 0
            self.problem = nil
        } catch {
            problem = "Could not open \(url.lastPathComponent): \(error)"
        }
    }

    private static func readSources(_ package: NotebookPackage) throws -> [Source] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: package.originalsURL,
            includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let off = Set((try? package.manifest().disabledSources) as? [String] ?? [])
        return urls.map { url in
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Source(name: url.lastPathComponent,
                          kind: kind(for: url), bytes: bytes,
                          state: .ready(chunks: 0),
                          enabled: !off.contains(url.lastPathComponent))
        }.sorted { $0.name < $1.name }
    }

    private static func kind(for url: URL) -> Source.Kind {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        case "csv", "tsv": return .csv
        case "xlsx", "xls": return .excel
        default: return .text
        }
    }

    private static func countChunks(_ package: NotebookPackage) throws -> Int {
        guard FileManager.default.fileExists(atPath: package.indexURL.path) else {
            return 0
        }
        // Opened without creating: a notebook whose index has been discarded
        // should report no chunks rather than quietly grow an empty one.
        let store = try VectorStore(path: package.indexURL, create: false)
        return try Self.blocking { try await store.count() }
    }

    /// Bridge for the two synchronous reads above.
    ///
    /// Deliberately small and deliberately named. Everything on the write path
    /// is async and stays async; these two run once when a notebook is opened
    /// and blocking briefly is better than an empty window that fills in later.
    private static func blocking<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await work()) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }

    // ------------------------------------------------------------ ingesting

    private(set) var working: String?
    /// Files dropped before the model finished loading.
    ///
    /// Held rather than refused. Loading takes about a minute and dropping a
    /// document into a new notebook is the first thing anybody does.
    private(set) var queued: [URL] = []
    private var job: Task<Void, Never>?

    func enqueue(_ urls: [URL]) {
        queued.append(contentsOf: urls)
        working = "\(queued.count) waiting for the model…"
    }

    func startQueued(using embedder: Embedder) {
        guard !queued.isEmpty, job == nil || working == nil else { return }
        let urls = queued
        queued = []
        add(urls, using: embedder)
    }

    /// Add dropped files, one at a time, reporting as they go.
    ///
    /// Sequential rather than parallel. Embedding is already using the whole
    /// GPU, so two documents at once finish no sooner and make the progress
    /// meaningless.
    func add(_ urls: [URL], using embedder: Embedder) {
        guard let package else { return }
        job?.cancel()
        job = Task { [weak self] in
            let ingest = Ingest(package: package, embedder: embedder)
            for url in urls {
                if Task.isCancelled { break }
                do {
                    _ = try await ingest.add(url) { progress in
                        Task { @MainActor in self?.note(progress) }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    await MainActor.run { self?.problem = "\(error)" }
                }
            }
            await MainActor.run {
                self?.working = nil
                self?.reload()
            }
        }
    }

    func cancelWork() { job?.cancel(); working = nil }

    private func note(_ progress: Ingest.Progress) {
        switch progress.stage {
        case .copying: working = "Copying \(progress.document)…"
        case .extracting: working = "Reading \(progress.document)…"
        case .chunking: working = "Chunking \(progress.document)…"
        case let .embedding(done, total):
            working = "Embedding \(progress.document): \(done) of \(total)"
        case let .done(chunks):
            working = nil
            problem = nil
            _ = chunks
        case let .failed(why):
            working = nil
            if why != "cancelled" { problem = "\(progress.document): \(why)" }
        }
    }

    /// Re-read what is on disk, after ingesting or deleting.
    func reload() {
        guard let package else { return }
        sources = (try? Self.readSources(package)) ?? []
        chunkCount = (try? Self.countChunks(package)) ?? 0
        turns = (try? package.turns()) ?? []
    }

    /// Switch a source on or off for future questions.
    ///
    /// Written to the manifest immediately, because the state of the notebook
    /// when a question was asked is part of the record and a toggle that only
    /// existed in memory would make the record wrong.
    func setEnabled(_ enabled: Bool, for name: String) {
        guard let package else { return }
        do {
            var manifest = try package.manifest()
            var off = Set(manifest.disabledSources ?? [])
            if enabled { off.remove(name) } else { off.insert(name) }
            manifest.disabledSources = off.isEmpty ? nil : off.sorted()
            try package.write(manifest)
            self.manifest = manifest
            if let index = sources.firstIndex(where: { $0.name == name }) {
                sources[index].enabled = enabled
            }
        } catch {
            problem = "Could not change \(name): \(error.localizedDescription)"
        }
    }

    var activeSources: [String] { sources.filter(\.enabled).map(\.name) }

    // ------------------------------------------------------------- asking

    private(set) var asking = false
    private(set) var lastHits: [Retrieval.Hit] = []

    var canAsk: Bool { isOpen && chunkCount > 0 && !asking && working == nil }

    var whyNotAsking: String {
        if !isOpen { return "Open a notebook first." }
        if chunkCount == 0 { return "Add a document first: this notebook has no chunks." }
        if working != nil { return "Wait for the current document to finish." }
        return ""
    }

    /// Retrieve, then ask the fleet, then record all of it.
    ///
    /// Retrieval is local and instant; generation is a request to another
    /// machine that takes seconds. The citations are published as soon as they
    /// exist so the window has something true on it while the answer is being
    /// written, which is both more informative than a spinner and the only
    /// honest thing to show: nothing streams, because a completion is
    /// dispatched as one unit so a preemption has a bounded worst case.
    func ask(_ question: String, using embedder: Embedder,
             gateway: Gateway?, settings: Retrieval.Settings = .init()) {
        guard let package, !asking else { return }
        asking = true
        let started = Date()
        Task { [weak self] in
            do {
                let hits = try await Retrieval.search(
                    question: question, in: package, using: embedder,
                    settings: settings)
                await MainActor.run { self?.lastHits = hits }

                let manifest = try package.manifest()
                var answer = "Retrieval only: \(hits.count) passages found."
                var node: String?
                var presence: String?
                var generation: String?

                if let gateway {
                    // Only the last few turns travel. The whole record would
                    // eventually exceed the model's window, and the cost of
                    // trimming is that a question about something said twenty
                    // turns ago is answered from the passages instead.
                    let history = await MainActor.run {
                        (self?.turns.suffix(6) ?? []).map {
                            (question: $0.question, answer: $0.answer)
                        }
                    }
                    let reply = try await gateway.answer(
                        question: question,
                        passages: hits.map { ($0.chunk.citation, $0.chunk.text) },
                        history: Array(history),
                        model: GatewaySettings.model.isEmpty
                            ? nil : GatewaySettings.model)
                    answer = reply.text
                    node = reply.node
                    presence = reply.presenceState
                    generation = reply.model
                }

                let turn = NotebookPackage.Turn(
                    question: question, answer: answer,
                    citations: hits.map {
                        .init(citation: $0.chunk.citation, section: $0.chunk.section,
                              url: $0.chunk.url, score: $0.score)
                    },
                    k: settings.k, hybrid: false,
                    embeddingModel: manifest.embeddingModel,
                    answeredBy: node, presenceState: presence,
                    generationModel: generation,
                    seconds: Date().timeIntervalSince(started),
                    sources: await MainActor.run { self?.activeSources } ?? [])
                try package.append(turn)
                await MainActor.run {
                    self?.turns.append(turn)
                    self?.asking = false
                }
            } catch {
                await MainActor.run {
                    self?.problem = "\(error)"
                    self?.asking = false
                }
            }
        }
    }
}
