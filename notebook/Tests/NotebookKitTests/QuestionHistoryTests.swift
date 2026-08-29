import Testing
@testable import NotebookKit

/// Recalling what was asked before.
///
/// The tests that matter are the refusals. An arrow key that recalls when it
/// should have moved the cursor silently destroys a sentence somebody was
/// halfway through writing, and they will not get it back.
@Suite("Question history")
struct QuestionHistoryTests {

    private var three: QuestionHistory {
        QuestionHistory(entries: ["third", "second", "first"])
    }

    @Test("up walks back from newest to oldest")
    func walkBack() {
        var h = three
        #expect(h.older(from: "") == "third")
        #expect(h.older(from: "third") == "second")
        #expect(h.older(from: "second") == "first")
    }

    @Test("the oldest is the end, not a wrap around to the newest")
    func stopsAtTheOldest() {
        var h = three
        _ = h.older(from: "")
        _ = h.older(from: "third")
        _ = h.older(from: "second")
        #expect(h.older(from: "first") == nil)
    }

    @Test("down walks forward and ends at what was being written")
    func returnsTheDraft() {
        var h = three
        #expect(h.older(from: "half a question") == nil)   // it is not recalling
        // Start from empty so recall engages, then walk back and forward.
        #expect(h.older(from: "") == "third")
        #expect(h.older(from: "third") == "second")
        #expect(h.newer(from: "second") == "third")
        #expect(h.newer(from: "third") == "")             // back to the empty draft
    }

    /// The refusal this type exists for.
    @Test("does not recall over something the person typed")
    func neverEatsTypedText() {
        var h = three
        #expect(!h.recalls("what I was writing"))
        #expect(h.older(from: "what I was writing") == nil)
        #expect(h.newer(from: "what I was writing") == nil)
    }

    /// Recall stays live while the field still holds exactly what it produced,
    /// and stops the moment that changes.
    @Test("editing a recalled question hands the arrows back to the cursor")
    func editingReleases() {
        var h = three
        #expect(h.older(from: "") == "third")
        #expect(h.recalls("third"))
        #expect(!h.recalls("third but longer"))
        #expect(h.older(from: "third but longer") == nil)
    }

    @Test("a draft is kept and returned unchanged")
    func keepsTheDraft() {
        var h = three
        // A field holding only whitespace still counts as empty.
        #expect(h.older(from: "   ") == "third")
        #expect(h.newer(from: "third") == "   ")
    }

    @Test("asking again moves that question to the front without duplicating it")
    func remember() {
        var h = three
        h.remember("second")
        #expect(h.entries == ["second", "third", "first"])
    }

    @Test("blank questions are never remembered")
    func ignoresBlanks() {
        var h = QuestionHistory()
        h.remember("   \n ")
        #expect(h.entries.isEmpty)
        #expect(h.older(from: "") == nil)
    }

    @Test("rebuilding from a record deduplicates and keeps the newest first")
    func replace() {
        var h = QuestionHistory()
        h.replace(with: ["c", "b", "c", "", "a"])
        #expect(h.entries == ["c", "b", "a"])
    }

    @Test("an empty history leaves both arrows alone")
    func empty() {
        var h = QuestionHistory()
        #expect(h.older(from: "") == nil)
        #expect(h.newer(from: "") == nil)
    }
}
