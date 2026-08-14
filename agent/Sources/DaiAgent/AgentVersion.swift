import CryptoKit
import Foundation

/// What this binary is, so a fleet can be told apart from itself.
///
/// Until this existed there was no way to know what any machine was running.
/// Two deploys in one day left both nodes on a build from hours earlier, and the
/// only way to find out was to compare file sizes over ssh and guess - which is
/// exactly the sort of thing an operator should never have to do, and exactly
/// the sort of mistake that hides for a day.
///
/// Two identifiers, because they answer different questions:
///
/// **`version`** is what a person says out loud, set at build time. It is what
/// an operator picks in a list and what a release is named after.
///
/// **`fingerprint`** is the hash of the running executable, computed at start.
/// It cannot be forged by a stale build number and it is what proves that the
/// binary on disk is the one the control plane believes it deployed. A version
/// string is a claim; this is evidence.
public enum AgentVersion {
    /// What this build is called, from the file beside the binary.
    ///
    /// The file first and the environment second, because the environment lies
    /// after a self-update. `DAI_AGENT_VERSION` is written into the plist by
    /// install.sh and launchd hands the daemon whatever was in it when the job
    /// was loaded - so a machine that upgraded itself four times reported the
    /// version it was originally installed with. Both nodes on this fleet
    /// reported 2026.08.12-5 while running the binary from 2026.08.13-7, and
    /// only the fingerprint gave it away.
    ///
    /// The file is written by whoever last put a binary here: the installer
    /// stages it, and the updater rewrites it after a successful upgrade. That
    /// makes it the same mechanism the control plane uses, which is worth more
    /// than either being individually clever.
    ///
    /// Falls back to a name that is obviously not a release, so an unversioned
    /// build cannot masquerade as one.
    public static let version: String = {
        if let path = versionFile,
           let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        if let v = ProcessInfo.processInfo.environment["DAI_AGENT_VERSION"], !v.isEmpty {
            return v
        }
        return "dev"
    }()

    /// `VERSION`, beside the executable. Nil when there is no executable path to
    /// work from, which is the test and REPL case rather than a deployment.
    static var versionFile: String? {
        guard let binary = Bundle.main.executablePath ?? CommandLine.arguments.first
        else { return nil }
        return URL(fileURLWithPath: binary).deletingLastPathComponent()
            .appendingPathComponent("VERSION").path
    }

    /// Record what is now installed here, called by the updater once the new
    /// binary is in place.
    ///
    /// Best effort and deliberately quiet: a machine that upgraded successfully
    /// and could not write a text file has upgraded successfully. Reporting a
    /// stale version is a smaller problem than refusing to run, and the
    /// fingerprint still says what is actually there.
    @discardableResult
    public static func record(_ version: String, at directory: URL) -> Bool {
        let file = directory.appendingPathComponent("VERSION")
        guard (try? Data((version + "\n").utf8).write(to: file, options: .atomic)) != nil
        else { return false }

        // Readable by the service account, explicitly rather than by whatever
        // umask the updater inherited. Only root writes this - the agent runs as
        // _dai and deliberately cannot write to the directory its own binary
        // lives in, because a process that executes fleet-supplied payloads must
        // not be able to rewrite itself. But it has to *read* it, and a file
        // that came out 0600 would send the version quietly back to the stale
        // environment variable this exists to replace: the same wrong answer,
        // with the fix apparently applied.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: file.path)
        return true
    }

    /// sha256 of the executable this process is running from.
    ///
    /// Computed once, lazily, and tolerant of failure: a node that cannot hash
    /// itself should still report in rather than drop off the fleet over a
    /// diagnostic. An empty answer says "unknown", which is honest, where a
    /// fabricated one would be worse than nothing.
    public static let fingerprint: String = {
        guard let path = Bundle.main.executablePath ?? CommandLine.arguments.first,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return "" }
        defer { try? handle.close() }

        var hasher = SHA256()
        // Streamed rather than read whole: the binary is around 48MB and this
        // runs on somebody's workstation at startup.
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }()

    /// Short form for logs and tables.
    public static var short: String {
        fingerprint.isEmpty ? version : "\(version) (\(fingerprint.prefix(12)))"
    }
}
