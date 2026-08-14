import Foundation

/// What launchd says about the control plane, read without privilege.
///
/// `launchctl print system/com.dai.control` answers for an ordinary user, which
/// is the whole reason this app can be useful without asking for a password on
/// launch. It only needs one when somebody presses a button.
///
/// The distinction that matters, and that the agent's menu bar app got wrong
/// once: **not installed** is not **stopped**. A machine where nothing was ever
/// meant to run should not be described in alarming language. Three states, not
/// two.
public enum DaemonState: Equatable, Sendable {
    /// No plist in /Library/LaunchDaemons. Nothing was ever installed here.
    case notInstalled
    /// Installed, and launchd is not running it.
    case stopped
    /// Installed and running, with the pid launchd reports.
    case running(pid: Int?)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

public enum DaemonReader {
    /// Where the installer puts it. Matches `com.dai.control.plist.in`.
    public static let plistPath = "/Library/LaunchDaemons/com.dai.control.plist"
    public static let label = "com.dai.control"
    public static let target = "system/com.dai.control"

    /// Interpret what `launchctl print` wrote.
    ///
    /// Deliberately parses text rather than asking for a structured answer,
    /// because launchctl has no structured answer to give. It is tolerant: a
    /// state line that changes wording between macOS releases degrades to
    /// "running without a pid" rather than to "stopped", because reporting a
    /// live daemon as down is the failure that sends somebody to a terminal at
    /// three in the morning.
    public static func parse(printOutput: String?, plistExists: Bool) -> DaemonState {
        guard plistExists else { return .notInstalled }
        guard let out = printOutput, !out.isEmpty else { return .stopped }

        // `state = running`, or the older `state = waiting` for a job that is
        // loaded but not up. Anything else that printed at all means launchd
        // knows about it, which is more than "stopped" deserves.
        if out.contains("state = not running") { return .stopped }

        var pid: Int?
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("pid = ") else { continue }
            pid = Int(t.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces))
            break
        }
        return .running(pid: pid)
    }
}
