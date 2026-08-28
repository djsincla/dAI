import Testing
@testable import NotebookKit

/// The trim cadence.
///
/// **This is the only part of the memory fix a test can reach.** MLX will not
/// run under `swift test`, so whether `clearCache` frees anything is measured by
/// `notebook-ingest` on hardware and not here. What is checkable is the
/// arithmetic that decides when to call it, which is worth checking because
/// getting it wrong is silent in both directions: never trimming looks exactly
/// like the bug it fixes, and trimming every batch looks like the model got
/// slower for no reason.
@Suite("Ingest trim cadence")
struct IngestTrimTests {

    @Test("trims on the interval and not between")
    func onTheInterval() {
        #expect(Ingest.shouldTrim(afterFlushes: 32, every: 32))
        #expect(Ingest.shouldTrim(afterFlushes: 64, every: 32))
        #expect(!Ingest.shouldTrim(afterFlushes: 31, every: 32))
        #expect(!Ingest.shouldTrim(afterFlushes: 33, every: 32))
    }

    /// Zero flushes is the state before any work, and trimming there would
    /// clear the cache the model load just filled.
    @Test("does not trim before anything has been embedded")
    func notAtZero() {
        #expect(!Ingest.shouldTrim(afterFlushes: 0, every: 32))
    }

    /// An interval of zero would be a division by zero with `%`, and a caller
    /// that wanted trimming switched off would get a crash instead.
    @Test("an interval of zero switches trimming off rather than crashing")
    func zeroInterval() {
        #expect(!Ingest.shouldTrim(afterFlushes: 10, every: 0))
        #expect(!Ingest.shouldTrim(afterFlushes: 0, every: 0))
    }

    /// The shipped cadence, asserted so that changing it is a decision.
    ///
    /// At 16 chunks a batch this is every 512 chunks, which on the VCF import
    /// is about ten seconds.
    @Test("the default interval is every 32 batches")
    func defaultInterval() {
        #expect(Ingest.trimEvery == 32)
        #expect(Ingest.shouldTrim(afterFlushes: Ingest.trimEvery))
    }
}

/// The reopening cadence for paged documents.
///
/// Same reasoning as the trim cadence: the effect is only measurable on
/// hardware, so what a test can hold is the arithmetic. Worth holding, because
/// both ways of getting it wrong are quiet - never reopening restores a 3.3 GB
/// read, and reopening every page turns a forty second read into an hour of
/// parsing xref tables.
@Suite("Document reopening cadence")
struct DocumentReopenTests {

    @Test("reopens on the interval and not between")
    func onTheInterval() {
        #expect(DocumentReader.shouldReopen(atPage: 512, every: 512))
        #expect(DocumentReader.shouldReopen(atPage: 1024, every: 512))
        #expect(!DocumentReader.shouldReopen(atPage: 511, every: 512))
        #expect(!DocumentReader.shouldReopen(atPage: 513, every: 512))
    }

    /// Page zero is where the document was just opened. Reopening there would
    /// parse the file twice before reading a single page.
    @Test("never reopens at the first page")
    func notAtTheStart() {
        #expect(!DocumentReader.shouldReopen(atPage: 0, every: 512))
    }

    @Test("an interval of zero switches reopening off rather than crashing")
    func zeroInterval() {
        #expect(!DocumentReader.shouldReopen(atPage: 100, every: 0))
    }

    /// The shipped cadence, asserted so changing it is a decision. Measured at
    /// 192 MB flat across the 8,894 page manual, against 3,363 MB without it.
    @Test("the default interval is every 512 pages")
    func defaultInterval() {
        #expect(DocumentReader.reopenEvery == 512)
        #expect(DocumentReader.shouldReopen(atPage: DocumentReader.reopenEvery,
                                            every: DocumentReader.reopenEvery))
    }
}
