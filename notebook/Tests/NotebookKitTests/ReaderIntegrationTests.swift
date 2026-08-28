import Foundation
import Testing
@testable import NotebookKit

/// The readers against real files, skipped when they are not present.
///
/// A parser that works on a fixture and not on the document somebody actually
/// has is a parser that has not been tested. These use the corpora in
/// examples/python, which is where the real awkwardness lives.
struct ReaderIntegrationTests {

    static let vcfPDF = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(
            "Developer/dAI/examples/python/vcf91/vmware-cloud-foundation-9-1.pdf")

    static var hasVCF: Bool {
        FileManager.default.fileExists(atPath: vcfPDF.path)
    }

    @Test("PDFKit reads the 8,894 page document, with its pages",
          .enabled(if: ReaderIntegrationTests.hasVCF))
    func readsALargePDF() throws {
        let content = try DocumentReader.read(Self.vcfPDF)
        guard case let .prose(text, pages) = content else {
            Issue.record("a PDF should read as prose"); return
        }
        // The Python extraction found 8,894 pages and 21.7M characters, so this
        // is a check against a known answer rather than against itself.
        #expect(pages.count > 8000, "found \(pages.count) pages")
        #expect(text.count > 15_000_000, "found \(text.count) characters")
        // Pages are 1 based, matching what a reader sees and what the citations
        // in the imported notebooks already say.
        #expect(pages[1] != nil)
        #expect(pages[0] == nil)
    }

    @Test("a csv with quoted separators and CRLF survives a round trip")
    func readsAWindowsCSV() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).csv")
        let csv = "Region,Units,Note\r\n\"Auckland, NZ\",42,\"said \"\"yes\"\"\"\r\n"
        try Data(csv.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case let .table(table) = try DocumentReader.read(url) else {
            Issue.record("a csv should read as a table"); return
        }
        #expect(table.header == ["Region", "Units", "Note"])
        #expect(table.rows == [["Auckland, NZ", "42", "said \"yes\""]])

        let chunks = try Extraction.rows(of: table, locator: url.lastPathComponent)
        #expect(chunks.count == 1)
        #expect(chunks[0].text.contains("Region: Auckland, NZ"))
    }
}
