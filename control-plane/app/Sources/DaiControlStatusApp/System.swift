import AppKit
import DaiControlStatusCore
import Foundation

/// Running things, reading things, and asking the operator for a password.
///
/// Separated from the window because none of it is about layout, and separated
/// from the core because all of it touches the machine - which is what the core
/// deliberately does not do, so that the core can be tested.

enum Shell {
    /// Run something and return what it wrote, or nil if it failed.
    ///
    /// Unprivileged only. `launchctl print` answers for an ordinary user, which
    /// is why this app can be useful without asking for anything on launch: it
    /// needs a password when somebody presses a button, and not before.
    static func run(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        // Read before waiting: a pipe that fills while nobody is draining it
        // blocks the child forever, and launchctl print is verbose enough to
        // matter on a busy machine.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum Log {
    static let path = "/var/log/dai-control/control.log"
    static let errorPath = "/var/log/dai-control/control.err.log"

    /// The last few lines of both logs, newest last.
    ///
    /// Both, because launchd splits them and the interesting half is usually
    /// stderr - a control plane that cannot reach Postgres says so there and
    /// says nothing at all on stdout.
    static func tail(lines: Int) -> [String] {
        let all = [path, errorPath].flatMap { read($0, lines: lines) }
        return Array(all.suffix(lines))
    }

    private static func read(_ path: String, lines: Int) -> [String] {
        // World-readable, as the installer leaves them, so this needs no
        // privilege. If that ever changes the app shows nothing rather than
        // prompting for a password to read a log.
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").map(String.init).suffix(lines))
    }
}

enum Probe {
    /// The control plane's own certificate is issued by a private authority, and
    /// this is a request to localhost from the machine that holds it. Verifying
    /// it would mean teaching the app where the CA lives and failing whenever
    /// somebody moved it - to check the identity of a process this app can see
    /// the pid of.
    ///
    /// This is the one place that is acceptable. It is loopback, it is a
    /// liveness check, and nothing it reads is trusted for anything more than a
    /// sentence in a window.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config, delegate: LoopbackTrust(), delegateQueue: nil)
    }()

    static func health(port: Int) async -> Health? {
        guard let url = URL(string: "https://localhost:\(port)/healthz"),
              let (data, _) = try? await session.data(from: url)
        else { return nil }
        return Health.parse(data)
    }

    /// The fleet, or the reason there isn't one to show.
    static func fleet(port: Int) async -> (Fleet?, String?) {
        guard let url = URL(string: "https://localhost:\(port)/monitor/v1/metrics"),
              let (data, response) = try? await session.data(from: url)
        else { return (nil, nil) }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 || code == 404 {
            // Loopback is not in the monitoring range by default, so an app on
            // the control plane's own machine gets refused by an endpoint six
            // inches away. Say which setting, because "forbidden" sends people
            // looking for a permission that does not exist.
            return (nil, "Fleet numbers need 127.0.0.1 in the monitoring range (DAI_MONITOR_CIDRS).")
        }
        guard code == 200, let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
        return (Fleet.parse(text), nil)
    }
}

/// Accepts the control plane's certificate on loopback, and nothing else.
private final class LoopbackTrust: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "localhost",
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

enum Privileged {
    /// Hand the command to macOS, which collects the password itself.
    ///
    /// The app never sees a credential: the authentication panel belongs to the
    /// system, and this process learns only whether the command ran. That is the
    /// whole reason to go through osascript rather than asking for a password in
    /// a window of our own - a password field in an app's own window is the
    /// shape of every credential-phishing dialog ever written, and teaching
    /// operators to type a root password into one is a bad habit to install.
    ///
    /// Returns nil on success, or what went wrong.
    static func run(_ action: DaemonAction) -> String? {
        let command = action.command()
        // Escaped for AppleScript's string literal, which is the only place this
        // is interpolated. The command itself is a constant from DaemonAction -
        // nothing here is composed from anything a user or a server typed.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = action.authorizationPrompt.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"

        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard let error else { return nil }
        // -128 is the operator cancelling the panel, which is not a failure.
        if (error["NSAppleScriptErrorNumber"] as? Int) == -128 { return nil }
        return error["NSAppleScriptErrorMessage"] as? String ?? "the command did not run"
    }
}

enum Confirm {
    /// Stopping the control plane stops the fleet.
    ///
    /// Every agent loses its lease renewal and no work is handed out until it
    /// comes back. That is worth a sentence beforehand, where restarting - which
    /// returns on its own - is not.
    @MainActor static func stop() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop the control plane?"
        alert.informativeText = """
        Every machine in the fleet stops receiving work until it is started \
        again. Agents keep their identities and reconnect on their own.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum Alert {
    @MainActor static func show(_ action: DaemonAction, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = "Could not \(action.rawValue) the control plane"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
