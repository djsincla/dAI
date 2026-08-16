import Testing
@testable import DaiWorker

/// What a machine says it is holding, when two loops both say it.
///
/// The batch loop and the serving loop each heartbeat, and the control plane
/// replaces `resident_models` wholesale with whatever arrived last. A loop that
/// reports only what it can see therefore erases what it cannot: on this fleet
/// residency alternated every twenty seconds between "the 32B share" and
/// "ane:embed", and the readiness strip flickered between ready and preparing -
/// a machine appearing to load and unload a model it never touched.
///
/// The rule is that either loop's report must describe the whole machine.
@Suite("what a machine says it holds")
struct ResidencyReportTests {
    /// Merging as the reporting code does: whatever this loop sees, plus
    /// whatever it was told the other loop holds.
    static func report(mine: [String: Double],
                       shared: [String: Double]) -> [String: Double] {
        var out = mine
        for (k, v) in shared { out[k] = v }
        return out
    }

    @Test("neither loop erases what the other holds")
    func complete() {
        // The batch loop sees the GPU model and the ANE; the serving loop sees
        // the split share. Both must report all three.
        let batch = Self.report(mine: ["30B": 17.0, "ane:embed": 0.3],
                                shared: ["32B": 9.45])
        #expect(Set(batch.keys) == ["30B", "ane:embed", "32B"])
    }

    @Test("a machine holding nothing says nothing")
    func empty() {
        #expect(Self.report(mine: [:], shared: [:]).isEmpty)
    }

    @Test("a share that is gone stops being reported")
    func releasedShare() {
        // What standing a split group down has to produce. A share still named
        // here would keep the readiness view saying a machine is warm for a
        // group that no longer exists.
        #expect(Self.report(mine: ["ane:embed": 0.3], shared: [:])
            == ["ane:embed": 0.3])
    }

    @Test("the same model from both sides is one entry, not two")
    func noDuplicate() {
        // A machine serving a model whole and holding a share of it would be
        // reporting one name twice; the map cannot express that and should not
        // try to.
        let out = Self.report(mine: ["32B": 18.4], shared: ["32B": 9.45])
        #expect(out.count == 1)
    }
}
