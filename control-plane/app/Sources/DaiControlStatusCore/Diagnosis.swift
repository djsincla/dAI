import Foundation

/// What the window says, in one line, from the two things it knows.
///
/// The pair is what carries the meaning. launchd says whether a process exists;
/// /healthz says whether it serves. Neither alone distinguishes the cases an
/// operator actually needs to tell apart, and reporting only one of them is how
/// a database outage gets diagnosed as a crashed daemon and fixed by restarting
/// something that was never broken.
public enum Diagnosis: Equatable, Sendable {
    case notInstalled
    case stopped
    /// Running, and answering. The ordinary case.
    case serving(surface: String, version: String)
    /// Running, and not answering yet. Startup takes a moment.
    case starting
    /// Running, and answering that it is not well - which nearly always means
    /// the database.
    case unhealthy
    /// Running, and unreachable at its own port.
    case notAnswering(port: Int)

    public var isGood: Bool {
        if case .serving = self { return true }
        return false
    }

    public static func of(daemon: DaemonState, health: Health?,
                          port: Int, startedWithin grace: Bool) -> Diagnosis {
        switch daemon {
        case .notInstalled: return .notInstalled
        case .stopped: return .stopped
        case .running:
            guard let health else {
                // A daemon launchd started a moment ago has not finished binding
                // its sockets, and calling that "not answering" would make every
                // restart look like a failure for the two seconds it takes.
                return grace ? .starting : .notAnswering(port: port)
            }
            return health.ok
                ? .serving(surface: health.surface, version: health.versionDescription)
                : .unhealthy
        }
    }

    /// The sentence a person reads, and what to do about it.
    ///
    /// Errors say what happened and what would fix it. "Unhealthy" on its own
    /// sends somebody to a log; naming Postgres sends them to the thing that is
    /// usually wrong.
    public var message: String {
        switch self {
        case .notInstalled:
            return "No control plane is installed on this machine."
        case .stopped:
            return "Installed and not running. Start it below."
        case .serving(let surface, let version):
            return "Serving on the \(surface) surface, version \(version)."
        case .starting:
            return "Started, and not answering yet."
        case .unhealthy:
            return "Running, and reporting a fault - usually Postgres. Check the log."
        case .notAnswering(let port):
            return "Running, and not answering on port \(port). Check the log."
        }
    }

    /// The icon carries the state at a glance, because most of the time nobody
    /// opens the window.
    public var symbolName: String {
        switch self {
        case .serving:      return "shippingbox.fill"
        case .starting:     return "shippingbox"
        case .notInstalled: return "shippingbox"
        case .stopped:      return "shippingbox.circle"
        case .unhealthy, .notAnswering: return "exclamationmark.triangle.fill"
        }
    }
}
