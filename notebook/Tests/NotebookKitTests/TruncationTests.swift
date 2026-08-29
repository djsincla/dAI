import Foundation
import Testing
@testable import NotebookKit

/// Recording that an answer was cut off.
///
/// The record is a file format, and this change adds fields to it. Every
/// notebook already on disk was written without them, so the test that matters
/// is not that the new fields work but that the old lines still decode: a
/// record that failed to parse would lose the whole conversation to make room
/// for a footnote about one turn.
@Suite("Truncation on the record")
struct TruncationTests {

    private func temporary() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("truncation-\(UUID().uuidString).dainotebook")
    }

    @Test("a turn written before these fields existed still reads")
    func oldRecordsDecode() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try NotebookPackage.create(at: root, manifest: .init(name: "old"))

        // Exactly the shape the app wrote before this change: no finishReason,
        // no maxTokensApplied, no cappedByPolicy.
        let line = """
        {"answer":"cut off here","askedAt":"2026-08-27T10:00:00Z","citations":[],\
        "embeddingModel":"mlx-community/Qwen3-Embedding-0.6B-8bit","hybrid":false,\
        "k":8,"question":"what happens"}
        """
        try (line + "\n").write(to: package.recordURL, atomically: true,
                                encoding: .utf8)

        let turns = try package.turns()
        #expect(turns.count == 1)
        #expect(turns[0].question == "what happens")
        // Unknown rather than false: nothing recorded whether it was cut, and
        // claiming it was not would be inventing evidence.
        #expect(turns[0].finishReason == nil)
        #expect(turns[0].cappedByPolicy == nil)
        #expect(turns[0].wasTruncated == false)
    }

    @Test("a truncated turn round trips and says so")
    func roundTrip() throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try NotebookPackage.create(at: root, manifest: .init(name: "new"))

        try package.append(NotebookPackage.Turn(
            question: "what is destroyed", answer: "The management domain and",
            citations: [], k: 8, hybrid: false,
            embeddingModel: NotebookPackage.Manifest.defaultModel,
            answeredBy: "orca", presenceState: "ACTIVE",
            finishReason: "length", maxTokensApplied: 256, cappedByPolicy: true))

        let read = try package.turns()
        #expect(read.count == 1)
        #expect(read[0].wasTruncated)
        #expect(read[0].maxTokensApplied == 256)
        #expect(read[0].cappedByPolicy == true)
    }

    /// `stop` is the ordinary ending and must not be dressed up as a problem.
    @Test("an answer that finished is not reported as cut off")
    func finishedIsNotTruncated() {
        let turn = NotebookPackage.Turn(
            question: "q", answer: "a", citations: [], k: 8, hybrid: false,
            embeddingModel: "m", finishReason: "stop",
            maxTokensApplied: 256, cappedByPolicy: true)
        // Capped by policy and still finished: the model had no more to say,
        // which is not something to warn about.
        #expect(!turn.wasTruncated)
    }
}
