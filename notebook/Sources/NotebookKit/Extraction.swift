import Foundation

/// Turning a dropped file into chunks worth embedding.
///
/// **Two kinds of document, and they are not the same problem.**
///
/// Prose (text, markdown, PDF) is chunked by size with an overlap, because a
/// sentence that answers a question can fall anywhere and a boundary through
/// the middle of it loses the answer from both sides.
///
/// Tables (CSV, Excel) are chunked by row, because a row is the unit of meaning
/// and slicing a spreadsheet by character count produces fragments that mean
/// nothing. `Auckland, 42, 2026-03-01` is noise; `Region: Auckland; Units: 42;
/// Date: 2026-03-01` is a sentence a model was trained on.
///
/// The honest limitation, stated here because it has to be said somewhere the
/// code can point at: **retrieval over a table answers lookup well and
/// aggregation wrongly.** "Which rows mention Auckland" is a retrieval
/// question. "What was the Q3 total" is arithmetic, and the nearest chunk to
/// that question will always look plausible and will not be a total. The rows
/// are kept in the package so that arithmetic can be done properly later.
public enum Extraction {

    public struct Chunk: Sendable, Equatable {
        /// What a citation shows: the section title, or the sheet and row.
        public var citation: String
        /// The grouping a per-section cap applies to.
        public var section: String
        /// Where it came from, for opening the original at the right place.
        public var locator: String
        public var text: String
        public var part: Int
        public var parts: Int

        public init(citation: String, section: String, locator: String,
                    text: String, part: Int = 0, parts: Int = 1) {
            self.citation = citation
            self.section = section
            self.locator = locator
            self.text = text
            self.part = part
            self.parts = parts
        }
    }

    public struct Settings: Sendable, Equatable {
        public var chunkChars: Int
        public var overlap: Int
        /// Below this, a trailing fragment is folded into the chunk before it
        /// rather than embedded alone. A sixty character chunk carries almost
        /// no signal and competes for a slot with chunks that do.
        public var minChunkChars: Int

        public init(chunkChars: Int = 600, overlap: Int = 100,
                    minChunkChars: Int = 120) {
            self.chunkChars = chunkChars
            self.overlap = overlap
            self.minChunkChars = minChunkChars
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case empty(String)
        case noHeader(String)
        case unreadable(String, String)

        public var description: String {
            switch self {
            case let .empty(name):
                return "\(name) produced no text. A file that extracts to "
                     + "nothing would add chunks that match everything weakly."
            case let .noHeader(name):
                return "\(name) has no header row. Every chunk from a table "
                     + "carries its column names, and guessing them wrong "
                     + "poisons the whole sheet rather than one row."
            case let .unreadable(name, why):
                return "\(name) could not be read: \(why)"
            }
        }
    }

    // ------------------------------------------------------------- prose

    /// Split prose on paragraph boundaries where it can, on size where it must.
    ///
    /// The overlap is what makes a boundary survivable: a sentence cut in half
    /// appears whole in the next chunk. Without it a fact that straddles a
    /// boundary is retrievable from neither side, which is invisible in the
    /// index and shows up only as an answer that should have been found.
    public static func prose(_ text: String, title: String, locator: String,
                             settings: Settings = .init()) throws -> [Chunk] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw Failure.empty(title) }

        let paragraphs = cleaned
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var pieces: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if current.isEmpty {
                current = paragraph
            } else if current.count + paragraph.count + 2 <= settings.chunkChars {
                current += "\n\n" + paragraph
            } else {
                pieces.append(current)
                // Carry the tail of the previous chunk into the next one.
                let tail = String(current.suffix(settings.overlap))
                current = settings.overlap > 0 ? tail + "\n\n" + paragraph : paragraph
            }
            // A single paragraph longer than the budget still has to be cut.
            while current.count > settings.chunkChars * 2 {
                pieces.append(String(current.prefix(settings.chunkChars)))
                current = String(current.dropFirst(
                    max(1, settings.chunkChars - settings.overlap)))
            }
        }
        if !current.isEmpty {
            // A short tail joins the chunk before it rather than standing alone.
            if current.count < settings.minChunkChars, var last = pieces.popLast() {
                last += "\n\n" + current
                pieces.append(last)
            } else {
                pieces.append(current)
            }
        }

        return pieces.enumerated().map { index, piece in
            Chunk(citation: title, section: title, locator: locator,
                  text: piece, part: index, parts: pieces.count)
        }
    }

    // ------------------------------------------------------------- tables

    /// A parsed table: a header and its rows, both kept.
    public struct Table: Sendable, Equatable {
        public var name: String
        public var header: [String]
        public var rows: [[String]]

        public init(name: String, header: [String], rows: [[String]]) {
            self.name = name
            self.header = header
            self.rows = rows
        }
    }

    /// One chunk per row, each carrying its column names.
    ///
    /// The header travels with every row because a row without it cannot be
    /// recovered: nothing downstream knows that the third value was a date. It
    /// costs a few tokens per chunk and buys the difference between a chunk
    /// that means something and one that does not.
    public static func rows(of table: Table, locator: String) throws -> [Chunk] {
        guard !table.header.isEmpty else { throw Failure.noHeader(table.name) }
        guard !table.rows.isEmpty else { throw Failure.empty(table.name) }

        return table.rows.enumerated().map { index, row in
            let rendered = zip(table.header, row)
                .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { "\($0.0): \($0.1)" }
                .joined(separator: "; ")
            return Chunk(
                citation: "\(table.name) row \(index + 1)",
                // Every row of one sheet shares a section, so the per-section
                // cap stops one table filling every slot of an answer.
                section: table.name,
                locator: "\(locator)#row=\(index + 1)",
                text: rendered, part: index, parts: table.rows.count)
        }
    }

    /// Whether a question is asking a table for arithmetic rather than a row.
    ///
    /// Used to warn, never to refuse the question outright. Retrieval cannot
    /// answer this and will return the nearest plausible row, which reads like
    /// an answer. Saying so is the only honest option until the rows are
    /// queried properly.
    public static func looksLikeAggregation(_ question: String) -> Bool {
        let q = question.lowercased()
        let words = ["total", "sum", "average", "mean", "count of", "how many",
                     "median", "maximum", "minimum", "largest", "smallest",
                     "highest", "lowest", "per cent", "percent"]
        return words.contains { q.contains($0) }
    }
}
