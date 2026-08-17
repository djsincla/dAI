import Testing
import Foundation
@testable import DaiAgent
@testable import DaiWorker

/// What a heartbeat tells this machine to do about its share of a split model.
///
/// This was one guard covering three cases, and two of them meant opposite
/// things. A group serving whichever model it was staged with names no model and
/// no standing split, so the guard read it as "nothing stands here any more" and
/// released the share - the one built moments earlier to answer a request, let
/// go on the next heartbeat and rebuilt for the request after that. Around
/// forty seconds of rebuild, every time, for a group whose whole purpose is to
/// hold what it loaded.
///
/// The protocol already said which reading was right. `servingModel` documents
/// that nil means nobody has said, "which is not the same as serve nothing: a
/// group that has not been given a model is not an instruction to unload one",
/// and `Worker.directive` honours it on the whole-model path. This is the split
/// path being made to agree with the contract it was already carrying.
@Suite("what to do with this machine's share")
struct ShareDirectiveTests {
    typealias Directives = ControlPlane.Directives
    typealias Share = ReverseChannel.ShareDirective

    @Test("a machine no group claims lets its share go")
    func nothingClaimsIt() {
        // keepLoaded false is the only thing a node ever learns about its
        // membership. False means the group was stood down or this machine was
        // handed back, and the memory belongs to whoever is sitting at it.
        #expect(ReverseChannel.shareDirective(Directives(keepLoaded: false)) == .release)
    }

    @Test("still released when a model is named but nothing claims the machine")
    func namedButUnclaimed() {
        // A harvest group can name a model. It cannot hold a split share, and
        // the naming must not be read as a claim on one.
        let d = Directives(servingModel: "qwen-32b", keepLoaded: false, rank: 0, size: 2)
        #expect(ReverseChannel.shareDirective(d) == .release)
    }

    @Test("a claimed machine with nothing named holds what it built")
    func dynamicGroupHolds() {
        // The bug. A group serving whichever staged model is asked for sends
        // keepLoaded with no model and no seat, because there is nothing to
        // warm before a caller chooses. That is not an instruction to unload.
        #expect(ReverseChannel.shareDirective(Directives(keepLoaded: true)) == .holdWhatIsHeld)
    }

    @Test("a named model with no seat is not a split to warm")
    func namedWithoutASeat() {
        // A cluster group serving a model that fits one machine. There is a
        // model and a claim but no pipeline, so there is no share to build -
        // and equally no share to throw away.
        let d = Directives(servingModel: "qwen-30b", keepLoaded: true)
        #expect(ReverseChannel.shareDirective(d) == .holdWhatIsHeld)
    }

    @Test("a standing split is warmed before anything asks for it")
    func warmsAStandingSplit() {
        let d = Directives(servingModel: "qwen-32b", keepLoaded: true, rank: 1, size: 2)
        #expect(ReverseChannel.shareDirective(d) == .warm(model: "qwen-32b", rank: 1, size: 2))
    }

    @Test("only release says release")
    func releaseIsNarrow() {
        // The property that matters, stated on its own: of every shape a
        // heartbeat can take, exactly one throws away a built share. A machine
        // that is claimed keeps what it has, whatever else is or is not named.
        let claimed = [
            Directives(keepLoaded: true),
            Directives(servingModel: "a", keepLoaded: true),
            Directives(servingModel: "a", keepLoaded: true, rank: 0, size: 2),
            Directives(keepLoaded: true, idleUnloadSeconds: 300),
        ]
        for d in claimed {
            #expect(ReverseChannel.shareDirective(d) != .release)
        }
    }

    @Test("an out-of-range seat is not treated as a split")
    func nonsenseSeat() {
        // standingSplit already refuses these; asserted here because the
        // difference between "no seat" and "a seat that cannot be right" used
        // to fall through the same guard to a release.
        for (rank, size) in [(0, 1), (2, 2), (-1, 2)] {
            let d = Directives(servingModel: "m", keepLoaded: true, rank: rank, size: size)
            #expect(ReverseChannel.shareDirective(d) == .holdWhatIsHeld,
                    "rank \(rank) of \(size) should not be warmed as a split")
        }
    }
}

/// The idle window, and which of the two things a machine can be holding it
/// applies to.
///
/// The decision was already right and already tested. What was missing is that
/// the release only ever unloaded the whole-model runtime and never the split
/// share - harmless while the only groups with a window were harvest groups,
/// which hold no share, and wrong the moment a cluster group gets one.
@Suite("idleness applies to whatever is held")
struct IdleReleaseScopeTests {
    @Test("a group with no window never releases")
    func noWindow() {
        // A group pinned to a model is dedicated and holds its share for as
        // long as it stands.
        #expect(Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: Date(timeIntervalSinceNow: -86_400),
            now: Date(), window: nil, serving: 0) == false)
    }

    @Test("never while a request is in flight")
    func notWhileServing() {
        // The 377-second prompt against a 300-second window: lastRequestEndedAt
        // does not move until the request ends, so a long split would have
        // unloaded the model it was serving from at the moment it finished.
        #expect(Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: Date(timeIntervalSinceNow: -600),
            now: Date(), window: 300, serving: 1) == false)
    }

    @Test("releases once the window has passed with nothing in flight")
    func releasesWhenIdle() {
        #expect(Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: Date(timeIntervalSinceNow: -600),
            now: Date(), window: 300, serving: 0) == true)
        #expect(Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: Date(timeIntervalSinceNow: -60),
            now: Date(), window: 300, serving: 0) == false)
    }
}
