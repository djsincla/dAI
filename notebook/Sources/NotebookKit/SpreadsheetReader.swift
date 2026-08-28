import CoreXLSX
import Foundation

/// Excel workbooks, one table per sheet.
///
/// A workbook is not a document. It is several, and treating it as one puts
/// unrelated tables in the same section so a per-section cap can no longer stop
/// one of them filling an answer. So each sheet becomes its own table, named
/// after itself, and a workbook with three sheets adds three sources.
public enum SpreadsheetReader {

    public static func read(_ url: URL) throws -> [Extraction.Table] {
        guard let file = XLSXFile(filepath: url.path) else {
            throw Extraction.Failure.unreadable(
                url.lastPathComponent,
                "it is not a readable xlsx. Excel's older .xls is a different "
                + "format entirely and needs converting first.")
        }

        // The shared string table. xlsx stores most text once here and refers
        // to it by index from the cells, so a reader that ignores it sees
        // numbers where the words were.
        let shared = try? file.parseSharedStrings()
        var tables: [Extraction.Table] = []

        for path in try file.parseWorksheetPaths() {
            let worksheet = try file.parseWorksheet(at: path)
            let name = sheetName(file: file, path: path)
                ?? url.deletingPathExtension().lastPathComponent

            var rows: [[String]] = []
            for row in worksheet.data?.rows ?? [] {
                let values = row.cells.map { cell in
                    value(of: cell, shared: shared)
                }
                // A row of nothing is a spacer in a spreadsheet and a chunk
                // about nothing in an index.
                if values.contains(where: { !$0.isEmpty }) { rows.append(values) }
            }
            guard !rows.isEmpty else { continue }

            let header = rows.removeFirst().map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard header.contains(where: { !$0.isEmpty }) else {
                // Refused per sheet rather than for the workbook: one sheet of
                // notes without a header should not stop the other three being
                // read. Guessing its columns would poison every chunk from it.
                throw Extraction.Failure.noHeader("\(url.lastPathComponent): \(name)")
            }
            tables.append(Extraction.Table(
                name: name, header: DocumentReader.named(header), rows: rows))
        }

        guard !tables.isEmpty else {
            throw Extraction.Failure.empty(url.lastPathComponent)
        }
        return tables
    }

    /// One cell as text.
    ///
    /// **A formula cell contributes its cached value, not its formula.**
    /// `=SUM(B2:B40)` embeds as nothing anybody would ask, while `1,284` is the
    /// number on the screen and the number a reader means. Excel stores both;
    /// this takes the one that was displayed.
    static func value(of cell: Cell, shared: SharedStrings?) -> String {
        if let shared, let text = cell.stringValue(shared) { return text }
        if let inline = cell.inlineString?.text { return inline }
        // The cached result of a formula lives in the value field, which is
        // also where a plain number lives. Either way it is what was shown.
        return cell.value ?? ""
    }

    static func sheetName(file: XLSXFile, path: String) -> String? {
        guard let workbook = try? file.parseWorkbooks().first else { return nil }
        let sheets = workbook.sheets.items
        // Matched on the relationship id where possible; the paths themselves
        // are sheet1.xml and say nothing a person would recognise.
        for sheet in sheets {
            if let found = try? file.parseWorksheetPathsAndNames(workbook: workbook)
                .first(where: { $0.path == path }) {
                return found.name ?? sheet.name
            }
        }
        return nil
    }
}
