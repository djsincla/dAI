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

    /// The GPU cache limit is set before any window exists.
    ///
    /// It governs allocations made after it, so setting it when the first model
    /// loads leaves the load itself uncapped. Nothing here touches MLX before
    /// this runs.
    /// What the window is showing, so the toolbar control can reflect it.
    @State private var appearance = Appearance.current
    @Environment(\.openWindow) private var openWindow

    private func openHelp() { openWindow(id: "help") }

    init() {
        Embedder.configureMemory()
        // Applied before the first window exists, so it opens in the chosen
        // appearance rather than flashing the system one first.
        Appearance.current.apply()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(library: library, model: model, embedding: embedding,
                        appearance: $appearance)
                .frame(minWidth: 1000, minHeight: 620)
                // The app's own accent rather than the system's. Sidebar
                // selection, switches and buttons all take this, which is most
                // of what makes the window look like one thing.
                .tint(Palette.accent)
        }
        .windowToolbarStyle(.unified)

        Settings { SettingsView() }

        // A window rather than a sheet, so it can be left open beside the
        // notebook while somebody reads a turn and the explanation together.
        Window("What the window is telling you", id: "help") {
            HelpView()
                .frame(minWidth: 520, minHeight: 560)
                .tint(Palette.accent)
        }
        .defaultSize(width: 660, height: 720)

        // One window per notebook, keyed by its URL. SwiftUI brings an existing
        // window forward rather than opening a second onto the same file, which
        // is what stops two models appending to one record.
        WindowGroup(id: "notebook", for: URL.self) { $url in
            if let url {
                NotebookWindow(url: url, embedding: embedding)
                    .tint(Palette.accent)
            }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Notebook") { _ = library.create() }
                    .keyboardShortcut("n")
            }
            // In the Help menu, where somebody looks for it, rather than only
            // discoverable by knowing the window exists.
            CommandGroup(replacing: .help) {
                Button("What the window is telling you") {
                    openHelp()
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}
