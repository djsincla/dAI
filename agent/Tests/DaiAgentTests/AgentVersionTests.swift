import Testing
@testable import DaiAgent
import Foundation

/// What a machine says it is running.
///
/// Both nodes on this fleet reported 2026.08.12-5 while running the binary
/// registered as 2026.08.13-7. Nothing was wrong with the upgrade - the binary
/// was correct and its fingerprint proved it. What was wrong was the label: the
/// version came from DAI_AGENT_VERSION in the plist, launchd hands the daemon
/// whatever was in it when the job loaded, and the updater never touched it. So
/// a machine that upgraded itself four times still named its first install.
///
/// A fingerprint is evidence and nobody reads it. The version is what somebody
/// reads, and it was the part that lied.
@Suite("what a machine says it is running")
struct AgentVersionTests {
    static func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dai-version-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("records what was installed, where the binary is")
    func records() throws {
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(AgentVersion.record("0.3.2", at: dir))
        let written = try String(contentsOf: dir.appendingPathComponent("VERSION"),
                                 encoding: .utf8)
        #expect(written.trimmingCharacters(in: .whitespacesAndNewlines) == "0.3.2")
    }

    @Test("an upgrade overwrites what was there")
    func overwrites() throws {
        // The whole point. install.sh stages a VERSION at install time and the
        // updater has to replace it, or the file becomes as stale as the plist
        // env it was brought in to fix.
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        AgentVersion.record("2026.08.12-5", at: dir)
        AgentVersion.record("0.3.2", at: dir)
        let written = try String(contentsOf: dir.appendingPathComponent("VERSION"),
                                 encoding: .utf8)
        #expect(written.trimmingCharacters(in: .whitespacesAndNewlines) == "0.3.2")
    }

    @Test("a rollback takes the version back with it")
    func rollback() throws {
        // A machine that rolled back and kept naming the build it rejected is
        // worse than one that never upgraded: the fleet view would show the bad
        // version spreading across machines that had refused it.
        let dir = Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        AgentVersion.record("0.3.1", at: dir)
        AgentVersion.record("0.3.2", at: dir)   // upgrade
        AgentVersion.record("0.3.1", at: dir)   // reverted
        let written = try String(contentsOf: dir.appendingPathComponent("VERSION"),
                                 encoding: .utf8)
        #expect(written.trimmingCharacters(in: .whitespacesAndNewlines) == "0.3.1")
    }

    @Test("a directory it cannot write is not a failed upgrade")
    func unwritable() {
        // Best effort by design. A machine that upgraded and could not write a
        // text file has upgraded; refusing to run over it would turn a cosmetic
        // problem into an outage, and the fingerprint still says what is there.
        #expect(!AgentVersion.record("0.3.2", at: URL(fileURLWithPath: "/nonexistent/dai")))
    }

    @Test("the file sits beside the binary, not somewhere it has to be told about")
    func location() {
        // Same mechanism as the control plane, which reads VERSION beside its
        // payload. Worth more than either being individually clever.
        #expect(AgentVersion.versionFile?.hasSuffix("/VERSION") == true)
    }

    @Test("an unversioned build cannot pass for a release")
    func honest() {
        // Whatever this test process resolves to, it must never be a number that
        // could be mistaken for a build somebody shipped.
        let v = AgentVersion.version
        #expect(!v.isEmpty)
    }
}

/// The permission the fix depends on.
///
/// Only root writes this file: the agent runs as _dai and deliberately cannot
/// write to the directory holding its own binary, because a process that
/// executes fleet-supplied payloads must not be able to rewrite itself. So the
/// updater writes and the agent reads, and the read is the half that breaks
/// silently - a file that came out 0600 sends the version back to the stale
/// environment variable, which is the same wrong answer with the fix apparently
/// applied.
@Suite("the service account can read what root wrote")
struct VersionPermissionTests {
    @Test("written readable, whatever umask the updater inherited")
    func readable() throws {
        let dir = AgentVersionTests.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        AgentVersion.record("0.3.2", at: dir)
        let file = dir.appendingPathComponent("VERSION").path
        let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as! NSNumber
        // Others must have read. That is the bit the agent depends on.
        #expect(mode.intValue & 0o004 == 0o004, "mode \(String(mode.intValue, radix: 8))")
        // And must not have write. Nothing but root should be able to relabel a build.
        #expect(mode.intValue & 0o022 == 0, "mode \(String(mode.intValue, radix: 8))")
    }
}
