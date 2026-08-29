import Testing
@testable import NotebookKit

/// Linking an answer back to the pages it came from.
///
/// The bar is not "finds as many as possible". A link that opens the wrong page
/// is a claim about provenance that is silently false, which is worse than a
/// name the reader has to look up themselves. So the tests that matter most are
/// the ones about not matching.
@Suite("Answer links")
struct AnswerLinksTests {

    private func text(_ s: String, _ citations: [String]) -> [String] {
        AnswerLinks.find(in: s, citations: citations).map { String(s[$0.range]) }
    }

    @Test("finds a citation named exactly")
    func exact() {
        let answer = "You add a host as described in vcf-9-1.pdf p2518 (2/6)."
        let found = AnswerLinks.find(in: answer, citations: ["vcf-9-1.pdf p2518 (2/6)"])
        #expect(found.count == 1)
        #expect(found[0].citation == 0)
        #expect(String(answer[found[0].range]) == "vcf-9-1.pdf p2518 (2/6)")
    }

    /// A model quoting a citation in a sentence routinely drops the part
    /// suffix, because the part is about the index rather than the document.
    @Test("finds a citation quoted without its part suffix")
    func withoutPart() {
        let answer = "This is covered in vcf-9-1.pdf p2518 in some detail."
        #expect(text(answer, ["vcf-9-1.pdf p2518 (2/6)"]) == ["vcf-9-1.pdf p2518"])
    }

    @Test("finds every mention, in the order they appear")
    func several() {
        let answer = "First see a.pdf p1, then b.pdf p2, and a.pdf p1 again."
        let found = AnswerLinks.find(in: answer, citations: ["a.pdf p1", "b.pdf p2"])
        #expect(found.map(\.citation) == [0, 1, 0])
    }

    /// The overlap rule: when one citation's name contains another's, the
    /// longer match is the one the writer meant.
    @Test("the longer name wins where two overlap")
    func overlapping() {
        let answer = "See notes.pdf p12 appendix for the rest."
        let found = AnswerLinks.find(in: answer,
                                     citations: ["notes.pdf p12",
                                                 "notes.pdf p12 appendix"])
        #expect(found.count == 1)
        #expect(found[0].citation == 1)
        #expect(String(answer[found[0].range]) == "notes.pdf p12 appendix")
    }

    @Test("a citation the answer never names is not linked")
    func absent() {
        #expect(text("Nothing in here names a source.", ["a.pdf p1"]).isEmpty)
    }

    /// The refusal that matters. Trimming a citation down far enough would
    /// start matching ordinary prose, so short remainders are not tried.
    @Test("does not shorten a citation into something that matches prose")
    func doesNotOverTrim() {
        // Stripping "(1/2)" would leave "p12", which appears in the sentence
        // by coincidence and must not become a link.
        let answer = "The value p12 is unrelated to anything cited."
        #expect(text(answer, ["p12 (1/2)"]).isEmpty)
    }

    @Test("no citations and no answer are both empty rather than errors")
    func empty() {
        #expect(AnswerLinks.find(in: "", citations: ["a.pdf p1"]).isEmpty)
        #expect(AnswerLinks.find(in: "some text", citations: []).isEmpty)
    }

    @Test("matching ignores case, since a model may start a sentence with it")
    func caseInsensitive() {
        #expect(text("Vcf-9-1.pdf P2518 explains it.",
                     ["vcf-9-1.pdf p2518"]) == ["Vcf-9-1.pdf P2518"])
    }
}
