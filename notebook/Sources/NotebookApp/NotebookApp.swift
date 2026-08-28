import NotebookKit
import SwiftUI

/// notebookMLX, as a window.
///
/// A plain `WindowGroup` rather than `DocumentGroup`, deliberately. Notebooks
/// are files the user owns, but they are worked with as a shelf: a list of
/// notebooks beside their sources beside the record, the way Notes presents
/// notes. `DocumentGroup` would give one window per notebook and no list, which
/// is the wrong shape for comparing two runs of the same corpus.
///
/// The library is a folder of packages, so a notebook can still be moved,
/// copied in the Finder, or opened from anywhere.
@main
struct NotebookMLXApp: App {
    @State private var library = NotebookLibrary()
    @State private var model = NotebookModel()
    /// One model in memory, shared by every window. Two notebooks on the same
    /// model must not load it twice, least of all on a machine that is also
    /// serving the fleet.
    @State private var embedding = EmbeddingService()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library, model: model, embedding: embedding)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowToolbarStyle(.unified)

        Settings { SettingsView() }

        // One window per notebook, keyed by its URL. SwiftUI brings an existing
        // window forward rather than opening a second onto the same file, which
        // is what stops two models appending to one record.
        WindowGroup(id: "notebook", for: URL.self) { $url in
            if let url { NotebookWindow(url: url, embedding: embedding) }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Notebook") { _ = library.create() }
                    .keyboardShortcut("n")
            }
        }
    }
}
