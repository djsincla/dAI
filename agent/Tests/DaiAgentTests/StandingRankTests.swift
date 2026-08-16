import Testing
@testable import DaiAgent

/// Which share of a split this machine holds, known before anything asks.
///
/// Rank was decided per request at dispatch, which is too late to have built
/// anything: a cold gang pays the slowest machine's load before the first token
/// and pays it again whenever the group falls idle. The rank now arrives with
/// the heartbeat so the share can be ready - and the dispatch still decides,
/// because the fleet can change between the two.
@Suite("the share a machine holds before it is asked")
struct StandingRankTests {
    @Test("a rank and a size together name a share to build")
    func complete() {
        let d = ControlPlane.Directives(servingModel: "m", keepLoaded: true,
                                        machines: 2, rank: 1, size: 2)
        #expect(d.standingSplit?.rank == 1)
        #expect(d.standingSplit?.size == 2)
    }

    @Test("one without the other says nothing")
    func halfAnAnswer() {
        // Which layers this machine owns needs both. Acting on a rank with no
        // size would build a share of a pipeline whose length is unknown.
        #expect(ControlPlane.Directives(rank: 1).standingSplit == nil)
        #expect(ControlPlane.Directives(size: 2).standingSplit == nil)
    }

    @Test("a control plane too old to say means nothing to build ahead")
    func absent() {
        // The machine still serves splits; it just builds them at dispatch, as
        // it always did.
        #expect(ControlPlane.Directives().standingSplit == nil)
    }

    @Test("a size of one is not a split")
    func notSplit() {
        // One machine holding the whole model has no share to build, and
        // building one would be building the model twice.
        #expect(ControlPlane.Directives(rank: 0, size: 1).standingSplit == nil)
    }

    @Test("a rank outside the gang is refused rather than built")
    func nonsense() {
        // Rank 2 of 2 owns no layers. Building it would produce a model with an
        // empty layer range that answers from nothing.
        #expect(ControlPlane.Directives(rank: 2, size: 2).standingSplit == nil)
        #expect(ControlPlane.Directives(rank: -1, size: 2).standingSplit == nil)
    }
}
