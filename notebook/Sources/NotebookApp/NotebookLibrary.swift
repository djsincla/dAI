import Foundation
import NotebookKit
import Observation

/// The notebooks on disk, as a list.
///
/// A notebook is still a file the user owns; this is a shelf, not a database.
/// The library is a folder, every notebook in it is a package that can be moved
/// out, mailed, or opened from anywhere, and nothing here is the source of
/// truth for a notebook's contents. That distinction is what keeps "open any
/// .dainotebook" working alongside a list.
@Observable
@MainActor
final class NotebookLibrary {
    private(set) var notebooks: [Entry] = []
    var problem: String?

    /// Where new notebooks are made. Chosen rather than hidden in Application
    /// Support: these are documents, and a document the user cannot find in the
    /// Finder is a document they do not really own.
    let root: URL

    struct Entry: Identifiable, Hashable {
        let id: URL
        var name: String
        var sourceCount: Int
        var turnCount: Int
        var modified: Date
        var url: URL { id }
    }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/notebookMLX", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        notebooks = urls
            .filter { $0.pathExtension == NotebookPackage.fileExtension }
            .compactMap { url -> Entry? in
                let package = NotebookPackage(root: url)
                guard package.isValid else { return nil }
                let manifest = try? package.manifest()
                let sources = (try? fm.contentsOfDirectory(
                    atPath: package.originalsURL.path))?.count ?? 0
                let turns = (try? package.turns().count) ?? 0
                let modified = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return Entry(id: url,
                             name: manifest?.name ?? url.deletingPathExtension()
                                 .lastPathComponent,
                             sourceCount: sources, turnCount: turns,
                             modified: modified)
            }
            .sorted { $0.modified > $1.modified }
    }

    // ------------------------------------------------------------ making

    @discardableResult
    func create(named name: String = "Untitled Notebook") -> URL? {
        do {
            let url = availableURL(for: name)
            try NotebookPackage.create(at: url, manifest: .init(name: name))
            reload()
            return url
        } catch {
            problem = "Could not create a notebook: \(error.localizedDescription)"
            return nil
        }
    }

    /// A copy, including its sources and its record.
    ///
    /// Everything is copied, not only the manifest. A duplicate that shared its
    /// originals would be one deletion away from taking the original's sources
    /// with it, and a duplicate without its record would silently discard the
    /// work: the record is the document.
    @discardableResult
    func duplicate(_ entry: Entry) -> URL? {
        do {
            let url = availableURL(for: "\(entry.name) copy")
            try FileManager.default.copyItem(at: entry.url, to: url)
            // The name inside the manifest, so the list and the window agree.
            let package = NotebookPackage(root: url)
            var manifest = try package.manifest()
            manifest.name = url.deletingPathExtension().lastPathComponent
            try package.write(manifest)
            reload()
            return url
        } catch {
            problem = "Could not duplicate \(entry.name): \(error.localizedDescription)"
            return nil
        }
    }

    /// To the Trash, never `removeItem`.
    ///
    /// A notebook holds the originals somebody dropped in, and those are the
    /// half of it that cannot be rebuilt. Unlinking them would make a
    /// mis-click unrecoverable; the Trash makes it a mistake somebody can undo,
    /// which is what the platform does everywhere else and what people expect.
    func delete(_ entry: Entry) {
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: &trashed)
            reload()
        } catch {
            problem = "Could not delete \(entry.name): \(error.localizedDescription)"
        }
    }

    func rename(_ entry: Entry, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        do {
            let package = NotebookPackage(root: entry.url)
            var manifest = try package.manifest()
            manifest.name = trimmed
            try package.write(manifest)
            // The file is left where it is. Renaming the package under the user
            // would break an open window and any alias they had made, and the
            // name in the manifest is the one the app shows.
            reload()
        } catch {
            problem = "Could not rename \(entry.name): \(error.localizedDescription)"
        }
    }

    /// A URL nothing is using, by adding a number rather than overwriting.
    private func availableURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        var candidate = root.appendingPathComponent(safe)
            .appendingPathExtension(NotebookPackage.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(safe) \(n)")
                .appendingPathExtension(NotebookPackage.fileExtension)
            n += 1
        }
        return candidate
    }
}
