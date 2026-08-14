import Testing
@testable import DaiControlStatusCore
import Foundation

/// launchctl's answer, which is the only one available without a password.
@Suite("what launchd says")
struct DaemonStateTests {
    /// Taken verbatim from `launchctl print system/com.dai.control` on this
    /// machine, because a parser written against remembered output is a parser
    /// written against the wrong thing.
    let real = """
    system/com.dai.control = {
    \tactive count = 1
    \tpath = /Library/LaunchDaemons/com.dai.control.plist
    \ttype = LaunchDaemon
    \tstate = running

    \tprogram = /usr/local/libexec/dai-control/node
    \tpid = 4471
    }
    """

    @Test("reads a running daemon, and its pid")
    func running() {
        #expect(DaemonReader.parse(printOutput: real, plistExists: true) == .running(pid: 4471))
    }

    @Test("not installed is not stopped")
    func notInstalled() {
        // The distinction the agent's menu bar app got wrong once: a machine
        // where nothing was ever meant to run described in alarming language.
        #expect(DaemonReader.parse(printOutput: nil, plistExists: false) == .notInstalled)
        #expect(DaemonReader.parse(printOutput: nil, plistExists: true) == .stopped)
    }

    @Test("launchctl printing nothing means the job is not loaded")
    func notLoaded() {
        #expect(DaemonReader.parse(printOutput: "", plistExists: true) == .stopped)
    }

    @Test("unfamiliar output is running-without-a-pid, never stopped")
    func tolerant() {
        // If Apple rewords the state line, the safe direction to fail is toward
        // "it is up". Reporting a live control plane as down is what sends
        // somebody to restart a fleet that was working.
        let state = DaemonReader.parse(printOutput: "system/com.dai.control = {\n\tstate = spawn scheduled\n}",
                                       plistExists: true)
        #expect(state.isRunning)
    }

    @Test("an explicit not-running is believed")
    func explicit() {
        #expect(DaemonReader.parse(printOutput: "state = not running", plistExists: true) == .stopped)
    }
}

