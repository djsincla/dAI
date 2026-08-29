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
        List(selection: $selection) {
            Section("Notebooks") {
                ForEach(library.notebooks) { entry in
                    NotebookRow(entry: entry)
                        .tag(entry.url)
                        // Double click opens it in its own window, as a note
                        // does in Notes.
                        //
                        // **`simultaneousGesture`, not `onTapGesture`.** A tap
                        // gesture attached to a row competes with the gesture
                        // List uses for selection and wins, so adding the way
                        // out took away the way in: clicking a notebook stopped
                        // switching to it, and the double click was the only
                        // thing that still worked. Simultaneous recognition
                        // lets both run, so a click selects and a double click
                        // selects and then opens.
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
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

struct NotebookRow: View {
    let entry: NotebookLibrary.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(detail)")
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
                .foregroundStyle(source.enabled ? .secondary : .tertiary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).lineLimit(1)
                    .foregroundStyle(source.enabled ? .primary : .secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
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
            Text("No sources yet").foregroundStyle(.secondary)
            Text("Drop text, PDF, CSV or Excel below.")
                .font(.caption).foregroundStyle(.tertiary)
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
                .font(.title2).foregroundStyle(.secondary)
            Text("Drop documents").font(.callout)
            Text("text · pdf · csv · xlsx")
                .font(.caption2).foregroundStyle(.tertiary)
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

struct RecordView: View {
    @Bindable var model: NotebookModel
    @Binding var question: String
    @Bindable var embedding: EmbeddingService
    /// Two turns chosen to compare, by their position in the record.
    @State private var picked: [Int] = []

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if model.turns.isEmpty && model.pending == nil {
                    EmptyRecord(isOpen: model.isOpen)
                        .padding(.top, 60)
                } else {
                    ForEach(Array(model.turns.enumerated()), id: \.offset) { index, turn in
                        TurnView(turn: turn, package: model.package,
                                 picked: picked.contains(index)) {
                            pick(index)
                        }
                        .id(index)
                    }
                    if let pending = model.pending {
                        PendingTurnView(pending: pending, package: model.package)
                            .id("pending")
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
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
        .safeAreaInset(edge: .bottom) { AskBar(model: model, question: $question, embedding: embedding) }
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
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(isOpen ? "Nothing asked yet" : "No notebook open")
                .font(.title3)
            Text(isOpen
                 ? "Questions and answers are recorded here, with what was retrieved and the settings in force."
                 : "Open a .dainotebook to see its sources and record.")
                .font(.callout).foregroundStyle(.secondary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pending.question)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            if !pending.citations.isEmpty {
                CitationStrip(citations: pending.citations, package: package)
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(pending.stage).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Palette.accentEdge)
        }
        .transition(.opacity)
    }
}

/// One exchange: the question, what it retrieved, what came back, and under
/// what settings. All four, because this is a record rather than a transcript.
struct TurnView: View {
    let turn: NotebookPackage.Turn
    let package: NotebookPackage?
    var picked: Bool = false
    var compare: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(turn.question)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            if !turn.citations.isEmpty {
                CitationStrip(citations: turn.citations, package: package)
            }

            Text(turn.answer)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if turn.wasTruncated { Truncation(turn: turn) }

            Provenance(turn: turn)
        }
        .padding(18)
        .background(picked ? AnyShapeStyle(Palette.accentSoft)
                           : AnyShapeStyle(Palette.card),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(picked ? Palette.accentEdge : Palette.cardEdge)
        }
        .overlay {
            if picked {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint)
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

struct CitationStrip: View {
    let citations: [NotebookPackage.Turn.Citation]
    let package: NotebookPackage?
    @State private var opened: NotebookPackage.Turn.Citation?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(citations.enumerated()), id: \.offset) { _, c in
                Button {
                    opened = c
                } label: {
                    HStack(spacing: 8) {
                        // The score is shown, not hidden. Whether the right
                        // thing was retrieved is the first question about any
                        // answer, and it is answerable at a glance only if the
                        // numbers are here.
                        // Coloured and tabular rather than grey.
                        //
                        // Whether the right passage was retrieved is the first
                        // question about any answer, and these numbers are the
                        // only thing that answers it. They were styled as the
                        // faintest text on screen. Tabular figures so a column
                        // of them can be compared by eye without reading.
                        Text(String(format: "%.3f", c.score))
                            .font(.system(.caption, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(Palette.accent)
                            .frame(width: 46, alignment: .trailing)
                        Text(c.citation).font(.callout).lineLimit(1)
                        if page(of: c) != nil {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(package == nil)
                .help("Open the passage this came from")
                .accessibilityLabel("\(c.citation), score "
                                    + "\(String(format: "%.3f", c.score))")
                .accessibilityHint("Opens the passage in its original document")
            }
        }
        .padding(10)
        .background(Palette.evidence, in: RoundedRectangle(cornerRadius: 8))
        .sheet(item: $opened) { citation in
            if let package {
                SourceViewer(citation: citation, package: package)
            }
        }
    }

    private func page(of c: NotebookPackage.Turn.Citation) -> Int? {
        guard let fragment = c.url.split(separator: "#").last,
              fragment.hasPrefix("page=") else { return nil }
        return Int(fragment.dropFirst("page=".count))
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

/// Which machine answered, and under what settings.
///
/// Kept on every turn rather than in a details pane: "what was different about
/// that run" is the question this file exists to answer, and it cannot be
/// answered later if it is not written down at the time.
struct Provenance: View {
    let turn: NotebookPackage.Turn

    var body: some View {
        HStack(spacing: 14) {
            ForEach(facts, id: \.self) { fact in
                Text(fact)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var facts: [String] {
        var out = ["k \(turn.k)", turn.hybrid ? "hybrid" : "semantic"]
        if let node = turn.answeredBy {
            out.append(turn.presenceState.map { "\(node) · \($0)" } ?? node)
        }
        if let seconds = turn.seconds { out.append(String(format: "%.1fs", seconds)) }
        if turn.wasTruncated, let applied = turn.maxTokensApplied {
            out.append("cut at \(applied)")
        }
        out.append(turn.embeddingModel.split(separator: "/").last.map(String.init) ?? "")
        return out.filter { !$0.isEmpty }
    }
}

// --------------------------------------------------------------------- ask

struct AskBar: View {
    @Bindable var model: NotebookModel
    @Binding var question: String
    @Bindable var embedding: EmbeddingService

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
                Button {
                    ask()
                } label: {
                    if model.asking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canAsk || question.isEmpty)
                .help(canAsk ? "Ask" : model.whyNotAsking)
            }
            .padding(12)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary)
            }

            // What the model is doing, said rather than implied by a
            // disabled control. Warming takes about a minute the first time and
            // a spinner with no words reads as a hang.
            HStack(spacing: 6) {
                if case .warming = embedding.state {
                    ProgressView().controlSize(.small)
                }
                if let summary = embedding.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                if let detail = embedding.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !canAsk, embedding.state.isReady, !model.whyNotAsking.isEmpty {
                    Text(model.whyNotAsking)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
