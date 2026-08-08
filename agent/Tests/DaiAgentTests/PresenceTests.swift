import Testing
@testable import DaiAgent

/// Ported from the Python agent's suite, which is the specification for this
/// rewrite. Every case corresponds to a bug that actually shipped and had to be
/// found by running the system, and all of them reproduce from a signal struct
/// with no hardware involved.
///
/// The Python failure mode was consistent: six separate measurements were wrong
/// in the *flattering* direction. These are written to fail closed.

// MARK: - Classification

@Test func recentInputIsActive() {
    #expect(classify(Signals(hidIdleSeconds: 5)) == .active)
}

@Test func lockedScreenBeatsIdleTime() {
    #expect(classify(Signals(hidIdleSeconds: 1, screenLocked: true)) == .locked)
}

@Test func noConsoleUserIsAbsent() {
    #expect(classify(Signals(consoleUser: nil)) == .absent)
}

/// A missing signal must never read as "nobody is here". Guessing absent
/// degrades a machine someone is using, which is the one-strike failure;
/// guessing active only costs throughput.
@Test func unreadableIdleSignalFailsClosedToActive() {
    #expect(classify(Signals(hidIdleSeconds: nil)) == .active)
}

// MARK: - Sleep assertions: the bug that shipped twice

/// A video call holds PreventUserIdleDisplaySleep and emits no HID events.
/// Without PASSIVE the agent would resume work mid-call.
@Test func displayAssertionMeansAHumanIsWatching() {
    #expect(classify(Signals(displayAssertions: ["zoom.us: Zoom Meeting"])) == .passive)
}

/// Regression for the sharingd/Handoff bug: treating system-sleep assertions as
/// presence pinned the machine in PASSIVE permanently and it never harvested.
@Test func systemSleepAssertionsDoNotImplyPresence() {
    #expect(classify(Signals(busyAssertions: ["sharingd: Handoff", "coreaudiod: ..."])) == .idle)
}

/// Regression for the same bug one layer down: a single `caffeinate` assertion
/// was gating GPU work off entirely. Safari, coreaudiod and downloads hold these
/// permanently, so gating on them blocks harvesting on any normal machine.
@Test func systemSleepAssertionsDoNotBlockWork() {
    let s = Signals(screenLocked: true, busyAssertions: ["caffeinate: caffeinate command-line tool"])
    let p = effectivePolicy(classify(s), s)
    #expect(p.gpu)
    #expect(p.dutyMax == 1)
    #expect(p.blockedBy.isEmpty)
}

// MARK: - Policy

/// E2 measured every GPU setting as perceptible, including the gentlest
/// (background QoS at 25% duty, +46% of viewport p95).
@Test(arguments: [PresenceState.active, .passive, .idle])
func gpuIsForbiddenWheneverAUserIsLoggedIn(state: PresenceState) {
    let p = effectivePolicy(state, Signals())
    #expect(!p.gpu)
    #expect(p.dutyMax == 0)
}

/// E5 measured ANE work as indistinguishable from no load. It is the only thing
/// a logged-in machine may do, across three of five states.
@Test(arguments: PresenceState.allCases)
func aneIsPermittedInEveryState(state: PresenceState) {
    #expect(effectivePolicy(state, Signals()).ane)
}

/// E1 measured background QoS at ~2.4x on sustained work, and the harvest worker
/// at ~26x on bursty work. Leaving it pinned to background wastes most of the
/// overnight window.
@Test(arguments: [PresenceState.locked, .absent])
func gpuRunsAtFullDutyAndStandardQoSWhenUnobserved(state: PresenceState) {
    let p = effectivePolicy(state, Signals())
    #expect(p.gpu)
    #expect(p.dutyMax == 1)
    #expect(p.qos == .standard)
}

@Test func batteryBlocksAllWork() {
    let s = Signals(consoleUser: nil, onACPower: false)
    let p = effectivePolicy(classify(s), s)
    #expect(!p.gpu && !p.ane)
    #expect(p.memFrac == 0)
    #expect(p.blockedBy.contains("on battery"))
}

@Test func thermalPressureBlocksGPU() {
    let s = Signals(consoleUser: nil, thermalOK: false)
    let p = effectivePolicy(classify(s), s)
    #expect(!p.gpu)
    #expect(p.blockedBy.contains("thermal pressure"))
}

