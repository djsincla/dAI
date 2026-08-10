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
///
/// Not in a file called `main.swift`: `@main` and top-level code cannot coexist,
/// and SwiftPM's debug build tolerated what a Release build rejects outright.
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

    /// Whether an agent is installed at all.
    ///
    /// Without this the app cannot tell "nothing is installed here" from "the
    /// daemon has stopped", and it reported the first as the second: alarming
    /// language about a machine where nothing was ever meant to be running.
    private var daemonInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.dai.agent.plist")
    }

    init() {
        refresh()
        // Two seconds: fast enough that pausing feels immediate, slow enough to
        // be free. The daemon republishes far more often than this.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @Published private(set) var installed = false

    func refresh() {
        status = AgentStatus.read()
        paused = pauseSwitch.read().paused
        installed = daemonInstalled
    }

    func togglePause() {
        // Written locally and taking effect on the next poll, rather than asking
        // anything. A pause that depends on a server is a pause that fails when
        // the network is down, which is not a property anyone wants from a
        // button labelled stop.
        try? paused ? pauseSwitch.resume() : pauseSwitch.pause(reason: "paused from the menu bar")
        refresh()
    }

    /// A fresh status file outranks everything.
    ///
    /// The installation check is a fallback for working out *why* nothing is
    /// reporting, not a precondition for believing what is. Checking it first
    /// meant the app said "not installed" while an agent was visibly running,
    /// which is worse than the vagueness it replaced: a status panel that
    /// contradicts the machine teaches people to ignore it.
    private var running: Bool { status?.isFresh == true }

    var symbolName: String {
        if paused { return "pause.circle" }
        if status?.pausedByFleet == true, running { return "pause.circle.fill" }
        if running { return status!.activity.hasPrefix("running") ? "bolt.fill" : "bolt" }
        return installed ? "exclamationmark.triangle" : "bolt.slash"
    }

    /// Deliberately plain language. The audience is someone whose machine feels
    /// slow, not an operator.
    var headline: String {
        if paused { return "Paused by you" }
        guard let status, running else {
            if !installed { return "Not installed" }
            return status == nil ? "Starting up" : "Not responding"
        }
        if status.pausedByFleet { return "Paused by the studio" }
        if status.permitted.isEmpty { return "Standing by" }
        if status.activity.hasPrefix("running") { return "Working" }
        return "Waiting for work"
    }

    var detail: String {
        if paused { return "Nothing will run here until you resume." }
        guard let status, running else {
            if !installed {
                return "No agent is installed on this machine, so nothing is running here."
            }
            guard let status else { return "The agent is installed but has not reported yet." }
            // Says what it knows rather than guessing. This is the state that
            // should prompt someone to ask a question, so it needs to be
            // distinguishable from ordinary idleness at a glance.
            return "Installed, but no update since \(Self.relative(status.updated)). "
                + "It has probably stopped."
        }
        if status.pausedByFleet {
            // Says who, and says plainly that this one is not theirs to undo.
            // Offering no explanation would leave someone pressing a button
            // that cannot work.
            return "An administrator has paused this machine. Your own pause "
                + "button is unaffected, but resuming has to happen centrally."
        }
        if status.permitted.isEmpty {
            return "You are using this machine, so nothing is running."
        }
        if status.permitted == ["serve"] {
            // A different bargain from overnight batch work, and the person at
            // the desk is the one it differs for.
            return "Answering requests for the studio from this machine."
        }
        if status.permitted == ["embed"] {
            // Worth saying, because it is the answer to "why is my machine
            // doing anything while I am using it".
            return "Only Neural Engine work, which does not touch the graphics your apps use."
        }
        return "Running \(status.permitted.joined(separator: " and ")) work while you are away."
    }

    /// Figures are worth showing whenever there are any, including after the
    /// agent stops: what somebody contributed does not become untrue because
    /// the daemon is no longer running.
    var showsFigures: Bool { (status?.itemsCompleted ?? 0) > 0 || running }

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
            // Says what this is, unprompted.
            //
            // Someone finding an unexplained icon on their own machine has one
            // question, and it is not the presence state. Without a name and a
            // sentence, the panel answers "what is it doing" for a thing the
            // reader has no reason to recognise, which reads as something that
            // installed itself.
            VStack(alignment: .leading, spacing: 2) {
                Text("dAI").font(.system(size: 15, weight: .semibold))
                Text("Shared compute. This machine helps run the studio's AI work "
                     + "when you are not using it.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Image(systemName: model.symbolName).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.headline).font(.headline)
                    Text(model.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            if let status = model.status, model.showsFigures {
                // The contribution counter. This is the part that changes how
                // people feel about the arrangement.
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Contributed").foregroundStyle(.secondary)
                        Text(status.permitted == ["serve"]
                             ? "\(status.unitsCompleted) requests answered"
                             : "\(status.itemsCompleted) items, \(status.unitsCompleted) batches")
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
                    if let label = status.jobLabel, !label.isEmpty {
                        GridRow {
                            Text("Working on").foregroundStyle(.secondary)
                            // The source is shown whenever it is not ordinary
                            // traffic, so a load test cannot be mistaken for
                            // the studio's actual work on someone's machine.
                            Text(status.jobSource.map { $0 == "api" ? label : "\(label) - \($0)" }
                                 ?? label)
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

            // Where it goes and where it does not, in one line. This is the
            // question behind the question when somebody opens this panel.
            Text("Work runs here and results go to the studio's own control "
                 + "plane. Nothing leaves the building.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Quit this menu") { NSApplication.shared.terminate(nil) }
                .font(.caption)
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
    }
}
