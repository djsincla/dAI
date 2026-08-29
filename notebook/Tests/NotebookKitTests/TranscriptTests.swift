import Foundation
import Testing
@testable import NotebookKit

/// Exporting a record.
///
/// The tests worth writing here are about what must not be dropped. A transcript
/// that reads well and has quietly lost the scores, the machine or the fact that
/// an answer was cut off is worse than no export: it looks complete.
@Suite("Transcript")
struct TranscriptTests {

    private func turn(_ question: String = "what happens",
                      answer: String = "It is deleted.",
                      truncated: Bool = false,
                      citations: [NotebookPackage.Turn.Citation] = []) -> NotebookPackage.Turn {
        NotebookPackage.Turn(
            askedAt: Date(timeIntervalSince1970: 1_787_000_000),
            question: question, answer: answer, citations: citations,
            k: 6, hybrid: false,
            embeddingModel: "mlx-community/Qwen3-Embedding-0.6B-8bit",
            answeredBy: "orca", presenceState: "ACTIVE",
            generationModel: "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
            seconds: 5.4,
            finishReason: truncated ? "length" : "stop",
            maxTokensApplied: 256, cappedByPolicy: truncated)
    }

    private let cite = NotebookPackage.Turn.Citation(
        citation: "vcf-9-1.pdf p2518 (2/6)", section: "vcf-9-1.pdf p2518",
        url: "vcf-9-1.pdf#page=2518#part=2", score: 0.7612)

    @Test("a turn carries its question, answer and scores")
    func oneTurn() {
        let out = Transcript.markdown(turn(citations: [cite]), number: 3)
        #expect(out.contains("## 3. what happens"))
        #expect(out.contains("It is deleted."))
        #expect(out.contains("### Retrieved"))
        // The score to three places, as the window shows it.
        #expect(out.contains("`0.761`"))
        #expect(out.contains("vcf-9-1.pdf p2518 (2/6)"))
    }

    /// The one that matters most. An exported answer that was cut off must say
    /// so, or the reader has no way to tell it from a complete one.
    @Test("a truncated answer says so, and says what capped it")
    func truncation() {
        let out = Transcript.markdown(turn(truncated: true))
        #expect(out.contains("cut off"))
        #expect(out.contains("256"))
        #expect(out.contains("orca"))
        #expect(out.contains("ACTIVE"))
    }

    @Test("a finished answer is not decorated with a warning")
    func notTruncated() {
        #expect(!Transcript.markdown(turn()).contains("cut off"))
    }

    @Test("provenance names the machine, the models and the settings")
    func provenance() {
        let out = Transcript.markdown(turn())
        #expect(out.contains("k 6"))
        #expect(out.contains("semantic"))
        #expect(out.contains("orca"))
        #expect(out.contains("Qwen3-30B-A3B-Instruct-2507-4bit"))
        #expect(out.contains("Qwen3-Embedding-0.6B-8bit"))
        // Long model ids are shortened, but never to nothing.
        #expect(!out.contains("mlx-community/"))
    }

    @Test("the whole record names the corpus that produced it")
    func header() {
        let manifest = NotebookPackage.Manifest(name: "VCF")
        let out = Transcript.markdown([turn(), turn("and then?")],
                                      manifest: manifest,
                                      sources: ["vcf-9-1.pdf"], chunks: 35_504)
        #expect(out.hasPrefix("# VCF"))
        #expect(out.contains("1 source: vcf-9-1.pdf"))
        #expect(out.contains("35504 chunks"))
        #expect(out.contains("2 questions"))
        #expect(out.contains("Qwen3-Embedding-0.6B-8bit"))
    }

    @Test("turns are numbered in the order they were asked")
    func numbering() {
        let out = Transcript.markdown([turn("first"), turn("second")],
                                      manifest: .init(name: "N"))
        let first = out.range(of: "## 1. first")
        let second = out.range(of: "## 2. second")
        #expect(first != nil && second != nil)
        #expect(first!.lowerBound < second!.lowerBound)
    }

    @Test("a notebook nobody has asked anything of exports honestly")
    func empty() {
        let out = Transcript.markdown([], manifest: .init(name: "Fresh"))
        #expect(out.contains("Nothing has been asked"))
        #expect(out.contains("0 questions"))
    }

    /// Notebook names are typed by people and end up in file systems.
    @Test("a name with path characters becomes a usable file name")
    func fileNames() {
        let name = Transcript.fileName(
            for: .init(name: "Q3/Q4: notes"),
            on: Date(timeIntervalSince1970: 1_787_000_000))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.hasSuffix(".md"))
        #expect(name.contains("Q3-Q4"))
    }

    @Test("an unnamed notebook still gets a file name")
    func blankName() {
        #expect(Transcript.fileName(for: .init(name: "  ")).hasPrefix("Notebook "))
    }
}
