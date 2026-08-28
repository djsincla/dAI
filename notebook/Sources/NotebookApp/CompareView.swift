import NotebookKit
import SwiftUI

/// Two turns, side by side, with what differs called out.
///
/// The reason this app exists rather than a script. The interesting question
/// about a retrieval experiment is almost never "what did it say" and almost
/// always "what changed", and a record that carries k, the retrieval mode, the
/// embedding model, the active sources and the scores can answer that without
/// anybody having written anything down.
///
/// Nothing is recomputed here. Both turns already happened, and re-running one
/// to compare it would be comparing a new run against an old one.
struct CompareView: View {
    let left: NotebookPackage.Turn
    let right: NotebookPackage.Turn
    let package: NotebookPackage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Compare").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()

            if !differences.isEmpty {
                // Put first, because it is the answer to the question somebody
                // opened this to ask.
                VStack(alignment: .leading, spacing: 4) {
                    Text("What differs").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(differences, id: \.self) { line in
                        Text(line).font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.quaternary.opacity(0.16))
                Divider()
            }

            HStack(spacing: 0) {
                column(left)
                Divider()
                column(right)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    private func column(_ turn: NotebookPackage.Turn) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(turn.question).font(.headline)
                Text(settings(of: turn)).font(.caption).foregroundStyle(.secondary)
                if !turn.citations.isEmpty {
                    CitationStrip(citations: turn.citations, package: package)
                }
                Text(turn.answer).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func settings(of turn: NotebookPackage.Turn) -> String {
        var parts = ["k \(turn.k)", turn.hybrid ? "hybrid" : "semantic",
                     EmbeddingService.short(turn.embeddingModel)]
        if let node = turn.answeredBy { parts.append(node) }
        if let seconds = turn.seconds { parts.append(String(format: "%.1fs", seconds)) }
        if let sources = turn.sources { parts.append("\(sources.count) sources") }
        return parts.joined(separator: "  ·  ")
    }

    /// Only what actually differs, named in words.
    ///
    /// Listing everything would bury the one line that matters, and a diff of
    /// two answers is not useful: the answers are prose and will always differ.
    /// What is comparable is the settings that produced them.
    private var differences: [String] {
        var out: [String] = []
        if left.question != right.question { out.append("Different questions.") }
        if left.k != right.k { out.append("k: \(left.k) against \(right.k)") }
        if left.hybrid != right.hybrid {
            out.append("retrieval: \(left.hybrid ? "hybrid" : "semantic") against "
                       + "\(right.hybrid ? "hybrid" : "semantic")")
        }
        if left.embeddingModel != right.embeddingModel {
            out.append("embedding model: \(EmbeddingService.short(left.embeddingModel)) "
                       + "against \(EmbeddingService.short(right.embeddingModel))")
        }
        let leftSources = Set(left.sources ?? [])
        let rightSources = Set(right.sources ?? [])
        if leftSources != rightSources {
            let only = leftSources.symmetricDifference(rightSources).sorted()
            out.append("sources differ: \(only.joined(separator: ", "))")
        }
        let leftCites = left.citations.map(\.citation)
        let rightCites = right.citations.map(\.citation)
        if leftCites != rightCites {
            let gained = Set(rightCites).subtracting(leftCites).sorted()
            let lost = Set(leftCites).subtracting(rightCites).sorted()
            if !gained.isEmpty { out.append("only on the right: \(gained.joined(separator: ", "))") }
            if !lost.isEmpty { out.append("only on the left: \(lost.joined(separator: ", "))") }
            if gained.isEmpty && lost.isEmpty {
                out.append("same passages, different order")
            }
        }
        if let l = left.answeredBy, let r = right.answeredBy, l != r {
            out.append("answered by: \(l) against \(r)")
        }
        if out.isEmpty { out.append("Nothing differs in the recorded settings.") }
        return out
    }
}
