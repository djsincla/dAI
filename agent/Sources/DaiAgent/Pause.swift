import Foundation

/// The pause switch belonging to the person at the machine.
///
/// This is the one control that must never be overridable. The isolation this
/// product relies on is policy rather than hardware - unified memory means the
/// agent and the artist's work share the same silicon and the same bandwidth -
/// so the only hard guarantee a machine's owner has is that the off switch
/// works. An agent that can be told to keep running is not a tenant, it is
/// malware in the user's mental model, and the first person who notices their
/// machine is slow and cannot stop it will end the programme.
///
/// So the mechanism is deliberately dumb, and local:
///
/// **A file, not a request.** Pausing works with the control plane unreachable,
/// the network down, or the daemon wedged. Anything requiring a round trip
/// fails exactly when someone is most annoyed.
///
/// **Under `/Users/Shared`, which is world-writable on every Mac.** The daemon
/// runs as a service account and the person pausing is a different user
/// entirely, so the file has to sit somewhere both can reach without either
/// needing privilege. Requiring `sudo` to stop a background process on your own
/// machine is the same as not having the button.
///
/// **The control plane is told, and cannot untell it.** The state is reported on
/// every heartbeat so the fleet view is honest about what is actually
/// available, but nothing on the server writes back.
public struct PauseSwitch: Sendable {
    public static let defaultPath = "/Users/Shared/.dai-paused"

    private let url: URL

    /// Exposed so a test can point at a file of its own rather than toggling
    /// the switch on the machine running it.
    public var path: String { url.path }

    public init(path: String = PauseSwitch.defaultPath) {
        self.url = URL(fileURLWithPath: path)
    }

    public struct State: Sendable, Equatable {
        public let paused: Bool
        public let since: Date?
        public let reason: String?
    }

    /// Reading is a `stat` in the common case, which matters because this is
    /// checked on the same cadence as presence.
    public func read() -> State {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return State(paused: false, since: nil, reason: nil)
        }
        let since = attributes[.creationDate] as? Date
        let reason = (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return State(paused: true, since: since,
                     reason: (reason?.isEmpty ?? true) ? nil : reason)
    }

    /// Pause, optionally saying why.
    ///
    /// World-writable on purpose. Anyone who can sit at this machine can stop
    /// work on it, and that is the intent rather than an oversight: narrowing it
    /// to the file's creator would mean a second user at the same machine could
    /// not stop something they can feel.
    public func pause(reason: String? = nil) throws {
        let body = (reason ?? "paused by the machine owner") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o666],
                                               ofItemAtPath: url.path)
    }

    public func resume() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
