import Foundation

/// User-presence detection: the harvest agent's primary control.
///
/// E2 showed contention lands in the tail. A 25 GB background load moved median
/// frame time 3% but p99 82%, and that damage only matters while a human is
/// watching. At 2am it is irrelevant. So the agent does not try to be
/// simultaneously fast and invisible; it detects presence and switches modes.
/// Memory ceiling and QoS are secondary dials applied *within* a mode.
///
/// Everything here is pure. Signal collection lives behind ``SignalSource`` so
/// tests inject fixtures: every policy bug found in the Python agent reproduced
/// from a recorded signal dictionary alone, with no hardware involved, and that
/// property is worth protecting.

public enum PresenceState: String, Sendable, CaseIterable, Comparable {
    /// Ordered least to most permissive. Promotion needs hysteresis; demotion is
    /// immediate.
    case active = "ACTIVE"
    case passive = "PASSIVE"
    case idle = "IDLE"
    case locked = "LOCKED"
    case absent = "ABSENT"

    var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: PresenceState, b: PresenceState) -> Bool { a.rank < b.rank }
}

public enum WorkKind: String, Sendable, CaseIterable {
    case embed, generate, render

    /// `embed` runs on the ANE. The other two are GPU work and are confined to
    /// states where nobody is at the machine.
    public var isGPU: Bool { self != .embed }
}

public enum QoS: String, Sendable { case background, standard }

public struct StatePolicy: Sendable, Equatable {
    public var gpu: Bool
    public var ane: Bool
    public var qos: QoS
    public var dutyMax: Double
    public var memFrac: Double
    /// Largest completion this state permits, in tokens.
    ///
    /// Batch work yields between items and hands back the remainder. A single
    /// interactive request has no such seam, so bounding its length bounds how
    /// long a returning user waits for their machine back.
    public var maxCompletionTokens: Int
    public var blockedBy: [String] = []
}

/// Seconds of no HID input before the machine stops counting as actively used.
public let activeIdleThreshold: TimeInterval = 90

/// Sustained idle required before adopting a more permissive state. Long on
/// purpose: E4 showed a false "they are gone" costs a model load and an
/// immediate preemption.
public let idlePromoteSeconds: TimeInterval = 300

/// How often to sample. E4 measured memory release at ~20ms and model reload at
/// 1-3s, which makes this interval the dominant term in end-to-end yield
/// latency. Sampling is cheap, so poll fast; tune this rather than the release
/// path.
public let pollIntervalActive: TimeInterval = 0.5
public let pollIntervalIdle: TimeInterval = 5.0

/// What the agent may do in each state. These are E2 and E5 measurements, not
/// estimates, and the control plane serves the same table.
///
/// GPU work is forbidden wherever a user is logged in: E2 swept QoS against duty
/// cycle and found every configuration perceptible, the gentlest tested
/// (background QoS at 25% duty) still costing 46% of viewport p95.
///
/// ANE work is permitted everywhere. E5 measured a saturating ANE workload as
/// indistinguishable from no load, which makes it the only daytime option and
/// the only thing three of five states allow at all.
///
/// `memFrac` is **not** a politeness dial. E2 measured a 32 GB load disturbing a
/// viewport less than an 8 GB one at identical duty. Footprint governs what
/// fits; occupancy governs disturbance.
public let defaultPolicy: [PresenceState: StatePolicy] = [
    .active:  StatePolicy(gpu: false, ane: true, qos: .background, dutyMax: 0, memFrac: 0, maxCompletionTokens: 256),
    .passive: StatePolicy(gpu: false, ane: true, qos: .background, dutyMax: 0, memFrac: 0.15, maxCompletionTokens: 256),
    .idle:    StatePolicy(gpu: false, ane: true, qos: .background, dutyMax: 0, memFrac: 0.35, maxCompletionTokens: 256),
    .locked:  StatePolicy(gpu: true, ane: true, qos: .standard, dutyMax: 1, memFrac: 0.70, maxCompletionTokens: 2048),
    .absent:  StatePolicy(gpu: true, ane: true, qos: .standard, dutyMax: 1, memFrac: 0.85, maxCompletionTokens: 4096),
]

public struct Signals: Sendable, Equatable {
    /// Seconds since the last keyboard, mouse or trackpad event. `nil` when the
    /// signal could not be read at all.
    public var hidIdleSeconds: TimeInterval?
    public var screenLocked: Bool?
    public var consoleUser: String?
    public var onACPower: Bool
    /// Something insists the *display* stay on: a call, playback, a
    /// presentation. Strong evidence a human is looking at the screen.
    public var displayAssertions: [String]
    /// Something insists the *machine* keep running. Renders hold this, but so
    /// do a dozen background daemons, so it implies the machine is busy rather
    /// than that anyone is present.
    public var busyAssertions: [String]
    public var thermalOK: Bool

