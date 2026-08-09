import AppKit
import DaiAgent
import SwiftUI

/// The menu bar app: what is running on your machine, and the button to stop it.
///
/// Three things, and the plan called all three non-optional even on a fleet you
/// own outright.
///
/// **A pause button that always works.** No admin override, no round trip, no
/// privilege. It writes a file the daemon watches, so it works with the control
/// plane unreachable.
///
/// **An activity log.** Without one, every unrelated slowdown on the machine
/// gets blamed on this. With one, people can check.
///
/// **A contribution counter.** Cheap to build, and it does most of the political
/// work: it reframes "IT took my machine" as "I contribute to the farm".
///
/// It runs as a LaunchAgent in the user's session, separately from the daemon,
/// and shares nothing with it but two files under `/Users/Shared`. That
/// separation is the point: this process has no privilege and can only ask.
@main
struct DaiMenuBarApp: App {
    @StateObject private var model = StatusModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContents(model: model)
        } label: {
            // The icon carries the state at a glance, because most people will
            // never open the menu. A paused machine has to look different from a
            // working one without being alarming about it.
            Image(systemName: model.symbolName)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var status: AgentStatus?
    @Published private(set) var paused = false

    private let pauseSwitch = PauseSwitch()
    private var timer: Timer?

    init() {
        refresh()
        // Two seconds: fast enough that pausing feels immediate, slow enough to
        // be free. The daemon republishes far more often than this.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        status = AgentStatus.read()
        paused = pauseSwitch.read().paused
    }

    func togglePause() {
        // Written locally and taking effect on the next poll, rather than asking
        // anything. A pause that depends on a server is a pause that fails when
        // the network is down, which is not a property anyone wants from a
        // button labelled stop.
        try? paused ? pauseSwitch.resume() : pauseSwitch.pause(reason: "paused from the menu bar")
        refresh()
    }

    var symbolName: String {
        if paused { return "pause.circle" }
        guard let status, status.isFresh else { return "circle.dashed" }
        return status.activity.hasPrefix("running") ? "bolt.fill" : "bolt"
    }

    /// Deliberately plain language. The audience is someone whose machine feels
    /// slow, not an operator.
    var headline: String {
        if paused { return "Paused by you" }
        guard let status else { return "Not running" }
        guard status.isFresh else { return "Not responding" }
        if status.permitted.isEmpty { return "Standing by" }
        if status.activity.hasPrefix("running") { return "Working" }
        return "Waiting for work"
    }

    var detail: String {
        if paused { return "Nothing will run here until you resume." }
        guard let status else {
            return "The agent is not installed or has not started."
        }
        guard status.isFresh else {
            return "No update since \(Self.relative(status.updated)). It may have stopped."
        }
        if status.permitted.isEmpty {
            return "You are using this machine, so nothing is running."
        }
        if status.permitted == ["embed"] {
            // Worth saying, because it is the answer to "why is my machine
            // doing anything while I am using it".
            return "Only Neural Engine work, which does not touch the graphics your apps use."
        }
        return "Running \(status.permitted.joined(separator: " and ")) work while you are away."
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct MenuContents: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: model.symbolName).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.headline).font(.headline)
                    Text(model.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            if let status = model.status {
                // The contribution counter. This is the part that changes how
                // people feel about the arrangement.
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Contributed").foregroundStyle(.secondary)
                        Text("\(status.itemsCompleted) items, \(status.unitsCompleted) batches")
                    }
                    GridRow {
                        Text("Handed back").foregroundStyle(.secondary)
                        Text(status.yields == 0 ? "never had to"
                                                : "\(status.yields) times when you returned")
                    }
                    if status.residentGb > 0 {
                        GridRow {
                            Text("Memory in use").foregroundStyle(.secondary)
                            Text(String(format: "%.1f GB", status.residentGb))
                        }
                    }
                    GridRow {
                        Text("This machine").foregroundStyle(.secondary)
                        Text(status.presenceState.lowercased())
                    }
                    if !status.controlPlaneReachable {
                        GridRow {
                            Text("Fleet").foregroundStyle(.secondary)
                            Text("not reachable").foregroundStyle(.orange)
                        }
                    }
                }
                .font(.caption)

                Divider()
            }

            Button(model.paused ? "Resume" : "Pause on this machine") {
                model.togglePause()
            }
            .keyboardShortcut(model.paused ? "r" : "p")

            if !model.paused {
                Text("Pausing takes effect within a few seconds and cannot be overridden.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
    }
}
