import Foundation
import Synchronization
import Testing
@testable import DaiWorker

/// Startup questions asked until the control plane answers.
///
/// rotorua rebooted with the agent up fifteen seconds before the control plane.
/// Its one question about its own tier was refused, the default of harvest
/// stood, and the machine sat out of interactive serving for a week while every
/// heartbeat said it was healthy.
struct UntilAnsweredTests {
    struct Refused: Error {}

    /// Records what it is told instead of doing it, so no test waits.
    final class Recorder: Sendable {
        let lines = Mutex<[String]>([])
        let waits = Mutex<[Duration]>([])
        let calls = Mutex(0)
    }

    @Test("keeps asking through refusals and returns the answer")
    func asksAgain() async throws {
        let r = Recorder()
        let answer = try await untilAnswered(
            "ask which tiers this machine is in",
            log: { line in r.lines.withLock { $0.append(line) } },
            sleep: { d in r.waits.withLock { $0.append(d) } }
        ) {
            let n = r.calls.withLock { $0 += 1; return $0 }
            if n < 4 { throw Refused() }
            return "cluster"
        }
        #expect(answer == "cluster")
        #expect(r.calls.withLock { $0 } == 4)
    }

    @Test("says so every time it is refused, and when it is finally answered")
    func logsEachMiss() async throws {
        // The fault this replaces logged nothing, so the only trace of it was a
        // week of 503s.
        let r = Recorder()
        _ = try await untilAnswered(
            "fetch the presence policy",
            log: { line in r.lines.withLock { $0.append(line) } },
            sleep: { _ in }
        ) {
            let n = r.calls.withLock { $0 += 1; return $0 }
            if n < 3 { throw Refused() }
            return 0
        }
        let lines = r.lines.withLock { $0 }
        #expect(lines.count == 3)
        #expect(lines[0].contains("no answer (attempt 1)"))
        #expect(lines[1].contains("no answer (attempt 2)"))
        #expect(lines[2].contains("answered on attempt 3"))
    }

    @Test("stays quiet when the first attempt is answered")
    func quietWhenAnswered() async throws {
        let r = Recorder()
        _ = try await untilAnswered(
            "fetch the presence policy",
            log: { line in r.lines.withLock { $0.append(line) } },
            sleep: { _ in }
        ) { 0 }
        #expect(r.lines.withLock { $0 }.isEmpty)
    }

    @Test("backs off, but not past the longest wait")
    func backsOff() async throws {
        // Doubling without a cap would leave a machine whose control plane was
        // down for an hour waiting most of another hour to notice it was back.
        let r = Recorder()
        _ = try await untilAnswered(
            "ask which tiers this machine is in",
            log: { _ in },
            sleep: { d in r.waits.withLock { $0.append(d) } }
        ) {
            let n = r.calls.withLock { $0 += 1; return $0 }
            if n < 7 { throw Refused() }
            return 0
        }
        #expect(r.waits.withLock { $0 } == [
            .seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60),
        ])
    }

    @Test("stops when cancelled rather than asking forever")
    func stopsOnCancel() async {
        let task = Task {
            try await untilAnswered(
                "ask which tiers this machine is in",
                log: { _ in },
                sleep: { try await Task.sleep(for: $0) }
            ) { () async throws -> Int in throw Refused() }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
