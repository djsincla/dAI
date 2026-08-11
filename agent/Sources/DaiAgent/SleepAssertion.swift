import Foundation
import IOKit.pwr_mgt

/// Keeping a machine reachable while it is lending its capacity.
///
/// A workstation that sleeps when locked contributes nothing during exactly the
/// hours this product is made of. orca demonstrated it: repeated four to seven
/// minute blackouts overnight, ssh timing out, heartbeats stopping, while ICMP
/// kept answering because the Bonjour sleep proxy replies on a sleeping Mac's
/// behalf. It looked alive and was not.
///
/// Three properties, and each is a promise to the person whose machine it is:
///
/// **Idle sleep only.** `PreventUserIdleSystemSleep` stops the machine dropping
/// off the network; it does not touch display sleep. The screen still goes dark
/// on the same schedule, the machine still sleeps when its lid closes, and a
/// person pressing the power button is not argued with.
///
/// **Nothing global is changed.** No `pmset`, no configuration profile, nothing
/// left behind. The assertion lives and dies with the process, so a crashed or
/// killed agent releases it without anyone having to remember.
///
/// **It is visible.** The name below is what `pmset -g assertions` prints, and
/// somebody wondering why their Mac is not sleeping deserves to find an answer
/// that names the culprit rather than a bare process id.
public final class SleepAssertion: @unchecked Sendable {
    /// What `pmset -g assertions` will show. Written for the person who goes
    /// looking, not for a log.
    public static let defaultName = "dAI: keeping this machine available for shared compute"

    private let name: String
    private let lock = NSLock()
    private var id: IOPMAssertionID = 0
    private var held = false
    private var acquired = 0

    public init(name: String = SleepAssertion.defaultName) {
        self.name = name
    }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return held
    }

    /// How many times the assertion has actually been taken.
    ///
    /// Exposed because "is it held now" cannot tell a loop that held it
    /// correctly and let go from one that never held it at all, and both end
    /// with the same answer. It also makes a leak visible: this should count
    /// transitions, not polls.
    public var acquisitions: Int {
        lock.lock(); defer { lock.unlock() }
        return acquired
    }

    /// Hold or release, idempotently.
    ///
    /// Called on every pass of the work loop, so it has to be cheap and safe to
    /// call with the value it already has: creating a second assertion each time
    /// would leak one per poll and leave the machine pinned awake long after the
    /// agent stopped wanting it.
    @discardableResult
    public func set(_ wanted: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if wanted == held { return held }
        return wanted ? acquireLocked() : releaseLocked()
    }

    private func acquireLocked() -> Bool {
        var newId: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &newId)
        guard result == kIOReturnSuccess else { return false }
        id = newId
        held = true
        acquired += 1
        return true
    }

    @discardableResult
    private func releaseLocked() -> Bool {
        if id != 0 { IOPMAssertionRelease(id) }
        id = 0
        held = false
        return false
    }

    deinit {
        if id != 0 { IOPMAssertionRelease(id) }
    }
}

/// Whether this machine should be kept awake right now.
///
/// Separated from the mechanism so the rule can be tested without holding a
/// real assertion, and because the rule is the part with judgement in it.
public enum SleepPolicy {
    /// The conditions, all of which must hold.
    ///
    /// **On AC power.** Keeping a laptop awake on battery to do somebody else's
    /// work is indefensible, and this is the gate the plan always specified.
    ///
    /// **Not paused, by anyone.** The off switch has to stop everything the
    /// agent does to a machine, not merely the work. A paused agent that went on
    /// preventing sleep would be exactly the overreach the pause exists to rule
    /// out.
    ///
    /// **AC state known.** Unknown reads as battery. A machine whose power state
    /// cannot be determined is the wrong one to gamble on.
    public static func shouldStayAwake(onACPower: Bool?,
                                       userPaused: Bool,
                                       pausedByFleet: Bool) -> Bool {
        if userPaused || pausedByFleet { return false }
        return onACPower == true
    }
}
