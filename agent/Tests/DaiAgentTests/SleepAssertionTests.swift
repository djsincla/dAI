import Foundation
import Testing
@testable import DaiAgent

/// Keeping a machine reachable, and knowing when not to.
///
/// orca proved the need: repeated four to seven minute blackouts overnight,
/// heartbeats stopping, ssh timing out, while ICMP kept answering because a
/// sleep proxy replies on a sleeping Mac's behalf. A harvest node that sleeps
/// when locked contributes nothing during exactly the hours this product is
/// made of.
///
/// The rule matters more than the mechanism, because it is the part that
/// decides how much of somebody else's machine this software takes.
struct SleepPolicyTests {
    @Test("stays awake on mains power when nobody has paused it")
    func awakeOnAC() {
        #expect(SleepPolicy.shouldStayAwake(onACPower: true, userPaused: false,
                                            pausedByFleet: false))
    }

    @Test("lets a machine on battery sleep")
    func sleepsOnBattery() {
        // Keeping a laptop awake on battery to do somebody else's work is
        // indefensible, and this is the gate the plan always specified.
        #expect(!SleepPolicy.shouldStayAwake(onACPower: false, userPaused: false,
                                             pausedByFleet: false))
    }

    @Test("treats an unknown power state as battery")
    func unknownACSleeps() {
        // A machine whose power state cannot be read is the wrong one to gamble
        // on, and the gamble is somebody else's battery.
        #expect(!SleepPolicy.shouldStayAwake(onACPower: nil, userPaused: false,
                                             pausedByFleet: false))
    }

    @Test("releases the machine the moment its owner pauses")
    func ownerPauseWins() {
        // The off switch has to stop everything this software does to a machine,
        // not merely the work it runs. A paused agent still preventing sleep is
        // precisely the overreach the pause exists to rule out.
        #expect(!SleepPolicy.shouldStayAwake(onACPower: true, userPaused: true,
                                             pausedByFleet: false))
    }

    @Test("releases when the fleet has paused the node")
    func fleetPauseAlsoWins() {
        #expect(!SleepPolicy.shouldStayAwake(onACPower: true, userPaused: false,
                                             pausedByFleet: true))
    }
}

/// The assertion itself, against real IOKit.
///
/// Worth exercising for real rather than behind a protocol: the failure mode
/// that matters is leaking one assertion per poll, which no fake would
/// reproduce and which would pin a machine awake long after the agent stopped
/// wanting it.
struct SleepAssertionTests {
    @Test("holds and releases")
    func holdsAndReleases() {
        let a = SleepAssertion(name: "dAI test assertion")
        #expect(!a.isHeld)
        a.set(true)
        #expect(a.isHeld)
        a.set(false)
        #expect(!a.isHeld)
    }

    @Test("setting the value it already has changes nothing")
    func idempotent() {
        // Called on every pass of the work loop. Creating a fresh assertion each
        // time would leak one per poll, and releasing the last id would leave
        // all the others held forever.
        let a = SleepAssertion(name: "dAI test assertion")
        a.set(true)
        a.set(true)
        a.set(true)
        #expect(a.isHeld)
        #expect(a.acquisitions == 1, "leaked \(a.acquisitions) assertions")
        a.set(false)
        #expect(!a.isHeld)
    }

    @Test("releasing when it was never held is safe")
    func releaseWithoutHold() {
        let a = SleepAssertion(name: "dAI test assertion")
        a.set(false)
        #expect(!a.isHeld)
    }

    @Test("is named so somebody can find out what is keeping their Mac awake")
    func hasAHumanName() {
        // This string is what `pmset -g assertions` prints. A person wondering
        // why their machine will not sleep deserves an answer that names the
        // culprit rather than a bare process id.
        #expect(SleepAssertion.defaultName.contains("dAI"))
        #expect(SleepAssertion.defaultName.count > 20)
    }
}
