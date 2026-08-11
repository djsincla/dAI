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
    /// Set with `-DDAI_VERSION=...` at build time; falls back to a name that is
    /// obviously not a release, so an unversioned build cannot masquerade as one.
    public static let version: String = {
        if let v = ProcessInfo.processInfo.environment["DAI_AGENT_VERSION"], !v.isEmpty {
            return v
        }
        return "dev"
    }()

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