    public init(hidIdleSeconds: TimeInterval? = 600, screenLocked: Bool? = false,
                consoleUser: String? = "user", onACPower: Bool = true,
                displayAssertions: [String] = [], busyAssertions: [String] = [],
                thermalOK: Bool = true) {
        self.hidIdleSeconds = hidIdleSeconds
        self.screenLocked = screenLocked
        self.consoleUser = consoleUser
        self.onACPower = onACPower
        self.displayAssertions = displayAssertions
        self.busyAssertions = busyAssertions
        self.thermalOK = thermalOK
    }
}

/// Map raw signals to a presence state.
///
/// Order matters: the most restrictive interpretation that fits wins. A missing
/// signal is treated as "user present", because the failure mode of guessing
/// absent is degrading someone's machine, and that ends the programme.
public func classify(_ s: Signals) -> PresenceState {
    if s.consoleUser == nil { return .absent }
    if s.screenLocked == true { return .locked }
    guard let idle = s.hidIdleSeconds else { return .active }  // cannot tell: assume the worst
    if idle < activeIdleThreshold { return .active }
    // Present but not typing. Someone on a call or watching playback produces no
    // HID events for many minutes while being entirely there, which is why this
    // is a distinct state rather than folded into idle.
    if !s.displayAssertions.isEmpty { return .passive }
    return .idle
}

/// Apply hard gates that override the state's policy entirely.
public func effectivePolicy(_ state: PresenceState, _ s: Signals) -> StatePolicy {
    var p = defaultPolicy[state]!
    var reasons: [String] = []

    if !s.onACPower {
        // The gate that would have saved a laptop which drained its battery
        // running a worker with no presence logic at all.
        p.gpu = false; p.ane = false; p.dutyMax = 0; p.memFrac = 0
        reasons.append("on battery")
    }
    if !s.thermalOK {
        p.gpu = false; p.dutyMax = 0; p.memFrac = 0
        reasons.append("thermal pressure")
    }

    // `busyAssertions` is deliberately NOT a gate. PreventUserIdleSystemSleep
    // means only "do not sleep": Safari, coreaudiod, downloads and caffeinate
    // hold it more or less permanently, so gating on it blocked harvesting
    // entirely on a normally-used machine. It is surfaced for observability and
    // nothing else.

    p.blockedBy = reasons
    return p
}

/// Work kinds this state permits. The control plane applies the same rule, and
/// the stricter of the two wins.
public func permittedKinds(_ state: PresenceState, policy: StatePolicy? = nil) -> [WorkKind] {
    let p = policy ?? defaultPolicy[state]!
    var kinds: [WorkKind] = []
    if p.ane { kinds.append(.embed) }
    if p.gpu && p.dutyMax > 0 { kinds.append(contentsOf: [.generate, .render]) }
    return kinds
}

/// Applies hysteresis so the agent does not flap between states.
///
/// Demotion toward `.active` is immediate: a returning user must be respected on
/// the very first sample. Promotion requires the condition to hold for
/// `promoteAfter`, because a momentary lull should not trigger an expensive
/// model load that is about to be thrown away. The asymmetry is the design, not
/// a refinement.
public final class PresenceMonitor {
    public private(set) var state: PresenceState = .active
    private var candidate: PresenceState?
    private var candidateSince: TimeInterval = 0
    private let promoteAfter: TimeInterval

    public init(promoteAfter: TimeInterval = idlePromoteSeconds) {
        self.promoteAfter = promoteAfter
    }

    public struct Reading: Sendable {
        public let state: PresenceState
        public let observed: PresenceState
        public let policy: StatePolicy
        public let signals: Signals
    }

    @discardableResult
    public func update(_ signals: Signals, now: TimeInterval) -> Reading {
        let observed = classify(signals)

        if observed <= state {
            state = observed          // more restrictive, or unchanged: apply now
            candidate = nil
        } else if observed != candidate {
            candidate = observed
            candidateSince = now
        } else if now - candidateSince >= promoteAfter {
            state = observed
            candidate = nil
        }

        return Reading(state: state, observed: observed,
                       policy: effectivePolicy(state, signals), signals: signals)
    }

    /// Sample fast when a user could plausibly be about to return; slowly when
    /// nobody can see the screen.
    public var pollInterval: TimeInterval {
        (state == .locked || state == .absent) ? pollIntervalIdle : pollIntervalActive
    }
}
