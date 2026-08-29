import Foundation

/// A notebook's record, as something you can send someone.
///
/// **Research that cannot leave the tool it was done in is research nobody
/// else can check.** The record has always been on disk as JSON Lines, which is
/// the right thing for a machine and the wrong thing for a colleague: it holds
/// every fact and reads like a log.
///
/// So this renders the same facts as Markdown, and it renders *all* of them.
/// The temptation is to export the questions and answers and drop the
/// provenance, which would produce a clean document that quietly loses the only
/// part that makes the answers checkable. Somebody reading an exported answer
/// should be able to see which passages produced it, how well they scored,
/// which machine wrote it, and whether it was cut off.
public enum Transcript {

    /// One turn, for copying a single answer out.
    public static func markdown(_ turn: NotebookPackage.Turn,
                                number: Int? = nil) -> String {
        var out = ""
        let heading = number.map { "## \($0). \(turn.question)" }
                      ?? "## \(turn.question)"
        out += heading + "\n\n"
        out += turn.answer.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"

        if turn.wasTruncated {
            let limit = turn.maxTokensApplied.map(String.init) ?? "its limit"
            out += "\n> **This answer was cut off** at \(limit) tokens"
            if turn.cappedByPolicy == true, let node = turn.answeredBy {
                let state = turn.presenceState.map { " (\($0))" } ?? ""
                out += ", capped by policy on \(node)\(state)"
            }
            out += ".\n"
        }

        if !turn.citations.isEmpty {
            out += "\n### Retrieved\n\n"
            for c in turn.citations {
                out += String(format: "- `%.3f` %@\n", c.score, c.citation)
            }
        }

        let facts = provenance(of: turn)
        if !facts.isEmpty {
            out += "\n" + facts.joined(separator: " · ") + "\n"
        }
        return out
    }

    /// The whole record, with a header saying what produced it.
    ///
    /// The header is not decoration. An exported transcript that does not name
    /// the corpus, the embedding model or the date is a document whose answers
    /// cannot be reproduced, and answers that cannot be reproduced are
    /// anecdotes.
    public static func markdown(_ turns: [NotebookPackage.Turn],
                                manifest: NotebookPackage.Manifest,
                                sources: [String] = [],
                                chunks: Int? = nil,
                                exportedAt: Date = Date()) -> String {
        var out = "# \(manifest.name)\n\n"

        var header: [String] = []
        if !sources.isEmpty {
            header.append(sources.count == 1
                          ? "1 source: \(sources[0])"
                          : "\(sources.count) sources: \(sources.joined(separator: ", "))")
        }
        if let chunks { header.append("\(chunks) chunks") }
        header.append("embedded with \(short(manifest.embeddingModel))")
        header.append(turns.count == 1 ? "1 question" : "\(turns.count) questions")
        out += header.joined(separator: " · ") + "\n\n"

        let stamp = DateFormatter()
        stamp.dateFormat = "d MMMM yyyy 'at' HH:mm"
        stamp.locale = Locale(identifier: "en_GB")
        out += "*Exported \(stamp.string(from: exportedAt)) from notebookMLX.*\n"

        guard !turns.isEmpty else {
            return out + "\nNothing has been asked of this notebook yet.\n"
        }

        for (index, turn) in turns.enumerated() {
            out += "\n---\n\n" + markdown(turn, number: index + 1)
        }
        return out
    }

    /// The settings a turn ran under, in the order they matter.
    ///
    /// Rendered as italic small print rather than a table: it belongs to the
    /// answer above it and a table would give it equal billing with the prose.
    static func provenance(of turn: NotebookPackage.Turn) -> [String] {
        var out = ["*k \(turn.k)", turn.hybrid ? "hybrid" : "semantic"]
        if let node = turn.answeredBy {
            out.append(turn.presenceState.map { "\(node) (\($0))" } ?? node)
        }
        if let model = turn.generationModel { out.append(short(model)) }
        if let seconds = turn.seconds { out.append(String(format: "%.1fs", seconds)) }
        out.append(short(turn.embeddingModel))
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime,
                               .withDashSeparatorInDate, .withSpaceBetweenDateAndTime]
        out.append(stamp.string(from: turn.askedAt) + "*")
        return out
    }

    static func short(_ model: String) -> String {
        String(model.split(separator: "/").last ?? Substring(model))
    }

    /// A file name that will not surprise anybody.
    ///
    /// Notebook names are typed by people and contain slashes and colons, both
    /// of which mean something to a file system.
    public static func fileName(for manifest: NotebookPackage.Manifest,
                                on date: Date = Date()) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        let safe = manifest.name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(safe.isEmpty ? "Notebook" : safe) \(stamp.string(from: date)).md"
    }
}
