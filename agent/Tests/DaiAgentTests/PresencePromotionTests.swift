import Foundation
import Testing
@testable import DaiAgent

/// Promotion is slow and demotion is instant, and the difference is visible to
/// anyone watching the fleet view wondering why nothing changed.
///
/// A machine locked for five minutes still reported ACTIVE, which reads as a
/// stuck agent rather than a grace period doing its job. These pin the
/// asymmetry itself, and the fact that a single sample can never promote -
/// which is what made the `presence` command lie about a machine that was
/// already LOCKED.
struct PresencePromotionTests {
    private func locked() -> Signals {
        Signals(hidIdleSeconds: 600, screenLocked: true, consoleUser: "kim")
    }

    private func present() -> Signals {
        Signals(hidIdleSeconds: 0, screenLocked: false, consoleUser: "kim")
    }

    @Test("one sample never promotes, however idle the machine looks")
    func singleSampleCannotPromote() {
        // The bug behind a misleading diagnostic: a monitor starts at ACTIVE, so
        // any command that builds one and reads it once prints ACTIVE forever.
        let monitor = PresenceMonitor(promoteAfter: 300)
        let reading = monitor.update(locked(), now: 1000)
        #expect(reading.observed == .locked)
        #expect(reading.state == .active)
    }

    @Test("promotes once the condition has held long enough")
    func promotesAfterGracePeriod() {
        let monitor = PresenceMonitor(promoteAfter: 300)
        monitor.update(locked(), now: 1000)
        monitor.update(locked(), now: 1299)
        #expect(monitor.state == .active, "promoted a second early")
        let after = monitor.update(locked(), now: 1300)
        #expect(after.state == .locked)
    }

    @Test("a returning user is respected on the first sample")
    func demotesImmediately() {
        // The guarantee the machine's owner actually has. Anything slower here
        // is felt as the machine being slow to give itself back.
        let monitor = PresenceMonitor(promoteAfter: 300)
        monitor.update(locked(), now: 1000)
        monitor.update(locked(), now: 1400)
        #expect(monitor.state == .locked)
        #expect(monitor.update(present(), now: 1401).state == .active)
    }

    @Test("a lull restarts the clock rather than accumulating")
    func interruptionResetsTheClock() {
        // Otherwise a machine touched every four minutes would still promote,
        // load a model, and be preempted immediately - the exact waste the
        // grace period exists to prevent.
        let monitor = PresenceMonitor(promoteAfter: 300)
        monitor.update(locked(), now: 1000)
        monitor.update(present(), now: 1200)
        monitor.update(locked(), now: 1250)
        #expect(monitor.update(locked(), now: 1450).state == .active)
        #expect(monitor.update(locked(), now: 1551).state == .locked)
    }

    @Test("a machine with no GPU model is offered no GPU work")
    func lockedStillPermitsOnlyWhatItCanDo() {
        // orca, locked, with no weights staged: LOCKED permits generate, but
        // the node advertises only what it can actually run. The distinction
        // matters because the fleet view shows one and the scheduler uses the
        // other.
        #expect(permittedKinds(.locked).contains(.generate))
        #expect(permittedKinds(.active).contains(.generate) == false)
    }
}
