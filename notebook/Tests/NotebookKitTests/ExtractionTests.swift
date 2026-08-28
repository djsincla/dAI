import Foundation
import Testing
@testable import NotebookKit

/// Chunking, which decides what can be retrieved at all.
///
/// A boundary through the middle of the sentence that answers a question loses
/// that answer from both sides, and nothing downstream can tell: the index is
/// full, the scores look ordinary, and the right passage simply never comes
/// back. So these test the boundaries rather than the happy path.
struct ProseChunkingTests {

    static func paragraphs(_ n: Int, each: Int = 200) -> String {
        (1 ... n).map { i in
            "Paragraph \(i). " + String(repeating: "word ", count: each / 5)
        }.joined(separator: "\n\n")
    }

    @Test("short prose is one chunk, not one per paragraph")
    func shortProseStaysWhole() throws {
        let text = "First paragraph.\n\nSecond paragraph."
        let chunks = try Extraction.prose(text, title: "T", locator: "l")
        #expect(chunks.count == 1)
        #expect(chunks[0].text.contains("First"))
        #expect(chunks[0].text.contains("Second"))
    }

    @Test("long prose is cut, and every part knows how many there are")
    func longProseIsCut() throws {
        let chunks = try Extraction.prose(Self.paragraphs(12), title: "T",
                                          locator: "l")
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.parts == chunks.count })
        #expect(chunks.map(\.part) == Array(0 ..< chunks.count))
    }

    @Test("consecutive chunks overlap, so a boundary is survivable")
    func chunksOverlap() throws {
        // The property that matters, tested through its consequence rather than
        // by counting characters: text near a boundary must appear in both
        // chunks, or a fact that straddles one is retrievable from neither.
        let settings = Extraction.Settings(chunkChars: 300, overlap: 80)
        let chunks = try Extraction.prose(Self.paragraphs(6, each: 120),
                                          title: "T", locator: "l",
                                          settings: settings)
        try #require(chunks.count >= 2)
        let tail = String(chunks[0].text.suffix(40))
        #expect(chunks[1].text.contains(tail),
                "the second chunk should start inside the first")
    }

    @Test("a paragraph longer than the budget is still cut")
    func oversizedParagraph() throws {
        let settings = Extraction.Settings(chunkChars: 200, overlap: 40)
        let one = String(repeating: "sentence ", count: 400)
        let chunks = try Extraction.prose(one, title: "T", locator: "l",
                                          settings: settings)
        #expect(chunks.count > 1)
        // Nothing may exceed twice the budget: the embedding model reads a
        // fixed number of tokens and silently drops the rest.
        #expect(chunks.allSatisfy { $0.text.count <= settings.chunkChars * 2 })
    }

    @Test("a short tail joins the chunk before it")
    func shortTailIsFolded() throws {
        // A sixty character chunk carries almost no signal and competes for a
        // slot with chunks that do.
        let settings = Extraction.Settings(chunkChars: 300, overlap: 0,
                                           minChunkChars: 150)
        let text = Self.paragraphs(2, each: 280) + "\n\nShort."
        let chunks = try Extraction.prose(text, title: "T", locator: "l",
                                          settings: settings)
        #expect(chunks.last?.text.contains("Short.") == true)
        #expect(chunks.allSatisfy { $0.text.count >= settings.minChunkChars }
                || chunks.count == 1)
    }

    @Test("empty text is refused rather than indexed")
    func refusesEmpty() {
        // An empty chunk embeds to a fixed point that is about nothing and is
        // then weakly similar to everything.
        #expect(throws: Extraction.Failure.self) {
            try Extraction.prose("   \n\n  ", title: "T", locator: "l")
        }
    }
}

/// Tables, which are a different problem and fail differently.
struct TableChunkingTests {

    static let table = Extraction.Table(
        name: "sales",
        header: ["Region", "Units", "Date"],
        rows: [["Auckland", "42", "2026-03-01"],
               ["Wellington", "17", "2026-03-02"]])

