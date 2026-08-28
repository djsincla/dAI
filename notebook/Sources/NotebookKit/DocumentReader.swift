import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Turning a dropped file into text or a table.
///
/// Reading is separate from chunking on purpose. A PDF and a text file differ
/// in how you get the words out and not at all in what you do with them
/// afterwards, and a CSV differs in both. Keeping the two apart is what lets
/// the chunker be tested without a file and the readers be tested without an
/// embedding model.
public enum DocumentReader {

    public enum Content: Sendable, Equatable {
        /// Prose, with a locator for each page where the format has pages.
        case prose(text: String, pages: [Int: String])
        /// One or more tables. A workbook is several documents rather than one:
        /// putting unrelated sheets in the same section would stop the
        /// per-section cap doing its job.
        case tables([Extraction.Table])
    }

    /// Whether this is worth streaming rather than reading whole.
    ///
    /// A PDF is, because its text is held twice while it is being read: once
    /// per page and once concatenated. The VCF document extracts to 21.7M
    /// characters, so reading it whole costs about 90 MB of strings before a
    /// single chunk exists, and the chunks are a third copy.
    public static func isPaged(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// One page at a time, holding one page at a time.
    ///
    /// The document is opened once and each page's text is handed over and then
    /// released. Nothing accumulates here: it is the caller's business what to
    /// keep, and the caller's job to keep as little as possible.
    public static func eachPage(
        of url: URL,
        _ body: (_ number: Int, _ pages: Int, _ text: String) throws -> Void) throws {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            throw Extraction.Failure.unreadable(
                url.lastPathComponent, "PDFKit could not open it")
        }
        var sawText = false
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index),
                  let text = page.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            sawText = true
            // 1 based, matching what a reader sees in a PDF viewer.
            try body(index + 1, document.pageCount, text)
        }
        guard sawText else {
            throw Extraction.Failure.unreadable(
                url.lastPathComponent,
                "it has no text layer. A scan needs OCR before it can be read.")
        }
        #else
        throw Extraction.Failure.unreadable(url.lastPathComponent,
                                            "PDF reading needs PDFKit")
        #endif
    }

    public static func read(_ url: URL) throws -> Content {
        switch url.pathExtension.lowercased() {
        case "pdf": return try pdf(url)
        case "csv": return .tables([try delimited(url, separator: ",")])
        case "tsv": return .tables([try delimited(url, separator: "\t")])
        case "xlsx": return .tables(try SpreadsheetReader.read(url))
        case "xls":
            throw Extraction.Failure.unreadable(
                url.lastPathComponent,
                "the older .xls format is not xlsx and cannot be read. Save it "
                + "as .xlsx or export the sheet as CSV.")
        default: return try plain(url)
        }
    }

    // ------------------------------------------------------------- prose

    static func plain(_ url: URL) throws -> Content {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw Extraction.Failure.unreadable(url.lastPathComponent, "no such file")
        }
        // Decoded permissively. A document that is nearly UTF-8 is still worth
        // reading, and refusing it over one bad byte helps nobody.
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Extraction.Failure.empty(url.lastPathComponent)
        }
        return .prose(text: text, pages: [:])
    }

    /// A PDF, page by page.
    ///
    /// Pages are kept rather than concatenated, because a citation that can
    /// open the original at the right page is worth far more than one that
    /// quotes a fragment. That is the whole reason this app keeps the original
    /// file: `vcf91.pdf#page=2517` is checkable and a quotation is not.
    static func pdf(_ url: URL) throws -> Content {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else {
            throw Extraction.Failure.unreadable(
                url.lastPathComponent, "PDFKit could not open it")
        }
        var pages: [Int: String] = [:]
        var whole = ""
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index),
                  let text = page.string else { continue }
            // 1 based, matching what a reader sees in a PDF viewer and what the
            // Python extraction wrote into its urls.
            pages[index + 1] = text
            whole += text + "\n\n"
        }
        guard !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A scanned PDF with no text layer extracts to nothing. It is not
            // corrupt and saying "empty" would be misleading, so it says what
            // is actually missing.
            throw Extraction.Failure.unreadable(
                url.lastPathComponent,
                "it has no text layer. A scan needs OCR before it can be read.")
        }
        return .prose(text: whole, pages: pages)
        #else
        throw Extraction.Failure.unreadable(url.lastPathComponent,
                                            "PDF reading needs PDFKit")
        #endif
    }

    // ------------------------------------------------------------- tables

    static func delimited(_ url: URL, separator: Character) throws -> Extraction.Table {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw Extraction.Failure.unreadable(url.lastPathComponent, "no such file")
        }
        var rows = parseDelimited(String(decoding: data, as: UTF8.self),
                                  separator: separator)
        guard !rows.isEmpty else {
            throw Extraction.Failure.empty(url.lastPathComponent)
        }
        let header = rows.removeFirst().map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard header.contains(where: { !$0.isEmpty }) else {
            throw Extraction.Failure.noHeader(url.lastPathComponent)
        }
        return Extraction.Table(
            name: url.deletingPathExtension().lastPathComponent,
            header: named(header), rows: rows)
    }

    /// Column names, with the blanks and duplicates made usable.
    ///
    /// A spreadsheet exported from anywhere has an unnamed column or two, and
    /// two columns called "Date" is common. Both would produce chunks where a
    /// value is labelled with nothing or labelled ambiguously, so they are
    /// numbered rather than left alone.
    static func named(_ header: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return header.enumerated().map { index, raw in
            let base = raw.isEmpty ? "Column \(index + 1)" : raw
            let count = seen[base, default: 0] + 1
            seen[base] = count
            return count == 1 ? base : "\(base) \(count)"
        }
    }

    /// RFC 4180 enough for real files.
    ///
    /// Quoted fields, doubled quotes inside them, and newlines inside quotes.
    /// Splitting on commas and newlines instead handles the easy half of the
    /// files people actually have and silently mangles the rest: a field
    /// containing a comma becomes two columns and every row after it is
    /// misaligned, which reads as a corrupt file rather than a parsing bug.
    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            // A trailing newline should not produce a row of one empty field.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") }  // escaped quote
                        else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty: inQuotes = true
            case separator: endField()
            // "\r\n" is one Character in Swift, not two: CRLF is a single
            // extended grapheme cluster. Matching only "\n" and "\r" therefore
            // matches neither, and a file exported from Windows parses as one
            // enormous row with the line endings buried inside the fields.
            case "\r\n", "\n", "\r": endRow()
            default: field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
