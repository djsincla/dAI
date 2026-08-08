import DaiAgent
import Foundation

// Minimal entry point while the runtimes are ported. Reading the real machine is
// the first thing worth being able to see: if presence is wrong, everything
// downstream is wrong in a way that disturbs somebody.
let source = MacSignalSource()
let monitor = PresenceMonitor()
let signals = source.read()
let reading = monitor.update(signals, now: Date().timeIntervalSince1970)

func fmt(_ v: TimeInterval?) -> String { v.map { String(format: "%.1f", $0) } ?? "unreadable" }

print("""
presence   \(reading.state.rawValue)  (observed \(reading.observed.rawValue))
hid idle   \(fmt(signals.hidIdleSeconds))s
locked     \(signals.screenLocked.map(String.init(describing:)) ?? "unknown")
console    \(signals.consoleUser ?? "nobody")
ac power   \(signals.onACPower)
thermal    \(signals.thermalOK ? "ok" : "pressure")
display assertions  \(signals.displayAssertions.isEmpty ? "none" : signals.displayAssertions.joined(separator: ", "))
busy assertions     \(signals.busyAssertions.isEmpty ? "none" : signals.busyAssertions.prefix(3).joined(separator: ", "))

policy     gpu=\(reading.policy.gpu) ane=\(reading.policy.ane) qos=\(reading.policy.qos.rawValue) \
duty=\(reading.policy.dutyMax) mem=\(reading.policy.memFrac)
permits    \(permittedKinds(reading.state, policy: reading.policy).map(\.rawValue).joined(separator: ", "))
\(reading.policy.blockedBy.isEmpty ? "" : "blocked by \(reading.policy.blockedBy.joined(separator: ", "))")
""")