    @Test("one chunk per row, each carrying its column names")
    func rowsCarryTheHeader() throws {
        // Without the header a row is noise: nothing downstream knows the third
        // value was a date, and it cannot be recovered from the vector.
        let chunks = try Extraction.rows(of: Self.table, locator: "sales.csv")
        #expect(chunks.count == 2)
        #expect(chunks[0].text == "Region: Auckland; Units: 42; Date: 2026-03-01")
        #expect(chunks[1].text.contains("Region: Wellington"))
    }

    @Test("every row of a sheet shares a section, so one table cannot fill an answer")
    func rowsShareASection() throws {
        let chunks = try Extraction.rows(of: Self.table, locator: "sales.csv")
        #expect(Set(chunks.map(\.section)) == ["sales"])
        #expect(chunks[0].locator == "sales.csv#row=1")
    }

    @Test("empty cells are dropped rather than labelled")
    func skipsEmptyCells() throws {
        let sparse = Extraction.Table(name: "t", header: ["A", "B", "C"],
                                      rows: [["1", "", "3"]])
        let chunks = try Extraction.rows(of: sparse, locator: "t.csv")
        #expect(chunks[0].text == "A: 1; C: 3")
    }

    @Test("a table with no header is refused")
    func refusesHeaderless() {
        // Guessing wrong poisons every chunk from the sheet rather than one row.
        let headerless = Extraction.Table(name: "t", header: [], rows: [["1"]])
        #expect(throws: Extraction.Failure.self) {
            try Extraction.rows(of: headerless, locator: "t.csv")
        }
    }

    @Test("an aggregate question is recognised, so it can be warned about")
    func spotsAggregation() {
        // Retrieval cannot answer these and will return the nearest plausible
        // row, which reads exactly like an answer.
        for q in ["what was the Q3 total", "how many units in Auckland",
                  "average units per region", "which region was highest"] {
            #expect(Extraction.looksLikeAggregation(q), "\(q)")
        }
        for q in ["which rows mention Auckland", "what is a workload domain",
                  "show me the March entries"] {
            #expect(!Extraction.looksLikeAggregation(q), "\(q)")
        }
    }
}

/// CSV, where naive splitting mangles real files silently.
struct DelimitedReaderTests {

    @Test("a quoted field containing the separator stays one field")
    func quotedSeparator() {
        // Splitting on commas turns this into two columns and misaligns every
        // row after it, which reads as a corrupt file rather than a bug.
        let rows = DocumentReader.parseDelimited(
            "a,b\n\"Auckland, NZ\",42\n", separator: ",")
        #expect(rows == [["a", "b"], ["Auckland, NZ", "42"]])
    }

    @Test("a quoted field can contain a newline")
    func quotedNewline() {
        let rows = DocumentReader.parseDelimited(
            "a,b\n\"line one\nline two\",42\n", separator: ",")
        #expect(rows.count == 2)
        #expect(rows[1][0] == "line one\nline two")
    }

    @Test("a doubled quote is one quote")
    func escapedQuote() {
        let rows = DocumentReader.parseDelimited(
            "a\n\"she said \"\"hello\"\"\"\n", separator: ",")
        #expect(rows[1][0] == "she said \"hello\"")
    }

    @Test("carriage returns and a trailing newline do not add rows")
    func lineEndings() {
        let rows = DocumentReader.parseDelimited("a,b\r\n1,2\r\n", separator: ",")
        #expect(rows == [["a", "b"], ["1", "2"]])
    }

    @Test("blank and duplicate column names are made usable")
    func headerNaming() {
        // Both are ordinary in an exported spreadsheet, and both would produce
        // chunks where a value is labelled with nothing or ambiguously.
        #expect(DocumentReader.named(["Date", "", "Date"])
                == ["Date", "Column 2", "Date 2"])
    }
}
