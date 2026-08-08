import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Where presence signals come from.
///
/// Behind a protocol so the policy core stays testable without hardware. Every
/// policy bug found in the Python agent reproduced from a recorded signal
/// struct, and keeping that seam is what makes the 20 tests in this package
/// possible on any machine.
public protocol SignalSource: Sendable {
    func read() -> Signals
}

/// Background services that hold sleep assertions indefinitely with no human
/// involved.
///
/// Without this list, `sharingd`'s permanent Handoff assertion pins a machine in
/// PASSIVE forever and it never harvests at all. `coreaudiod` was found later
/// holding assertions for device *context* on a completely idle machine, which
/// is not playback.
let systemAssertionProcesses: Set<String> = [
    "powerd", "sharingd", "backupd", "mds", "mds_stores", "mDNSResponder",
    "softwareupdated", "nsurlsessiond", "cloudd", "bird", "AppleIDAuthAgent",
    "UpdateBrainService", "corespeechd", "photoanalysisd", "AMPDeviceDiscoveryAgent",
    "coreaudiod",
]

/// Reads the real machine.
///
/// Deliberately IOKit and power-management rather than AppKit: a LaunchDaemon in
/// session 0 has no GUI session, and E1 confirmed these survive there where
/// NSWorkspace and CGEventSource would not.
public struct MacSignalSource: SignalSource {
    public init() {}

    public func read() -> Signals {
        Signals(
            hidIdleSeconds: hidIdleSeconds(),
            screenLocked: screenLocked(),
            consoleUser: consoleUser(),
            onACPower: onACPower(),
            displayAssertions: assertions().display,
            busyAssertions: assertions().busy,
            thermalOK: thermalOK()
        )
    }

    /// Seconds since the last keyboard, mouse or trackpad event.
    ///
    /// Read from IOHIDSystem rather than `CGEventSourceSecondsSinceLastEventType`
    /// so it works with no GUI session. The property is in nanoseconds.
    func hidIdleSeconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let prop = IORegistryEntryCreateCFProperty(
            service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }

        if let n = prop as? NSNumber { return n.doubleValue / 1_000_000_000 }
        return nil
    }

    /// Whether the screen is locked, via the IORegistry root rather than the
    /// window server, for the same session-0 reason.
    func screenLocked() -> Bool? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let prop = IORegistryEntryCreateCFProperty(
            root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return (prop as? NSNumber)?.boolValue
    }

    /// Who owns the GUI session, or nil when nobody is logged in.
    func consoleUser() -> String? {
        var st = stat()
        guard stat("/dev/console", &st) == 0 else { return nil }
        guard let pw = getpwuid(st.st_uid) else { return nil }
        let name = String(cString: pw.pointee.pw_name)
        // loginwindow owns the console when nobody is logged in.
        return ["", "root", "_windowserver", "loginwindow"].contains(name) ? nil : name
    }

    func onACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return true }  // desktops report nothing; they are always on AC

        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = d[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue
            }
        }
        return true
    }

    /// `ProcessInfo.thermalState` rather than parsing `pmset -g therm`. One of
    /// several places where the Swift agent replaces a subprocess with a call.
    func thermalOK() -> Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: return true
        case .serious, .critical: return false
        @unknown default: return true
        }
    }

    /// Sleep assertions, split by what they actually imply.
    ///
    /// These answer two different questions and conflating them is wrong:
    ///
    /// `PreventUserIdleDisplaySleep` means something insists the *display* stay
    /// on: a call, playback, a presentation. Strong evidence a human is looking
    /// at the screen right now.
    ///
    /// `PreventUserIdleSystemSleep` means something insists the *machine* keep
    /// running. Renders hold it, but so do a dozen background daemons
    /// permanently, so it is evidence the machine is busy rather than that
    /// anyone is present. Only the display class implies presence.
    func assertions() -> (display: [String], busy: [String]) {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dict = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return ([], []) }

        var display: [String] = []
        var busy: [String] = []
        for (pid, list) in dict {
            for entry in list {
                guard let type = entry["AssertType"] as? String else { continue }
                // Prefer the name the assertion carries. proc_name() fails for
                // some system processes, and falling back to "pid 349" meant
                // powerd sailed straight through the filter it was written for.
                let name = (entry["Process Name"] as? String)
                    ?? processName(pid.int32Value)
                    ?? "pid \(pid)"
                if systemAssertionProcesses.contains(name) { continue }
                let assertName = entry["AssertName"] as? String ?? type
                // powerd's assertion is identifiable by name even when its
                // process is not: it reflects the display being on, not work.
                if assertName.hasPrefix("Powerd - ") { continue }
                let label = "\(name): \(assertName)"
                if type == kIOPMAssertionTypePreventUserIdleDisplaySleep {
                    display.append(label)
                } else if type == kIOPMAssertionTypePreventUserIdleSystemSleep {
                    busy.append(label)
                }
            }
        }
        return (display, busy)
    }

    private func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }
}

/// Replays a fixed sequence. Used by tests and by `--simulate` so the yield path
/// can be exercised deterministically rather than by waiting on a real user.
///
/// A final class with a lock rather than a struct: the protocol is synchronous
/// and this has to advance a cursor, which Swift 6 will not let a Sendable
/// struct do. The lock is the honest way to say "shared mutable state, guarded".
public final class ScriptedSignalSource: SignalSource, @unchecked Sendable {
    private let script: [Signals]
    private let lock = NSLock()
    private var cursor = 0

    public init(_ script: [Signals]) { self.script = script }

    public func read() -> Signals {
        lock.lock()
        defer { lock.unlock() }
        guard !script.isEmpty else { return Signals() }
        let s = script[min(cursor, script.count - 1)]
        cursor += 1
        return s
    }
}
