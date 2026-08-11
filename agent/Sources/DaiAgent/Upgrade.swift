import Foundation

/// Replacing the agent binary, and undoing it when that goes wrong.
///
/// The dangerous operation in this whole system. A bad model produces bad
/// answers; a bad binary produces a machine that does not come back, and there
/// is no way to reach it to fix that because the thing that would have listened
/// is the thing that broke. Every decision here follows from that asymmetry.
///
/// **The machine decides whether it worked, not the control plane.** A node that
/// cannot reach home after an upgrade is exactly the node the control plane
/// cannot tell to roll back. So the check runs locally, against evidence the
/// agent writes to disk, and the rollback needs nothing from the network.
///
/// **The previous binary is kept, not re-fetched.** Recovering by downloading
/// would need the network that may be the reason recovery is happening.
///
/// **Silence is failure.** If the new agent has not reported a healthy beat by
/// the deadline, it is rolled back. Waiting for a definite error would mean
/// waiting forever for the failure that matters most, which is the one where
/// nothing happens at all.
public enum Upgrade {
    /// What the updater left behind so it can finish the job after a restart.
    public struct Pending: Codable, Sendable, Equatable {
        public let toVersion: String
        public let fromVersion: String
        /// Absolute path of the binary that was replaced.
        public let rollbackPath: String
        /// When to give up waiting for a healthy beat.
        public let deadline: Date

        public init(toVersion: String, fromVersion: String,
                    rollbackPath: String, deadline: Date) {
            self.toVersion = toVersion
            self.fromVersion = fromVersion
            self.rollbackPath = rollbackPath
            self.deadline = deadline
        }
    }

    /// What the updater should do next.
    public enum Verdict: Sendable, Equatable {
        /// Healthy since the upgrade. Keep it and forget the rollback copy.
        case commit
        /// Not healthy, and out of time. Put the old binary back.
        case revert(reason: String)
        /// Still inside the window with no verdict yet.
        case wait
    }

    /// Decide, from evidence on disk, whether an upgrade took.
    ///
    /// `status` is what the running agent last published, and its two useful
    /// properties are its age and whether it could reach the control plane. An
    /// agent that starts, publishes, and cannot connect is as broken as one that
    /// never starts: it will take no work and answer no requests.
    ///
    /// Pure, and it takes `now` as an argument, because the interesting cases
    /// are all about time and none of them are reachable by waiting for real
    /// clocks in a test.
    public static func verdict(pending: Pending,
                               status: AgentStatus?,
                               now: Date,
                               healthyWithin: TimeInterval = 90) -> Verdict {
        if let status,
           status.updated > pending.deadline.addingTimeInterval(-healthyWithin),
           now.timeIntervalSince(status.updated) < healthyWithin,
           status.controlPlaneReachable {
            return .commit
        }
        guard now >= pending.deadline else { return .wait }

        if status == nil {
            return .revert(reason: "no status published after upgrade to \(pending.toVersion)")
        }
        if status?.controlPlaneReachable == false {
            return .revert(reason: "agent \(pending.toVersion) could not reach the control plane")
        }
        return .revert(reason: "agent \(pending.toVersion) stopped reporting")
    }

    /// Whether an upgrade is worth starting.
    ///
    /// Compared by hash rather than by version string. A build number is what
    /// somebody typed; the hash is what the bytes are, and the case worth
    /// catching is a machine reporting the right version with the wrong binary
    /// after a half-finished install.
    public static func needed(desiredVersion: String?, desiredSha: String?,
                              runningVersion: String, runningSha: String) -> Bool {
        guard let desiredVersion, !desiredVersion.isEmpty else { return false }
        if let desiredSha, !desiredSha.isEmpty, !runningSha.isEmpty {
            return desiredSha != runningSha
        }
        return desiredVersion != runningVersion
    }
}
