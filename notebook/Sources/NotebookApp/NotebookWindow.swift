import NotebookKit
import SwiftUI

/// One notebook in its own window: sources and record, no library column.
///
/// Opened by double clicking a notebook in the browser, and the reason it
/// exists is comparison. The interesting question about a retrieval experiment
/// is rarely "what did it say" and almost always "what changed", which needs two
/// notebooks on screen at once. A single browsing window cannot do that, and a
/// tabbed one makes you flip between the two things you are comparing.
///
/// Value based `WindowGroup`, so opening a notebook that is already open brings
/// its window forward rather than making a second one showing the same file.
/// Two windows onto one notebook would be two models appending to one record.
struct NotebookWindow: View {
    let url: URL
    @Bindable var embedding: EmbeddingService
    @State private var model = NotebookModel()
    @State private var question = ""
    @State private var isTargeted = false

    var body: some View {
        NavigationSplitView {
            SourceList(model: model, embedding: embedding, isTargeted: $isTargeted)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            RecordView(model: model, question: $question, embedding: embedding)
        }
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .frame(minWidth: 760, minHeight: 560)
        .task(id: url) {
            model.open(url)
            // Warmed while the notebook is being read rather than when a
            // question is asked. Cold loading this model measured 68 seconds.
            if let manifest = model.manifest { embedding.warm(for: manifest.embeddingModel) }
        }
        .alert("Problem", isPresented: .constant(model.problem != nil)) {
            Button("OK") { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
        }
    }
}
