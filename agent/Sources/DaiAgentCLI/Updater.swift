import CryptoKit
import DaiAgent
import Foundation

/// The privileged half of deployment: replacing the agent binary, and undoing
/// it when the replacement does not come back.
///
/// Runs as root from its own launchd job rather than inside the agent, because
/// the agent runs as a service account that cannot write to the directory its
/// own binary lives in - and giving it that ability would mean a process which
/// executes fleet-supplied payloads could rewrite itself.
///
/// It is deliberately small and deliberately dumb. Everything it decides is a
/// pure function tested elsewhere; this file only moves files and restarts a
/// daemon, which is the part that cannot be undone by a later commit.
enum Updater {
    static let markerPath = "/var/db/dai/pending-upgrade.json"
    static let rollbackPath = "/var/db/dai/dai-agent.rollback"

    /// One pass. Safe to run on a timer and safe to run twice.
    static func run(controlPlane: URL, binaryPath: String, waitSeconds: TimeInterval) async {
        let dir = Enroll.identityDir()
        guard let identity = try? NodeIdentity.load(
                certificate: dir.appendingPathComponent("node.crt"),
                enclaveKey: Enroll.keyPath(dir)),
              let ca = try? String(contentsOf: dir.appendingPathComponent("ca.crt"),
                                   encoding: .utf8),
              let cp = try? ControlPlane(base: controlPlane, identity: identity,
                                         serverCAPEM: ca) else {
            print("updater: not enrolled; nothing to do")
            return
        }
        // An upgrade in flight is finished before another is considered. Two
        // rollbacks racing would restore each other's binaries.
        if let pending = readPending() {
            await settle(pending, cp: cp, binaryPath: binaryPath)
        } else {
            await considerUpgrade(cp: cp, binaryPath: binaryPath, waitSeconds: waitSeconds)
        }
        await cp.shutdown()
    }

    // MARK: - Deciding

    private static func considerUpgrade(cp: ControlPlane, binaryPath: String,
                                        waitSeconds: TimeInterval) async {
        guard let desired = try? await cp.desiredBuild() else {
            print("updater: could not ask what to run")
            return
        }
        guard let version = desired.version else {
            // Nobody is managing this machine. An MDM or a person owns the
            // binary, and doing anything here would be two systems fighting
            // over one executable.
            print("updater: unmanaged, leaving the binary alone")
            return
        }
        let runningSha = sha256OfFile(binaryPath)
        guard Upgrade.needed(desiredVersion: version, desiredSha: desired.sha256,
                             runningVersion: AgentVersion.version, runningSha: runningSha) else {
            print("updater: already running \(version)")
            return
        }

        print("updater: upgrading to \(version)")
        try? await cp.reportUpgrade(fromVersion: AgentVersion.version, toVersion: version,
                                    state: "started", detail: nil)
        do {
            try await install(cp: cp, version: version, expectedSha: desired.sha256,
                              binaryPath: binaryPath, waitSeconds: waitSeconds)
        } catch {
            print("updater: upgrade failed before restart: \(error)")
            try? await cp.reportUpgrade(fromVersion: AgentVersion.version, toVersion: version,
                                        state: "failed", detail: String(describing: error))
        }
    }

    /// Fetch, verify, keep the old one, swap, restart.
    private static func install(cp: ControlPlane, version: String, expectedSha: String?,
                                binaryPath: String, waitSeconds: TimeInterval) async throws {
        let staged = URL(fileURLWithPath: binaryPath + ".incoming")
        let got = try await cp.downloadAgentBuild(version: version, to: staged)
        guard expectedSha == nil || got == expectedSha else {
            try? FileManager.default.removeItem(at: staged)
            throw Failure.hashMismatch(expected: expectedSha ?? "", got: got)
        }

        let fm = FileManager.default
        // The running binary is kept rather than re-fetchable. Recovering by
        // downloading would need the network that may be the reason recovery is
        // happening at all.
        try? fm.removeItem(atPath: rollbackPath)
        try fm.copyItem(atPath: binaryPath, toPath: rollbackPath)

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        // Renamed rather than written over: a half-copied binary must never be
        // reachable under the name launchd will execute.
        _ = try fm.replaceItemAt(URL(fileURLWithPath: binaryPath), withItemAt: staged)

        writePending(Upgrade.Pending(
            toVersion: version, fromVersion: AgentVersion.version,
            rollbackPath: rollbackPath,
            deadline: Date().addingTimeInterval(waitSeconds)))

        reloadAgent()
    }

    /// Finish an upgrade that is already in flight.
    private static func settle(_ pending: Upgrade.Pending, cp: ControlPlane,
                               binaryPath: String) async {
        let status = AgentStatus.read()
        switch Upgrade.verdict(pending: pending, status: status, now: Date()) {
        case .wait:
            print("updater: waiting for \(pending.toVersion) to report in")

        case .commit:
            print("updater: \(pending.toVersion) is healthy")
            clearPending()
            try? FileManager.default.removeItem(atPath: pending.rollbackPath)
            try? await cp.reportUpgrade(fromVersion: pending.fromVersion,
                                        toVersion: pending.toVersion,
                                        state: "committed", detail: nil)

        case let .revert(reason):
            print("updater: rolling back to \(pending.fromVersion): \(reason)")
            let fm = FileManager.default
            if fm.fileExists(atPath: pending.rollbackPath) {
                _ = try? fm.replaceItemAt(URL(fileURLWithPath: binaryPath),
                                          withItemAt: URL(fileURLWithPath: pending.rollbackPath))
            }
            clearPending()
            reloadAgent()
            // Reported after the rollback, and best effort: the control plane
            // being unreachable is a likely reason we are here at all, and the
            // machine has already saved itself either way.
            try? await cp.reportUpgrade(fromVersion: pending.fromVersion,
                                        toVersion: pending.toVersion,
                                        state: "reverted", detail: reason)
        }
    }

    /// Hash of the binary on disk, which is what a node is actually running.
    ///
    /// Read from the file rather than from `AgentVersion.fingerprint`, because
    /// this process may be a different build from the daemon: the updater runs
    /// from its own copy and the question is what the daemon will execute.
    static func sha256OfFile(_ path: String) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Mechanics

    private static func reloadAgent() {
        // Through launchd, so the daemon comes back under the same job with the
        // same environment. Killing the process would work and would lose every
        // setting the plist carries.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "system/com.dai.agent"]
        try? p.run()
        p.waitUntilExit()
    }

    static func readPending() -> Upgrade.Pending? {
        guard let data = FileManager.default.contents(atPath: markerPath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Upgrade.Pending.self, from: data)
    }

    static func writePending(_ p: Upgrade.Pending) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(p) else { return }
        FileManager.default.createFile(atPath: markerPath, contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }

    static func clearPending() {
        try? FileManager.default.removeItem(atPath: markerPath)
    }

    enum Failure: Error, CustomStringConvertible {
        case hashMismatch(expected: String, got: String)
        var description: String {
            switch self {
            case let .hashMismatch(expected, got):
                return "binary hash \(got.prefix(12)) does not match \(expected.prefix(12))"
            }
        }
    }
}
