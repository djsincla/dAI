import AppKit
import DaiControlStatusCore
import SwiftUI

/// The control plane's status app: whether it is up, what it is, and the buttons
/// to start and stop it.
///
/// It exists because "is the control plane running" needed ssh and a guess at
/// which directory the daemon was started from. The agent has had a menu bar app
/// since the beginning; the one machine an operator actually attends to had
/// nothing.
///
/// **It does not own the daemon.** launchd starts the control plane, with
/// KeepAlive, and keeps starting it. If this app started it too there would be
/// two owners of one process and a race the first time both acted. The buttons
/// here ask launchd, which stays the only thing that runs it - the difference
/// between an operator's remote control and a supervisor.
///
/// This is a status window, not the console. The fleet - nodes, groups, models,
/// work - is the browser UI and stays there, because that has to reach an
/// operator who is not sitting at this machine and on a platform nobody
/// specified in advance.
///
/// Not in main.swift: `@main` and top-level code cannot coexist, and SwiftPM's
/// debug build tolerates what a Release build rejects outright - which the
/// agent's menu bar app learned the expensive way.
@main
struct DaiControlStatusApp: App {
    @StateObject private var model = ControlModel()

    var body: some Scene {
        MenuBarExtra {
            Contents(model: model)
        } label: {
            Image(systemName: model.diagnosis.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class ControlModel: ObservableObject {
    @Published private(set) var diagnosis: Diagnosis = .notInstalled
    @Published private(set) var daemon: DaemonState = .notInstalled
    @Published private(set) var fleet: Fleet?
    /// Why the fleet is unknown, when it is. A monitoring surface that refuses
    /// loopback is configuration, not a fault, and must not read as an empty
    /// fleet - which would say every machine is gone.
    @Published private(set) var fleetNote: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var busy = false

    let port: Int
    private var timer: Timer?
    /// When an action last ran, so a control plane that is still binding its
    /// sockets is described as starting rather than as broken.
    private var actedAt: Date?

    init() {
        port = Self.configuredPort()
        refresh()
        // Two seconds, matching the agent's app. Everything polled here is local
        // except one loopback request, so the cost is noise.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The port out of the installed plist, rather than a constant.
    ///
    /// Reading the file is all that happens here; deciding what it means lives
    /// in the core, where it is tested against a plist that does not have to be
    /// installed on the machine running the tests.
    private static func configuredPort() -> Int {
        InstalledPlist.port(from: FileManager.default.contents(atPath: DaemonReader.plistPath))
    }

    func refresh() {
        let plistExists = FileManager.default.fileExists(atPath: DaemonReader.plistPath)
        let printed = Shell.run("/bin/launchctl", ["print", DaemonReader.target])
        daemon = DaemonReader.parse(printOutput: printed, plistExists: plistExists)
        log = Log.tail(lines: 12)

        let grace = actedAt.map { Date().timeIntervalSince($0) < 8 } ?? false
        guard daemon.isRunning else {
            diagnosis = Diagnosis.of(daemon: daemon, health: nil, port: port, startedWithin: grace)
            fleet = nil
            return
        }

        Task { [port] in
            let health = await Probe.health(port: port)
            let (f, note) = await Probe.fleet(port: port)
            await MainActor.run {
                self.diagnosis = Diagnosis.of(daemon: self.daemon, health: health,
                                              port: port, startedWithin: grace)
                self.fleet = f
                self.fleetNote = note
            }
        }
    }

    /// Ask the system to do it, and say plainly if it refused.
    ///
    /// A failure here is nearly always the operator cancelling the password
    /// panel, which is not an error worth an alert - so it refreshes and lets
    /// the state speak for itself.
    func perform(_ action: DaemonAction) {
        if action.needsConfirmation && !Confirm.stop() { return }
        busy = true
        Task.detached {
            let failure = Privileged.run(action)
            await MainActor.run {
                self.busy = false
                self.actedAt = Date()
                if let failure { Alert.show(action, failure) }
                self.refresh()
            }
        }
    }
}

struct Contents: View {
    @ObservedObject var model: ControlModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: model.diagnosis.symbolName)
                Text("Control plane").font(.headline)
            }
            Text(model.diagnosis.message)
                .font(.callout)
                .foregroundStyle(model.diagnosis.isGood ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let fleet = model.fleet {
                Divider()
                Text("\(fleet.nodes) machines, \(fleet.working) working")
                    .font(.callout).monospacedDigit()
            } else if let note = model.fleetNote {
                Divider()
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.log.isEmpty {
                Divider()
                Text("Recent log").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(model.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 120)
            }

            Divider()
            HStack {
                ForEach(DaemonAction.allCases, id: \.self) { action in
                    Button(action.title) { model.perform(action) }
                        .disabled(model.busy || !action.isAvailable(given: model.daemon))
                }
            }
            Button("Open console") {
                if let url = URL(string: "https://localhost:\(model.port)/ui/") {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(!model.diagnosis.isGood)

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 330)
    }
}