@Suite("what /healthz says")
struct HealthTests {
    @Test("parses the current answer")
    func current() {
        let h = Health.parse(Data(#"{"ok":true,"surface":"both","version":"0.3.2"}"#.utf8))
        #expect(h == Health(ok: true, surface: "both", version: "0.3.2"))
        #expect(h?.versionDescription == "0.3.2")
    }

    @Test("parses a control plane too old to report a version")
    func old() {
        // Exactly what 0.3.1 on this desk answers. The app must not report the
        // machine most in need of upgrading as unreachable.
        let h = Health.parse(Data(#"{"ok":true,"surface":"both"}"#.utf8))
        #expect(h?.ok == true)
        #expect(h?.version == nil)
        #expect(h?.versionDescription.contains("does not report") == true)
    }

    @Test("does not dress a working tree up as a release")
    func dev() {
        let h = Health.parse(Data(#"{"ok":true,"surface":"agent","version":"dev"}"#.utf8))
        #expect(h?.versionDescription.contains("working tree") == true)
    }

    @Test("refuses a body it cannot read")
    func garbage() {
        #expect(Health.parse(Data("not json".utf8)) == nil)
        #expect(Health.parse(Data("{}".utf8)) == nil)
    }
}

@Suite("the fleet, out of the metrics already served")
struct FleetTests {
    @Test("reads the version out of build_info")
    func buildInfo() {
        let f = Fleet.parse("""
        # HELP dai_build_info the version of the control plane, as a label
        # TYPE dai_build_info gauge
        dai_build_info{version="0.3.2"} 1
        """)
        #expect(f.version == "0.3.2")
    }

    @Test("counts nodes and the ones working")
    func nodes() {
        let f = Fleet.parse("""
        dai_nodes{state="working"} 2
        dai_nodes{state="idle"} 3
        """)
        #expect(f.nodes == 5)
        #expect(f.working == 2)
    }

    @Test("skips metrics it was not written for")
    func unknown() {
        // A metric added on the server must not need a release of this app.
        let f = Fleet.parse("""
        dai_something_new{kind="x"} 9
        dai_nodes{state="idle"} 1
        garbage without a value
        """)
        #expect(f.nodes == 1)
    }

    @Test("empty input is empty, not a crash")
    func empty() {
        #expect(Fleet.parse("") == Fleet(version: nil, nodes: 0, working: 0))
    }
}

@Suite("what the window says")
struct DiagnosisTests {
    @Test("running and answering is the ordinary case")
    func serving() {
        let d = Diagnosis.of(daemon: .running(pid: 1),
                             health: Health(ok: true, surface: "both", version: "0.3.2"),
                             port: 8452, startedWithin: false)
        #expect(d.isGood)
        #expect(d.message.contains("both"))
        #expect(d.message.contains("0.3.2"))
    }

    @Test("a process that exists is not a control plane that serves")
    func upButNotServing() {
        // The pair is the whole point. launchd says the process is there; the
        // database went away, so nothing works. Restarting the daemon - the
        // thing an operator does when told only that it is 'down' - fixes
        // nothing here.
        let d = Diagnosis.of(daemon: .running(pid: 1),
                             health: Health(ok: false, surface: "both", version: "0.3.2"),
                             port: 8452, startedWithin: false)
        #expect(!d.isGood)
        #expect(d.message.contains("Postgres"))
    }

    @Test("a restart is not a failure for the two seconds it takes")
    func grace() {
        let starting = Diagnosis.of(daemon: .running(pid: 1), health: nil,
                                    port: 8452, startedWithin: true)
        #expect(starting == .starting)

        let stuck = Diagnosis.of(daemon: .running(pid: 1), health: nil,
                                 port: 8452, startedWithin: false)
        #expect(stuck == .notAnswering(port: 8452))
        #expect(stuck.message.contains("8452"))
    }

    @Test("nothing installed says so plainly")
    func absent() {
        let d = Diagnosis.of(daemon: .notInstalled, health: nil, port: 8452, startedWithin: false)
        #expect(d.message.contains("No control plane"))
    }

    @Test("every state has its own icon, and only faults look like faults")
    func icons() {
        let faults: [Diagnosis] = [.unhealthy, .notAnswering(port: 8452)]
        for f in faults { #expect(f.symbolName.contains("exclamationmark")) }
        #expect(!Diagnosis.serving(surface: "both", version: "0.3.2").symbolName.contains("exclamationmark"))
        #expect(!Diagnosis.stopped.symbolName.contains("exclamationmark"))
    }
}

@Suite("what the app may ask the system to do")
struct ActionTests {
    @Test("restart goes through the script that knows bootout is asynchronous")
    func restartUsesReloadScript() {
        // bootout returns before the job is gone, and bootstrapping into a label
        // that still exists fails with 5: Input/output error. That cost a failed
        // install to learn, and the knowledge lives in one script.
        let cmd = DaemonAction.restart.command()
        #expect(cmd.contains("reload-daemon.sh"))
        #expect(!cmd.contains("bootout"))
    }

    @Test("offers only what makes sense")
    func availability() {
        #expect(DaemonAction.start.isAvailable(given: .stopped))
        #expect(!DaemonAction.start.isAvailable(given: .running(pid: 1)))
        #expect(DaemonAction.stop.isAvailable(given: .running(pid: 1)))
        #expect(!DaemonAction.stop.isAvailable(given: .stopped))
        // Nothing is offered where nothing is installed.
        for a in DaemonAction.allCases { #expect(!a.isAvailable(given: .notInstalled)) }
    }

    @Test("stopping the fleet asks twice; restarting does not")
    func confirmation() {
        #expect(DaemonAction.stop.needsConfirmation)
        #expect(!DaemonAction.restart.needsConfirmation)
        #expect(!DaemonAction.start.needsConfirmation)
    }

    @Test("every prompt says what it is for")
    func prompts() {
        // macOS shows this verbatim, and an unexplained password prompt is one
        // people learn to approve without reading.
        for a in DaemonAction.allCases {
            #expect(a.authorizationPrompt.contains("control plane"))
            #expect(a.authorizationPrompt.contains(a == .restart ? "restart"
                                                 : a == .stop ? "stop" : "start"))
        }
    }

    @Test("commands name the installed label, never a guess")
    func targets() {
        for a in DaemonAction.allCases {
            #expect(a.command().contains("com.dai.control"))
        }
    }
}
