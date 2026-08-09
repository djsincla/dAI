import DaiAgent
import Foundation

// Subcommands while the port proceeds. `presence` is the one worth having first:
// if presence is wrong, everything downstream is wrong in a way that disturbs
// somebody.
let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "presence"

func fmt(_ v: TimeInterval?) -> String { v.map { String(format: "%.1f", $0) } ?? "unreadable" }

switch command {
case "presence":
    let signals = MacSignalSource().read()
    let monitor = PresenceMonitor()
    let reading = monitor.update(signals, now: Date().timeIntervalSince1970)
    print("""
    presence   \(reading.state.rawValue)  (observed \(reading.observed.rawValue))
    hid idle   \(fmt(signals.hidIdleSeconds))s
    locked     \(signals.screenLocked.map(String.init(describing:)) ?? "unknown")
    console    \(signals.consoleUser ?? "nobody")
    ac power   \(signals.onACPower)
    thermal    \(signals.thermalOK ? "ok" : "pressure")
    policy     gpu=\(reading.policy.gpu) ane=\(reading.policy.ane) qos=\(reading.policy.qos.rawValue)
    limits     duty=\(reading.policy.dutyMax) mem=\(reading.policy.memFrac) maxTokens=\(reading.policy.maxCompletionTokens)
    permits    \(permittedKinds(reading.state, policy: reading.policy).map(\.rawValue).joined(separator: ", "))
    """)

case "verify-ane":
    // Placement verification is the safety property, so it gets its own command:
    // Core ML falls back to CPU silently, and a model that is not ANE-resident
    // would disturb the very user this runtime exists to avoid.
    guard args.count > 2 else {
        print("usage: dai-agent verify-ane <model.mlpackage>"); exit(2)
    }
    let url = URL(fileURLWithPath: args[2])
    let runtime = ANERuntime(modelURL: url)
    do {
        let seconds = try await runtime.load()
        guard let p = await runtime.placement else { print("no placement"); exit(1) }
        print(String(format: "loaded in %.2fs", seconds))
        for (device, n) in p.devices.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-34s %4d ops  (%.0f%%)",
                         (device as NSString).utf8String!, n,
                         Double(n) / Double(p.totalOps) * 100))
        }
        print(String(format: "ANE share: %.0f%% of %d compute ops", p.aneShare * 100, p.totalOps))
        print("VERDICT: ANE-resident. Safe to run while someone is using the machine.")
    } catch {
        print("REFUSED: \(error)")
        exit(1)
    }

case "qos":
    // Demonstrates the control that E1 measured at 2.4x on sustained work and
    // the worker at ~26x on bursty work.
    print("enter background: \(ProcessQoS.setBackground(true))")
    print("leave background: \(ProcessQoS.setBackground(false))")

default:
    print("usage: dai-agent [presence|verify-ane <model>|qos]")
    exit(2)
}
