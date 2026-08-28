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
        return urls.map { url in
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Source(name: url.lastPathComponent,
                          kind: kind(for: url), bytes: bytes,
                          state: .ready(chunks: 0))
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

    // ------------------------------------------------------------- asking

    /// Placeholder until the embedder lands.
    ///
    /// It refuses rather than inventing an answer, and says which step is
    /// missing. A shell that returns plausible text would make the rest of the
    /// app impossible to judge.
    var canAsk: Bool { false }
    var whyNotAsking: String {
        "Asking needs the embedder, which is step 3. Retrieval and generation "
        + "are wired to nothing yet, so this box would return an invented "
        + "answer and there would be no way to tell."
    }
}
