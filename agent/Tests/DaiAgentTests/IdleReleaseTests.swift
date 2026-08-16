import Testing
@testable import DaiAgent
@testable import DaiWorker
import Foundation

/// When a machine lets go of a model because nothing is being asked of it.
///
/// The presence policy already answered "somebody wants their machine back".
/// Nothing answered "nobody wants anything", so a harvest machine that served
/// one request at nine in the morning held gigabytes until its owner returned -
/// memory belonging to a person nobody was asking anything of.
///
/// A pure function, so the rule is testable without a GPU and without waiting
/// five minutes for a clock.
@Suite("letting go when nothing is being asked")
struct IdleReleaseTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let window: TimeInterval = 300

    @Test("releases once the window has passed")
    func past() {
        #expect(Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: now.addingTimeInterval(-301), now: now, window: window))
    }

    @Test("holds while a conversation is still going")
    func within() {
        // The half a short window would break. An agentic client resends the
        // whole conversation every turn, seconds apart, and unloading between
        // turns destroys the prompt cache - which once turned a 0.5s warm
        // request into 37.5s.
        #expect(!Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: now.addingTimeInterval(-30), now: now, window: window))
        #expect(!Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: now.addingTimeInterval(-299), now: now, window: window))
    }

    @Test("the boundary releases rather than holding one more tick")
    func exactly() {
        #expect(Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: now.addingTimeInterval(-300), now: now, window: window))
    }

    @Test("no window means never, which is what a dedicated group gets")
    func noWindow() {
        // And what every machine did before this existed, so a control plane
        // too old to send one changes nothing.
        #expect(!Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: now.addingTimeInterval(-100_000), now: now, window: nil))
    }

    @Test("never while a request is being answered")
    func whileServing() {
        // The bug this guard exists for. The window is decided from when the
        // last request *ended*, which is stale for the whole of the one running
        // now - so a request longer than the window would be judged idle and
        // have its model unloaded the instant it finished, taking the prompt
        // cache with it. There is a measured example: 19,243 tokens took 377
        // seconds against a 300 second default.
        #expect(!Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: now.addingTimeInterval(-100_000), now: now,
            window: window, serving: 1))
        // And with several in flight, which is the ordinary case on a machine
        // answering more than one caller.
        #expect(!Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: now.addingTimeInterval(-100_000), now: now,
            window: window, serving: 3))
    }

    @Test("releases once the last of them finishes")
    func afterServing() {
        // The counter reaching zero is what makes the machine idle; the clock
        // then decides whether it has been idle long enough.
        #expect(Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: now.addingTimeInterval(-301), now: now,
            window: window, serving: 0))
    }

    @Test("a machine that has served nothing has nothing to release")
    func neverServed() {
        // Whatever it holds was not put there by serving, so this rule is not
        // the one that should take it away.
        #expect(!Worker.shouldReleaseWhenIdle(
            lastRequestEndedAt: nil, now: now, window: window))
    }
}

/// The window as it arrives from the control plane.
@Suite("how long to hold, as the group decided")
struct IdleWindowDirectiveTests {
    @Test("a control plane too old to say means no window")
    func absent() {
        #expect(ControlPlane.Directives().idleUnloadSeconds == nil)
    }

    @Test("carries what the group set")
    func carries() {
        #expect(ControlPlane.Directives(idleUnloadSeconds: 600).idleUnloadSeconds == 600)
    }

    @Test("a nonsense window is clamped, not believed")
    func clamped() {
        // Zero would mean releasing between the turns of one conversation,
        // which is the behaviour that cost 37 seconds a request.
        #expect(ControlPlane.Directives(idleUnloadSeconds: 0).idleUnloadSeconds == 1)
        #expect(ControlPlane.Directives(idleUnloadSeconds: -5).idleUnloadSeconds == 1)
    }
}
