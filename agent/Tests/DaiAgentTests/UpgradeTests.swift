import Foundation
import Testing
@testable import DaiAgent

/// Deciding whether an upgrade took, and undoing it when it did not.
///
/// The dangerous operation in this system. A bad model produces bad answers; a
/// bad binary produces a machine that does not come back, and there is no way
/// to reach it to fix that because the thing that would have listened is the
/// thing that broke.
///
/// Every test here is about the machine deciding for itself, because the node
/// that cannot reach home after an upgrade is exactly the node the control
/// plane cannot tell to roll back.
struct UpgradeTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func pending(deadlineAfter: TimeInterval = 300) -> Upgrade.Pending {
        Upgrade.Pending(toVersion: "2026.08.10-b", fromVersion: "2026.08.10-a",
                        rollbackPath: "/var/db/dai/dai-agent.rollback",
                        deadline: start.addingTimeInterval(deadlineAfter))
    }

    private func status(at: Date, reachable: Bool) -> AgentStatus {
        var s = AgentStatus(updated: at, presenceState: "LOCKED")
        s.controlPlaneReachable = reachable
        return s
    }

    @Test("commits once the new agent reports a healthy beat")
    func commitsOnHealthyBeat() {
        let p = pending()
        let v = Upgrade.verdict(pending: p,
                               status: status(at: start.addingTimeInterval(240), reachable: true),
                               now: start.addingTimeInterval(250))
        #expect(v == .commit)
    }

    @Test("waits while the window is still open")
    func waitsInsideTheWindow() {
        // Reverting early would undo an upgrade on a machine that was merely
        // slow to start, and a restart under launchd is not instant.
        let v = Upgrade.verdict(pending: pending(), status: nil,
                               now: start.addingTimeInterval(60))
        #expect(v == .wait)
    }

    @Test("reverts when nothing was ever published")
    func revertsOnSilence() {
        // Silence is the failure that matters most: a binary that does not
        // start produces no error anywhere, and waiting for a definite one
        // means waiting forever.
        let v = Upgrade.verdict(pending: pending(), status: nil,
                               now: start.addingTimeInterval(301))
        guard case let .revert(reason) = v else { Issue.record("expected revert"); return }
        #expect(reason.contains("no status"))
    }

    @Test("reverts an agent that runs but cannot reach the control plane")
    func revertsUnreachable() {
        // As broken as one that never starts: it will take no work and answer
        // no requests, and it will sit there looking alive to anybody local.
        let v = Upgrade.verdict(pending: pending(),
                               status: status(at: start.addingTimeInterval(290), reachable: false),
                               now: start.addingTimeInterval(301))
        guard case let .revert(reason) = v else { Issue.record("expected revert"); return }
        #expect(reason.contains("could not reach"))
    }

    @Test("reverts an agent that reported once and then stopped")
    func revertsOnStaleStatus() {
        // A crash loop publishes one healthy beat and dies. Judging on the last
        // status ever seen rather than a recent one would call that a success.
        let v = Upgrade.verdict(pending: pending(),
                               status: status(at: start.addingTimeInterval(5), reachable: true),
                               now: start.addingTimeInterval(301))
        guard case .revert = v else { Issue.record("expected revert"); return }
    }

    @Test("does not accept a status written before the upgrade began")
    func ignoresStatusFromTheOldAgent() {
        // The file is written by whichever agent is running, and the previous
        // one left its own. Trusting it would commit every upgrade instantly,
        // including the ones that never started.
        let p = pending()
        let v = Upgrade.verdict(pending: p,
                               status: status(at: start.addingTimeInterval(-60), reachable: true),
                               now: start.addingTimeInterval(10))
        #expect(v == .wait)
    }
}

struct UpgradeNeededTests {
    @Test("compares by hash when both are known")
    func comparesByHash() {
        // A build number is what somebody typed; the hash is what the bytes
        // are. The case worth catching is a machine reporting the right version
        // with the wrong binary after a half-finished install.
        #expect(Upgrade.needed(desiredVersion: "v2", desiredSha: "aaa",
                               runningVersion: "v2", runningSha: "bbb"))
        #expect(!Upgrade.needed(desiredVersion: "v2", desiredSha: "aaa",
                                runningVersion: "v1", runningSha: "aaa"))
    }

    @Test("falls back to the version when no hash is available")
    func fallsBackToVersion() {
        #expect(Upgrade.needed(desiredVersion: "v2", desiredSha: nil,
                               runningVersion: "v1", runningSha: ""))
        #expect(!Upgrade.needed(desiredVersion: "v1", desiredSha: nil,
                                runningVersion: "v1", runningSha: ""))
    }

    @Test("does nothing when nobody is managing this machine")
    func doesNothingWhenUnmanaged() {
        // An external pool means an MDM or a person owns the binary. A node
        // told nothing must do nothing, or two systems end up fighting over one
        // executable.
        #expect(!Upgrade.needed(desiredVersion: nil, desiredSha: nil,
                                runningVersion: "v1", runningSha: "aaa"))
        #expect(!Upgrade.needed(desiredVersion: "", desiredSha: nil,
                                runningVersion: "v1", runningSha: "aaa"))
    }
}
