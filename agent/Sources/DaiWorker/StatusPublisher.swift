import DaiAgent
import Foundation

/// One writer for the status file, fed by both loops.
///
/// A node harvests and serves at once, and each loop was writing the whole file
/// from its own partial view. The batch loop writes every poll, so it won a race
/// it did not know it was in: a machine answering requests reported "waiting for
/// work" throughout, which is the same failure as the heartbeats erasing each
/// other, one layer up and visible to the person whose machine it is.
///
/// Each loop now updates only what it knows. The file is the union.
public final class StatusPublisher: @unchecked Sendable {
    /// The path is injectable so a test does not write to the file a running
    /// daemon owns, and so two tests cannot see each other's state.
    private let path: String

    public init(path: String = AgentStatus.defaultPath) {
        self.path = path
    }

    private let lock = NSLock()
    private var status = AgentStatus()

    private var batchActivity = "starting"
    private var batchKinds: [String] = []
    private var servingActivity: String?
    private var servingReady = false

    /// Serving takes precedence when it is doing something, because it is the
    /// answer to "why is this machine busy right now" - batch work yields and
    /// a conversation does not.
    private func recompute() {
        status.permitted = batchKinds + (servingReady ? ["serve"] : [])
        status.activity = servingActivity ?? batchActivity
        status.updated = Date()
        status.write(path: path)
    }

    public func updateBatch(presence: String, permitted: [String], activity: String,
                     paused: Bool, pauseReason: String?, pausedByFleet: Bool,
                     items: Int, units: Int, yields: Int, residentGb: Double) {
        lock.lock(); defer { lock.unlock() }
        status.presenceState = presence
        status.paused = paused
        status.pauseReason = pauseReason
        status.pausedByFleet = pausedByFleet
        status.itemsCompleted = items
        status.unitsCompleted = units
        status.yields = yields
        status.residentGb = max(status.residentGb, residentGb)
        batchKinds = permitted
        batchActivity = activity
        recompute()
    }

    public func updateServing(ready: Bool, activity: String?, requestsAnswered: Int,
                       residentGb: Double) {
        lock.lock(); defer { lock.unlock() }
        servingReady = ready
        servingActivity = activity
        status.requestsAnswered = requestsAnswered
        status.residentGb = residentGb
        recompute()
    }

    public func markReachable() {
        lock.lock(); defer { lock.unlock() }
        status.controlPlaneReachable = true
    }

    public func recordYield(at date: Date) {
        lock.lock(); defer { lock.unlock() }
        status.lastYield = date
    }
}
