import Foundation

/// What `/healthz` answers, and what it means when it does not.
///
/// A daemon that launchd calls running is not the same as a control plane that
/// works. It can be up and unable to reach Postgres, or up and still binding
/// its sockets. launchd answers "is the process there"; this answers "is it
/// serving", and an operator needs both to tell a crash from a database that
/// went away.
public struct Health: Equatable, Sendable {
    public let ok: Bool
    /// `agent`, `serving` or `both` - which surfaces this process is answering
    /// on, which is set by configuration and is the first thing to check when a
    /// request is refused by a control plane that is plainly up.
    public let surface: String
    /// The packaged version, or "dev" from a working tree. Absent on a control
    /// plane older than the release that started reporting it, which is itself
    /// the answer to "is this machine behind".
    public let version: String?

    public init(ok: Bool, surface: String, version: String?) {
        self.ok = ok
        self.surface = surface
        self.version = version
    }

    /// Tolerant of a body it does not recognise.
    ///
    /// A control plane predating the version field must still parse, or the app
    /// would report the machine most in need of upgrading as unreachable.
    public static func parse(_ data: Data) -> Health? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = obj["ok"] as? Bool
        else { return nil }
        return Health(ok: ok,
                      surface: obj["surface"] as? String ?? "unknown",
                      version: obj["version"] as? String)
    }

    /// How the version should read in the window.
    ///
    /// "dev" is not dressed up as a version. A control plane deployed from a
    /// checkout is a thing an operator should notice rather than a number they
    /// should compare, and an older one that cannot say is described as what it
    /// is rather than as blank space.
    public var versionDescription: String {
        switch version {
        case .none: return "before 0.3.2 (does not report)"
        case .some("dev"): return "dev - deployed from a working tree"
        case .some(let v): return v
        }
    }
}
