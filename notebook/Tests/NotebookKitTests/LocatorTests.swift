import Testing
@testable import NotebookKit

/// Reading a locator back.
///
/// These exist because the bug they describe was invisible: a citation opened
/// the document at page one, which looks like a PDF viewer being slow to jump
/// rather than like a parser that returned nil. The case that matters is the
/// second fragment, since that is the one that occurs in almost every real
/// document and never in a hand written example.
@Suite("Locator")
struct LocatorTests {

    @Test("a page with one chunk")
    func singlePart() {
        #expect(Locator.page(of: "vcf.pdf#page=1") == 1)
        #expect(Locator.part(of: "vcf.pdf#page=1") == nil)
    }

    /// The regression. A page that produced several chunks carries both
    /// fragments, and reading only the last one finds no page.
    @Test("a page with several chunks still reports its page")
    func withPart() {
        #expect(Locator.page(of: "vcf.pdf#page=2518#part=3") == 2518)
        #expect(Locator.part(of: "vcf.pdf#page=2518#part=3") == 3)
    }

    @Test("a document with parts and no pages")
    func partsOnly() {
        #expect(Locator.page(of: "statutes.md#part=2") == nil)
        #expect(Locator.part(of: "statutes.md#part=2") == 2)
    }

    @Test("a table row")
    func row() {
        #expect(Locator.row(of: "sales.xlsx#row=417") == 417)
        #expect(Locator.page(of: "sales.xlsx#row=417") == nil)
    }

    @Test("no fragments at all")
    func bare() {
        #expect(Locator.page(of: "notes.txt") == nil)
        #expect(Locator.fileName(of: "notes.txt") == "notes.txt")
    }

    @Test("the file name drops fragments and directories")
    func fileName() {
        #expect(Locator.fileName(of: "vcf.pdf#page=2#part=3") == "vcf.pdf")
        #expect(Locator.fileName(of: "originals/vcf.pdf#page=2") == "vcf.pdf")
        #expect(Locator.fileName(of: "a/b/c.csv#row=1") == "c.csv")
    }

    /// A name that is a prefix of another must not match it. Without the
    /// trailing "=" in the comparison, "page" would match "pages=".
    @Test("a fragment whose name only starts the same is not read")
    func prefixIsNotAMatch() {
        #expect(Locator.page(of: "x.pdf#pages=4") == nil)
        #expect(Locator.part(of: "x.pdf#partial=9") == nil)
    }

    @Test("a fragment with a value that is not a number is ignored")
    func notANumber() {
        #expect(Locator.page(of: "x.pdf#page=iv") == nil)
    }
}
