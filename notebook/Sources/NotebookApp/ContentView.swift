import NotebookKit
import SwiftUI
import UniformTypeIdentifiers

/// The window: sources on the left, the record on the right.
///
/// The record is the document, so it gets the space. Sources are the ground and
/// sit in a sidebar where they can be scanned and toggled without leaving the
/// thread.
struct ContentView: View {
    @Bindable var library: NotebookLibrary
    @Bindable var model: NotebookModel
    @Bindable var embedding: EmbeddingService
    @State private var selection: URL?
    @State private var question = ""
    @State private var isTargeted = false
    @State private var renaming: NotebookLibrary.Entry?
    @State private var newName = ""
    @State private var confirmingDelete: NotebookLibrary.Entry?

    /// Which columns are showing.
    ///
    /// `NavigationSplitViewVisibility` has three stages and they are not
    /// independent: `.all`, `.doubleColumn` which hides the sidebar, and
    /// `.detailOnly` which hides both. There is no state for "hide the middle
    /// one and keep the first", which is a reasonable thing to want when
    /// browsing notebooks without caring about their files.
    ///
    /// So the sources column is a separate flag and the layout swaps between a
    /// three column and a two column split. Swapping rather than animating a
    /// width to zero, because a zero width column still takes keyboard focus
    /// and still reports itself to VoiceOver.
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showSources = true

    var body: some View {
        Group {
            if showSources {
                NavigationSplitView(columnVisibility: $columns) {
                    notebookColumn
                } content: {
                    sourceColumn
                } detail: {
                    RecordView(model: model, question: $question, embedding: embedding)
                }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    notebookColumn
                } detail: {
                    RecordView(model: model, question: $question, embedding: embedding)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Toggle("Notebooks", isOn: Binding(
                        get: { columns != .detailOnly },
                        set: { columns = $0 ? .all : .detailOnly }))
                        .keyboardShortcut("1")
                    Toggle("Sources", isOn: $showSources)
                        .keyboardShortcut("2")
                } label: {
                    Label("Columns", systemImage: "sidebar.squares.left")
                }
                .help("Show or hide the notebook and source columns")
            }
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        // The list counts sources and questions, and both change while a
        // notebook is open. Without this the sidebar says "0 sources" beside a
        // column showing one, which reads as the app having lost the file.
        .onChange(of: model.sources.count) { _, _ in library.reload() }
        .onChange(of: model.turns.count) { _, _ in library.reload() }
        .onChange(of: selection) { _, url in
            guard let url else { return }
            model.open(url)
            if let manifest = model.manifest { embedding.warm(for: manifest.embeddingModel) }
        }
        .task {
            // Open the most recent, so the window is never empty on a machine
            // that already has notebooks.
            if selection == nil { selection = library.notebooks.first?.url }
        }
        .alert("Problem", isPresented: .constant(model.problem != nil || library.problem != nil)) {
            Button("OK") { model.problem = nil; library.problem = nil }
        } message: {
            Text(model.problem ?? library.problem ?? "")
        }
        // Renaming in a sheet rather than in place: an editable row that commits
        // on focus loss is easy to change by accident, and a notebook's name is
        // how somebody finds it again.
        .sheet(item: $renaming) { entry in
            RenameSheet(name: $newName, original: entry.name) { name in
                library.rename(entry, to: name)
                if selection == entry.url { model.open(entry.url) }
            }
        }
        .confirmationDialog(
            "Move “\(confirmingDelete?.name ?? "")” to the Trash?",
            isPresented: .constant(confirmingDelete != nil),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = confirmingDelete {
                    let wasOpen = selection == entry.url
                    library.delete(entry)
                    if wasOpen { selection = library.notebooks.first?.url }
                }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            // Named plainly, because this is the half that cannot be rebuilt.
            Text("Its sources and its record go with it. The Trash can be "
                 + "emptied, and then they are gone.")
        }
    }

    private var notebookColumn: some View {
        NotebookList(library: library, selection: $selection,
                     renaming: $renaming, newName: $newName,
                     confirmingDelete: $confirmingDelete)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }

    private var sourceColumn: some View {
        SourceList(model: model, embedding: embedding, isTargeted: $isTargeted)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    }
}

