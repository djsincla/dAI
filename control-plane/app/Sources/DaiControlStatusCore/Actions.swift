import Foundation

/// The three things this app can ask the system to do, as data.
///
/// Data rather than code so the exact command is testable. A privileged action
/// composed inline is one that gets read once, at review, and never again - and
/// these run as root on the machine the whole fleet depends on.
///
/// Root is unavoidable: the control plane is a system daemon and stopping one is
/// privileged. The app never handles a password. It hands the command to
/// `osascript ... with administrator privileges` and macOS puts up its own
/// authentication panel, so the credential goes from the operator to the system
/// and this process only ever learns whether it worked.
public enum DaemonAction: String, CaseIterable, Sendable {
    case start
    case stop
    case restart

    public var title: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .restart: return "Restart"
        }
    }

    /// Whether this action makes sense right now, so the window can disable what
    /// would only produce an error.
    public func isAvailable(given state: DaemonState) -> Bool {
        switch (self, state) {
        case (_, .notInstalled): return false
        case (.start, .stopped): return true
        case (.stop, .running), (.restart, .running): return true
        default: return false
        }
    }

    /// Restart goes through the installed reload-daemon.sh rather than issuing
    /// bootout and bootstrap directly.
    ///
    /// That script is the one that knows `launchctl bootout` returns before the
    /// job is gone, and that bootstrapping into a label which still exists fails
    /// with `5: Input/output error`. It cost a failed install to learn once. An
    /// app that reimplemented the pair would relearn it on somebody else's
    /// machine.
    public func command(binaryDir: String = "/usr/local/libexec/dai-control") -> String {
        switch self {
        case .start:
            return "launchctl bootstrap system \(DaemonReader.plistPath)"
        case .stop:
            return "launchctl bootout \(DaemonReader.target)"
        case .restart:
            return "\(binaryDir)/reload-daemon.sh system \(DaemonReader.label) \(DaemonReader.plistPath)"
        }
    }

    /// What the authentication panel tells the operator they are approving.
    ///
    /// macOS shows this verbatim. "dai-control-status wants to make changes" is
    /// what an unexplained prompt looks like, and an unexplained prompt is one
    /// people learn to approve without reading.
    public var authorizationPrompt: String {
        switch self {
        case .start: return "dAI needs your password to start the control plane."
        case .stop: return "dAI needs your password to stop the control plane."
        case .restart: return "dAI needs your password to restart the control plane."
        }
    }

    /// Whether pressing this should ask twice.
    ///
    /// Stopping the control plane stops the fleet: every agent loses its lease
    /// renewal and no work is handed out until it returns. That is worth a
    /// sentence before it happens, where restarting - which comes back on its
    /// own - is not.
    public var needsConfirmation: Bool { self == .stop }
}