/// `memFrac` is not a politeness dial: E2 measured a 32 GB load disturbing a
/// viewport *less* than an 8 GB one at identical duty. So any state permitting
/// GPU work must also carry a duty limit.
@Test func memoryCeilingIsNeverTheOnlyThrottle() {
    for state in PresenceState.allCases {
        let p = effectivePolicy(state, Signals())
        if p.gpu { #expect(p.dutyMax > 0, "\(state) allows GPU with no duty limit") }
    }
}

/// A single request has no seam to yield at, so its length is bounded by state.
@Test func completionCapTightensWhenSomeoneMightBeWatching() {
    #expect(defaultPolicy[.locked]!.maxCompletionTokens < defaultPolicy[.absent]!.maxCompletionTokens)
    #expect(defaultPolicy[.idle]!.maxCompletionTokens <= defaultPolicy[.locked]!.maxCompletionTokens)
}

@Test func permittedKindsMatchTheTable() {
    for s in [PresenceState.active, .passive, .idle] {
        #expect(permittedKinds(s) == [.embed])
    }
    for s in [PresenceState.locked, .absent] {
        #expect(permittedKinds(s).contains(.generate))
        #expect(permittedKinds(s).contains(.render))
    }
}

// MARK: - Hysteresis, asymmetric by design

@Test func demotionTowardActiveIsImmediate() {
    let m = PresenceMonitor(promoteAfter: 300)
    m.update(Signals(hidIdleSeconds: 600, screenLocked: true), now: 0)
    m.update(Signals(hidIdleSeconds: 600, screenLocked: true), now: 400)
    #expect(m.state == .locked)
    // A returning user must be respected on the very first sample.
    let r = m.update(Signals(hidIdleSeconds: 1, screenLocked: false), now: 401)
    #expect(r.state == .active)
}

@Test func promotionRequiresTheConditionToHold() {
    let m = PresenceMonitor(promoteAfter: 300)
    let idle = Signals(hidIdleSeconds: 600)
    m.update(Signals(hidIdleSeconds: 1), now: 0)
    #expect(m.state == .active)

    // The timer starts at the first sample showing the new condition (t=10),
    // not when the previous state was entered, so the deadline is 310.
    #expect(m.update(idle, now: 10).state == .active)
    #expect(m.update(idle, now: 309).state == .active)
    #expect(m.update(idle, now: 310).state == .idle)
}

/// Otherwise a user tapping the trackpad every few minutes would still see the
/// machine promote to a permissive state.
@Test func aBriefReturnResetsThePromotionTimer() {
    let m = PresenceMonitor(promoteAfter: 300)
    let idle = Signals(hidIdleSeconds: 600)
    m.update(Signals(hidIdleSeconds: 1), now: 0)
    m.update(idle, now: 200)                      // would promote at 500
    m.update(Signals(hidIdleSeconds: 1), now: 250) // user touches the machine
    #expect(m.state == .active)
    #expect(m.update(idle, now: 400).state == .active)
    #expect(m.update(idle, now: 699).state == .active)
    #expect(m.update(idle, now: 700).state == .idle)
}

/// Property: across any signal sequence, a sample with recent input must never
/// leave the worker permitted to run GPU work.
@Test(arguments: [
    [1.0, 600.0, 1.0, 600.0, 1.0],
    [600.0, 1.0, 600.0, 600.0, 1.0],
    [1.0, 1.0, 600.0, 1.0, 600.0],
])
func neverPermitsGPUWhileInputIsRecent(sequence: [Double]) {
    let m = PresenceMonitor(promoteAfter: 1)
    for (i, idle) in sequence.enumerated() {
        let r = m.update(Signals(hidIdleSeconds: idle), now: Double(i) * 10)
        if idle < activeIdleThreshold {
            #expect(!r.policy.gpu, "GPU permitted at idle=\(idle)s in state \(r.state)")
        }
    }
}

@Test func pollsFastWhenAUserCouldReturn() {
    let m = PresenceMonitor(promoteAfter: 1)
    m.update(Signals(hidIdleSeconds: 1), now: 0)
    #expect(m.pollInterval == pollIntervalActive)
    // Promotion needs the condition observed once and then held: the first
    // sample only starts the timer.
    m.update(Signals(hidIdleSeconds: 600, screenLocked: true), now: 10)
    #expect(m.pollInterval == pollIntervalActive)
    m.update(Signals(hidIdleSeconds: 600, screenLocked: true), now: 12)
    // Nobody can see the screen, so there is nothing to interrupt quickly.
    #expect(m.state == .locked)
    #expect(m.pollInterval == pollIntervalIdle)
}