// --------------------------------------------------------------- notebooks

struct NotebookList: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var library: NotebookLibrary
    @Binding var selection: URL?
    @Binding var renaming: NotebookLibrary.Entry?
    @Binding var newName: String
    @Binding var confirmingDelete: NotebookLibrary.Entry?

    var body: some View {
        // **No `selection:` binding, deliberately.**
        //
        // `List(selection:)` under `.sidebar` is backed by NSTableRowView, whose
        // highlight is drawn from the system accent colour, and the SwiftUI tint
        // does not reach it: a teal app had a blue sidebar and no amount of
        // `.tint` fixed it. The supported override is an AccentColor asset named
        // in the main bundle's Info.plist, which a SwiftPM executable does not
        // have.
        //
        // The binding was also already doing nothing else. The rows set the
        // selection themselves, because the List's own gesture never reliably
        // fired through the tap recognisers attached for opening a window. So
        // it was drawing a colour we did not want and providing nothing we
        // still used.
        List {
            Section("Notebooks") {
                ForEach(library.notebooks) { entry in
                    NotebookRow(entry: entry, selected: selection == entry.url)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        // Double click opens it in its own window, as a note
                        // does in Notes.
                        //
                        // **Selection is set here, not left to the List.**
                        //
                        // Any tap gesture on a row competes with the gesture
                        // List uses for selection, and simultaneousGesture was
                        // not enough: clicking a notebook still did nothing and
                        // double click was the only thing that worked. Rather
                        // than keep guessing which recogniser wins, the single
                        // click sets the selection itself. The List's own
                        // handling is then a bonus rather than a dependency,
                        // and keyboard navigation still drives the same binding.
                        .onTapGesture { selection = entry.url }
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            selection = entry.url
                            openWindow(id: "notebook", value: entry.url)
                        })
                        .contextMenu {
                            Button("Open in New Window") {
                                openWindow(id: "notebook", value: entry.url)
                            }
                            Divider()
                            Button("Rename…") {
                                newName = entry.name
                                renaming = entry
                            }
                            Button("Duplicate") {
                                if let url = library.duplicate(entry) { selection = url }
                            }
                            Divider()
                            Button("Move to Trash", role: .destructive) {
                                confirmingDelete = entry
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        // Arrow keys, which the selection binding used to provide.
        //
        // Owning the highlight means owning this too. Left out, dropping the
        // binding would have traded a colour for a way of moving around, which
        // is not a trade worth making.
        .focusable()
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    if let url = library.create() {
                        selection = url
                        if let entry = library.notebooks.first(where: { $0.url == url }) {
                            newName = entry.name
                            renaming = entry
                        }
                    }
                } label: {
                    Label("New Notebook", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

extension NotebookList {
    /// Move the selection by one, staying inside the list.
    ///
    /// Clamped rather than wrapping: a list that jumps from the last notebook
    /// to the first looks like it lost the selection.
    func move(_ by: Int) {
        let all = library.notebooks
        guard !all.isEmpty else { return }
        guard let at = all.firstIndex(where: { $0.url == selection }) else {
            selection = all.first?.url
            return
        }
        let next = min(max(at + by, 0), all.count - 1)
        selection = all[next].url
    }
}

struct NotebookRow: View {
    let entry: NotebookLibrary.Entry
    var selected: Bool = false
    /// Whether this window is the one being used. A selected row in a window
    /// behind another should recede, which is the behaviour the system
    /// highlight gave for free and which drawing our own means doing here.
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).font(Type.rowTitle).lineLimit(1)
                .foregroundStyle(selected ? Palette.accent : Palette.ink)
            Text(detail).font(Type.rowDetail)
                .foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(detail)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var background: Color {
        guard selected else { return .clear }
        return activeState == .key ? Palette.selection : Palette.selectionIdle
    }

    private var detail: String {
        let sources = entry.sourceCount == 1 ? "1 source" : "\(entry.sourceCount) sources"
        let turns = entry.turnCount == 1 ? "1 question" : "\(entry.turnCount) questions"
        return "\(sources) · \(turns)"
    }
}

struct RenameSheet: View {
    @Binding var name: String
    let original: String
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Notebook").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit(name); dismiss() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") { commit(name); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

// ----------------------------------------------------------------- sources

struct SourceList: View {
    @Bindable var model: NotebookModel
    @Bindable var embedding: EmbeddingService
    @Binding var isTargeted: Bool

    private func drain() {
        guard let manifest = model.manifest, !model.queued.isEmpty,
              let embedder = embedding.ready(for: manifest.embeddingModel) else { return }
        model.startQueued(using: embedder)
    }

    var body: some View {
        List {
            Section("Sources") {
                if model.sources.isEmpty {
                    DropHint()
                } else {
                    ForEach(model.sources) { source in
                        SourceRow(source: source) { on in
                            model.setEnabled(on, for: source.name)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            DropZone(isTargeted: $isTargeted, working: model.working,
                     cancel: { model.cancelWork() })
        }
        // Dropped onto the whole list rather than only the dashed rectangle: a
        // target you have to hit is a target people miss.
        .dropDestination(for: URL.self) { urls, _ in
            guard let manifest = model.manifest else { return false }
            // Accepted while the model is still warming rather than refused.
            // Making a notebook and immediately dropping a file into it is the
            // obvious first thing to do, and the model takes a minute to load:
            // refusing then is refusing exactly when somebody is finding out
            // whether the app works.
            if let why = EmbeddingService.support(for: manifest.embeddingModel) {
                model.problem = why
                return false
            }
            model.enqueue(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        // Drain the queue once the model is ready, and whenever more arrives.
        .onChange(of: embedding.state) { _, _ in drain() }
        .onChange(of: model.queued.count) { _, _ in drain() }
    }
}

struct SourceRow: View {
    let source: NotebookModel.Source
    var setEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.kind.symbol)
                .foregroundStyle(source.enabled ? Palette.inkSecondary : Palette.inkTertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).lineLimit(1)
                    .foregroundStyle(source.enabled ? Palette.ink : Palette.inkSecondary)
                Text(detail).font(Type.rowDetail).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 0)
            // A switch rather than a checkbox: this is a state the source is
            // in, not an action taken on it, and it changes what the next
            // question can see.
            Toggle("", isOn: Binding(get: { source.enabled },
                                     set: { setEnabled($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.name), \(source.kind.rawValue), \(detail)")
        .accessibilityValue(source.enabled ? "included" : "excluded")
        .accessibilityHint("Switch off to ask without this source")
    }

    private var detail: String {
        switch source.state {
        case .pending: return "waiting"
        case .extracting: return "extracting"
        case let .embedding(done, total): return "embedding \(done) of \(total)"
        case let .ready(chunks):
            let size = chunks > 0 ? "\(chunks) chunks" : ByteCountFormatter
                .string(fromByteCount: Int64(source.bytes), countStyle: .file)
            return source.enabled ? size : "\(size) · excluded"
        case let .failed(why): return why
        }
    }
}

struct DropHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No sources yet").foregroundStyle(Palette.inkSecondary)
            Text("Drop text, PDF, CSV or Excel below.")
                .font(.caption).foregroundStyle(Palette.inkTertiary)
        }
        .padding(.vertical, 6)
    }
}

struct DropZone: View {
    @Binding var isTargeted: Bool
    var working: String?
    var cancel: () -> Void

    var body: some View {
        if let working {
            // Progress replaces the target while something is running, with a
            // way to stop it. Embedding a large PDF takes minutes and an app
            // that cannot be interrupted during it is an app that looks hung.
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(working).font(.caption).multilineTextAlignment(.center)
                Button("Stop", action: cancel).buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(10)
        } else {
            target
        }
    }

    private var target: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down")
                .font(.title2).foregroundStyle(Palette.inkSecondary)
            Text("Drop documents").font(.callout)
            Text("text · pdf · csv · xlsx")
                .font(.caption2).foregroundStyle(Palette.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(isTargeted ? AnyShapeStyle(Palette.accentSoft)
                               : AnyShapeStyle(Palette.field),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(isTargeted ? Palette.accent : Palette.fieldEdge)
        }
        .padding(10)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
        .accessibilityLabel("Drop documents here")
        .accessibilityHint("Accepts text, PDF, CSV and Excel files")
    }
}

// ------------------------------------------------------------------ record

/// How wide the record is, and when it grows a margin.
///
/// **The measure never changes; the layout around it does.** 700 points of 15
/// point serif is already about 95 characters, which is at the limit of what
/// can be read comfortably, so a wider window must not produce a wider
/// paragraph. What it produces instead is somewhere to put the evidence.
enum Measure {
    /// The reading column. Fixed, in both layouts.
    static let prose: CGFloat = 700
    /// The evidence rail, when there is room for one.
    static let rail: CGFloat = 240
    static let gutter: CGFloat = 24
    /// The card's own horizontal padding, both sides.
    static let cardPadding: CGFloat = 44
    /// The record's padding inside its width, both sides.
    static let pagePadding: CGFloat = 56
    /// The document's left margin.
    static let lead: CGFloat = 56

    static let narrow = prose + cardPadding + pagePadding
    static let wide = prose + gutter + rail + cardPadding + pagePadding

    /// Below this, the rail folds back into the card.
    ///
    /// Set from the width the wide layout actually needs plus its lead, with a
    /// little room, rather than chosen as a round number: the breakpoint should
    /// be the point at which the thing fits.
    static let threshold = wide + lead + 60
}

struct RecordView: View {
    @Bindable var model: NotebookModel
    @Binding var question: String
    @Bindable var embedding: EmbeddingService
    /// Two turns chosen to compare, by their position in the record.
    @State private var picked: [Int] = []

    var body: some View {
        GeometryReader { geometry in
        let wide = geometry.size.width >= Measure.threshold
        ScrollViewReader { scroll in
        ScrollView {
            document(wide: wide)
        }
        .background(Palette.page)
        // The question is put on screen the moment it is asked, and scrolled
        // to, so submitting does something visible rather than nothing until
        // the answer lands.
        .onChange(of: model.pending?.question) { _, question in
            guard question != nil else { return }
            withAnimation { scroll.scrollTo("pending", anchor: .bottom) }
        }
        .onChange(of: model.turns.count) { _, _ in
            if let last = model.turns.indices.last {
                withAnimation { scroll.scrollTo(last, anchor: .bottom) }
            }
        }
        }
        .safeAreaInset(edge: .bottom) {
            AskBar(model: model, question: $question, embedding: embedding,
                   wide: wide, cancel: { stopAsking() })
        }
        // Escape, which is what somebody reaches for before they look for a
        // button.
        .onExitCommand { stopAsking() }
        .safeAreaInset(edge: .top) {
            if picked.count == 1 {
                // Said rather than left to be guessed. One turn chosen is a
                // half finished gesture and the way out has to be visible.
                HStack(spacing: 10) {
                    Text("Choose a second turn to compare")
                        .font(.callout)
                    Button("Cancel") { picked = [] }.buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 28).padding(.vertical, 8)
                .background(.bar)
            }
        }
        .sheet(isPresented: Binding(get: { picked.count == 2 },
                                    set: { if !$0 { picked = [] } })) {
            if picked.count == 2 {
                CompareView(left: model.turns[picked[0]],
                            right: model.turns[picked[1]],
                            package: model.package)
            }
        }
        }
    }

    /// The record itself, at whichever width it was given.
    ///
    /// Extracted from `body` because the whole view in one expression stopped
    /// type checking in reasonable time once the width became a variable, which
    /// is SwiftUI's way of asking for a smaller function.
    @ViewBuilder
    private func document(wide: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 40) {
            if model.turns.isEmpty && model.pending == nil {
                EmptyRecord(isOpen: model.isOpen)
                    .padding(.top, 60)
            } else {
                ForEach(Array(model.turns.enumerated()), id: \.offset) { index, turn in
                    TurnView(turn: turn, package: model.package,
                             picked: picked.contains(index), wide: wide) {
                        pick(index)
                    }
                    .id(index)
                }
                if let pending = model.pending {
                    PendingTurnView(pending: pending, package: model.package,
                                    wide: wide) { stopAsking() }
                        .id("pending")
                }
            }
        }
        .padding(.horizontal, Measure.pagePadding / 2)
        .padding(.vertical, 28)
        .frame(maxWidth: wide ? Measure.wide : Measure.narrow, alignment: .leading)
        // Left aligned with a lead, not centred.
        //
        // Centring a 760pt column in a 2,000pt window leaves 600pt of dead
        // ground on each side, symmetrical enough to look deliberate, which is
        // why it read as the app having nothing to put there. Empty space to
        // the right of a left aligned document reads as margin.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Measure.lead)
    }

    /// Stop the question in flight and put it back in the field.
    ///
    /// Putting it back is the whole point. The reason somebody stops a question
    /// is almost always that they have just seen a mistake in it, and making
    /// them retype the sentence to fix one word is the sort of thing that
    /// teaches people not to use the stop button.
    private func stopAsking() {
        if let restored = model.cancelAsk() { question = restored }
    }

    /// Choosing turns to compare: first, then second, then the sheet.
    private func pick(_ index: Int) {
        if let at = picked.firstIndex(of: index) { picked.remove(at: at) }
        else if picked.count < 2 { picked.append(index) }
    }
}

struct EmptyRecord: View {
    let isOpen: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isOpen ? "text.bubble" : "book.closed")
                .font(.system(size: 34)).foregroundStyle(Palette.inkTertiary)
            Text(isOpen ? "Nothing asked yet" : "No notebook open")
                .font(.title3)
            Text(isOpen
                 ? "Questions and answers are recorded here, with what was retrieved and the settings in force."
                 : "Open a .dainotebook to see its sources and record.")
                .font(.callout).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A question being worked on.
///
/// Shaped like a finished turn so it does not move when it becomes one, with
/// the stage where the provenance line will be. The citations appear as soon as
/// retrieval finishes, which is most of the useful information and arrives in
/// milliseconds, while the answer is still seconds away.
struct PendingTurnView: View {
    let pending: NotebookModel.Pending
    let package: NotebookPackage?
    var wide: Bool = false
    /// Take the question back. Beside the stage rather than in the toolbar,
    /// because the thing being stopped is the thing on screen.
    var cancel: (() -> Void)?

    private var gutter: Bool { wide && pending.citations.count > 1 }

    var body: some View {
        HStack(alignment: .top, spacing: Measure.gutter) {
            VStack(alignment: .leading, spacing: 12) {
                Text(pending.question)
                    .font(Type.question)
                    .tracking(-0.2)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)

                if !pending.citations.isEmpty && !gutter {
                    CitationStrip(citations: pending.citations, package: package)
                }

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(pending.stage).font(.callout)
                        .foregroundStyle(Palette.inkSecondary)
                    if let cancel {
                        Button("Stop", action: cancel)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if gutter {
                CitationStrip(citations: pending.citations, package: package,
                              layout: .gutter)
                    .frame(width: Measure.rail, alignment: .leading)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Palette.accentEdge)
        }
        .shadow(color: Palette.cardShadow, radius: 3, x: 0, y: 1)
        .shadow(color: Palette.cardShadowWide, radius: 12, x: 0, y: 4)
        .transition(.opacity)
    }
}

/// One exchange: the question, what it retrieved, what came back, and under
/// what settings. All four, because this is a record rather than a transcript.
struct TurnView: View {
    let turn: NotebookPackage.Turn
    let package: NotebookPackage?
    var picked: Bool = false
    /// Whether there is room beside the prose for the evidence.
    var wide: Bool = false
    var compare: (() -> Void)?
    /// A citation the answer named, opened from inside the sentence.
    @State private var opened: NotebookPackage.Turn.Citation?

    /// The citations go beside the answer only when they both fit and there
    /// are enough of them to be worth a column. One citation in a margin is a
    /// stray number; below that threshold it stays in the band.
    private var gutter: Bool { wide && turn.citations.count > 1 }

    var body: some View {
        HStack(alignment: .top, spacing: Measure.gutter) {
            prose
                .frame(maxWidth: .infinity, alignment: .leading)
            if gutter {
                CitationStrip(citations: turn.citations, package: package,
                              layout: .gutter)
                    .frame(width: Measure.rail, alignment: .leading)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            // One stroke, not a fill and two strokes. A 12% teal fill on a
            // teal grey page was invisible anyway, so the border carries the
            // whole of the chosen state and carries it clearly.
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(picked ? Palette.accent : Palette.cardEdge,
                              lineWidth: picked ? 2 : 1)
        }
        .shadow(color: Palette.cardShadow, radius: 3, x: 0, y: 1)
        .shadow(color: Palette.cardShadowWide, radius: 12, x: 0, y: 4)
        .sheet(item: $opened) { citation in
            if let package {
                SourceViewer(citation: citation, package: package)
            }
        }
        .contextMenu {
            if let compare {
                Button(picked ? "Remove from Comparison" : "Compare With…",
                       action: compare)
            }
        }
    }
}

extension TurnView {
    /// The reading column: what was asked, what came back, and where from.
    @ViewBuilder
    var prose: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(turn.question)
                .font(Type.question)
                .tracking(-0.2)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)

            if !turn.citations.isEmpty && !gutter {
                CitationStrip(citations: turn.citations, package: package)
                    .padding(.top, 14)
            }

            // **Above the answer, not below it.**
            //
            // This was under the prose, which is the one place it cannot do its
            // job: by the time somebody reads "that was cut off" they have
            // already read the cut off thing as though it were whole. Its
            // entire purpose is to change how the next paragraph is read.
            if turn.wasTruncated {
                Truncation(turn: turn)
                    .padding(.top, turn.citations.isEmpty || gutter ? 14 : 16)
            }

            AnswerView(answer: turn.answer, citations: turn.citations) { citation in
                // Only opened when the package is here to open it from. A
                // record read without its notebook still shows the links; they
                // simply have nowhere to go, which is better than hiding that
                // the answer cited anything.
                if package != nil { opened = citation }
            }
            .padding(.top, turn.wasTruncated ? 16 : 18)

            Rule()
                .padding(.top, 16)
            Provenance(turn: turn)
                .padding(.top, 10)
        }
    }
}

/// Retrieved passages, in one of two places.
///
/// **The same evidence, laid out for two different jobs.** Inline it is a band
/// between the question and the answer, which is the right sequence for
/// auditing: the passages come before the prose they produced. In the gutter it
/// is a sidenote column beside the answer, which is the right shape for
/// reading: the evidence stays visible without interrupting the sentence.
///
/// Which one is used is decided by the width of the window and nothing else.
struct CitationStrip: View {
    let citations: [NotebookPackage.Turn.Citation]
    let package: NotebookPackage?
    var layout: Layout = .band
    @State private var opened: NotebookPackage.Turn.Citation?
    @State private var hovered: String?

    enum Layout { case band, gutter }

    var body: some View {
        VStack(alignment: .leading, spacing: layout == .gutter ? 8 : 2) {
            if layout == .gutter {
                // Labelled only in the gutter. Inline, its position between the
                // question and the answer says what it is; in a margin it is
                // a column of numbers with no context.
                Text("Retrieved")
                    .font(Type.stateBadge)
                    .tracking(0.6)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.bottom, 2)
            }
            ForEach(Array(citations.enumerated()), id: \.offset) { _, c in
                Button { opened = c } label: { row(c) }
                    .buttonStyle(.plain)
                    .disabled(package == nil)
                    // These have always opened their page and never looked like
                    // they would. A hover ground is the whole of the
                    // affordance, and it costs nothing when nobody is reaching
                    // for it. `onHover` rather than `pointerStyle`, which needs
                    // macOS 15 and this targets 14.
                    .background(hovered == c.id ? Palette.accentSoft : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .onHover { hovered = $0 ? c.id : nil }
                    .help("Open the passage this came from")
                    .accessibilityLabel("\(c.citation), score "
                                        + "\(String(format: "%.3f", c.score))")
                    .accessibilityHint("Opens the passage in its original document")
            }
        }
        .modifier(Ground(layout: layout))
        .sheet(item: $opened) { citation in
            if let package {
                SourceViewer(citation: citation, package: package)
            }
        }
    }

    @ViewBuilder
    private func row(_ c: NotebookPackage.Turn.Citation) -> some View {
        // The score is shown, not hidden, and it is coloured and tabular.
        //
        // Whether the right passage was retrieved is the first question about
        // any answer, and these numbers are the only thing that answers it.
        // They were once the faintest text on screen.
        let score = Text(String(format: "%.3f", c.score))
            .font(Type.score)
            .monospacedDigit()
            .foregroundStyle(Palette.accent)

        switch layout {
        case .band:
            HStack(spacing: 8) {
                score.frame(width: 46, alignment: .trailing)
                Text(c.citation)
                    .font(Type.citation)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                if page(of: c) != nil {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption2)
                        .foregroundStyle(Palette.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())

        case .gutter:
            // Stacked, because 240 points is not enough for a score, a file
            // name and a page number on one line, and truncating the name to
            // fit would remove the part that identifies it.
            VStack(alignment: .leading, spacing: 1) {
                score
                Text(c.citation)
                    .font(Type.citation)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    /// What the strip sits on, which differs by where it sits.
    ///
    /// A band runs to the card's text edges with a rule above and below, so it
    /// reads as part of the turn rather than as a panel inside it. A gutter
    /// column needs no ground at all: the space around it already separates it,
    /// and a fill there would make the margin look like a second card.
    private struct Ground: ViewModifier {
        let layout: Layout

        func body(content: Content) -> some View {
            switch layout {
            case .band:
                content
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.evidence)
                    .overlay(alignment: .top) { Rule() }
                    .overlay(alignment: .bottom) { Rule() }
            case .gutter:
                content
            }
        }
    }

    private func page(of c: NotebookPackage.Turn.Citation) -> Int? {
        Locator.page(of: c.url)
    }
}

/// Said plainly when an answer stopped before it was finished.
///
/// **Not a caption.** An answer cut off mid sentence reads as a complete one,
/// and the reader has no way to tell: this is the one piece of provenance that
/// changes what the words in front of them mean, so it sits with the answer
/// rather than in the grey line underneath it.
///
/// It names the cause too, because the cause is almost never the setting in
/// this app. A harvested machine allows 256 completion tokens while its owner
/// is using it, and somebody who is not told that will raise a limit here and
/// watch nothing change.
struct Truncation: View {
    let turn: NotebookPackage.Turn

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "scissors")
            Text(explanation)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .foregroundStyle(Palette.warning)
        .background(Palette.warningSoft, in: RoundedRectangle(cornerRadius: 8))
    }

    private var explanation: String {
        let limit = turn.maxTokensApplied.map { "\($0) tokens" } ?? "its limit"
        guard turn.cappedByPolicy == true else {
            return "This answer was cut off at \(limit). Raise Longest answer "
                 + "in Settings to let it finish."
        }
        let machine = turn.answeredBy ?? "the machine that answered"
        let state = turn.presenceState.map { " (\($0))" } ?? ""
        return "This answer was cut off at \(limit), which is less than was "
             + "asked for: \(machine)\(state) is being harvested and limits "
             + "completions while it is in use. Raising Longest answer will not "
             + "change this; the answer has to land on an idle machine."
    }
}

/// A hairline, at the weight an edge should be.
///
/// One point at the palette's rule alpha rather than a Divider, whose colour is
/// the system's and lands neutral grey on a tinted ground.
struct Rule: View {
    var body: some View {
        Rectangle().fill(Palette.evidenceRule).frame(height: 1)
    }
}

/// Which machine answered, and under what settings.
///
/// Kept on every turn rather than in a details pane: "what was different about
/// that run" is the question this file exists to answer, and it cannot be
/// answered later if it is not written down at the time.
struct Provenance: View {
    let turn: NotebookPackage.Turn

    var body: some View {
        HStack(spacing: 12) {
            Text(retrieval)
            if let machine = turn.answeredBy {
                Text(machine)
                if let state = turn.presenceState {
                    // **A badge, because this one is not a fact like the
                    // others.** A presence state that caps completions decides
                    // whether the answer above is whole, and rendering it in
                    // the same grey as the elapsed time said it was the same
                    // kind of thing. It is not.
                    Text(state.uppercased())
                        .font(Type.stateBadge)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(caps(state) ? Palette.warningSoft
                                                : Palette.accentSoft,
                                    in: Capsule())
                        .foregroundStyle(caps(state) ? Palette.warning
                                                     : Palette.accent)
                }
            }
            if let seconds = turn.seconds {
                Text(String(format: "%.1fs", seconds))
            }
            if turn.wasTruncated, let applied = turn.maxTokensApplied {
                Text("cut at \(applied)").foregroundStyle(Palette.warning)
            }
            Spacer(minLength: 0)
            // The embedding model is the least urgent of these and is the one
            // that never changes within a notebook, so it sits at the far end
            // in the quietest ink rather than in the reading order.
            Text(model).foregroundStyle(Palette.inkTertiary)
        }
        .font(Type.provenance)
        .tracking(0.2)
        .foregroundStyle(Palette.inkSecondary)
    }

    private var retrieval: String {
        "k \(turn.k) · \(turn.hybrid ? "hybrid" : "semantic")"
    }

    private var model: String {
        turn.embeddingModel.split(separator: "/").last.map(String.init) ?? ""
    }

    /// Presence states under which a harvested machine limits completions.
    ///
    /// Named here rather than inferred from the truncation, because the cap
    /// applies whether or not this particular answer hit it, and knowing the
    /// next one might is worth as much as knowing this one did.
    private func caps(_ state: String) -> Bool {
        ["ACTIVE", "PASSIVE", "IDLE"].contains(state.uppercased())
    }
}

// --------------------------------------------------------------------- ask

struct AskBar: View {
    @Bindable var model: NotebookModel
    @Binding var question: String
    @Bindable var embedding: EmbeddingService
    var wide: Bool = false
    var cancel: (() -> Void)?

    /// Asking needs both a notebook with chunks and a loaded model.
    private var canAsk: Bool {
        guard let manifest = model.manifest else { return false }
        return model.canAsk && embedding.ready(for: manifest.embeddingModel) != nil
    }

    private func ask() {
        guard canAsk, let manifest = model.manifest,
              let embedder = embedding.ready(for: manifest.embeddingModel) else { return }
        let asked = question
        question = ""
        model.ask(asked, using: embedder, gateway: Self.gateway())
    }

    /// The fleet, when one has been configured.
    ///
    /// nil is a working state, not a failure: retrieval alone is useful and is
    /// what this app did before generation existed. A turn without an answer
    /// says so rather than pretending.
    static func gateway() -> Gateway? {
        guard let url = URL(string: GatewaySettings.baseURL),
              Credentials.read()?.isEmpty == false else { return nil }
        let ca = GatewaySettings.caPath
        return Gateway(configuration: .init(baseURL: url,
                                            caCertificatePath: ca.isEmpty ? nil : ca),
                       credential: { Credentials.read() })
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                TextField("Ask this notebook", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 4)
                    .font(.body)
                    .disabled(!canAsk)
                    .onSubmit(ask)
                if model.asking {
                    // The same control, doing the opposite thing. A spinner
                    // here said "wait" and offered nothing; the only place
                    // somebody looks to take a question back is where they sent
                    // it from.
                    Button { cancel?() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Palette.warning)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Stop this question and put it back")
                } else {
                    Button { ask() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAsk || question.isEmpty)
                    .help(canAsk ? "Ask" : model.whyNotAsking)
                }
            }
            .padding(12)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.fieldEdge)
            }

            // What the model is doing, said rather than implied by a
            // disabled control. Warming takes about a minute the first time and
            // a spinner with no words reads as a hang.
            HStack(spacing: 6) {
                if case .warming = embedding.state {
                    ProgressView().controlSize(.small)
                }
                if let summary = embedding.summary {
                    Text(summary).font(Type.provenance).foregroundStyle(Palette.inkSecondary)
                }
                if let detail = embedding.detail {
                    Text(detail).font(Type.rowDetail).foregroundStyle(Palette.inkSecondary)
                        .lineLimit(2)
                } else if !canAsk, embedding.state.isReady, !model.whyNotAsking.isEmpty {
                    Text(model.whyNotAsking)
                        .font(.caption).foregroundStyle(Palette.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Measure.pagePadding / 2)
        .padding(.vertical, 12)
        // The same column as the record above it, left aligned to the same
        // lead. Centred under a left aligned document, the field's text edge
        // would land somewhere the answers never start.
        .frame(maxWidth: wide ? Measure.wide : Measure.narrow, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Measure.lead)
        .background(.bar)
    }
}
