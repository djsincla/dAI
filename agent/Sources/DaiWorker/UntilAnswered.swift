import Foundation

/// Ask the control plane something until it answers.
///
/// For the questions the agent asks once at startup and then lives by: which
/// tiers this machine is in, and the presence policy. Asked once and the
/// failure swallowed, a single miss lasted for the life of the process.
///
/// It did, on a reboot. The agent came up fifteen seconds before the control
/// plane, whose database was not up yet, so "is this machine cluster tier?" got
/// a refused connection and the answer stayed "no". A cluster machine then
/// behaved as a harvest one for a week: while its owner was at the keyboard it
/// never held the reverse channel open, the gateway had nobody to route to, and
/// every request came back 503 from a fleet whose heartbeats all looked fine.
///
/// Callers start on the conservative default and let this finish in the
/// background, so a slow control plane delays the correct answer rather than
/// the whole agent. Every failed attempt is logged, because the failure this
/// replaces left nothing in the log at all.
public func untilAnswered<T: Sendable>(
    _ question: String,
    firstWait: Duration = .seconds(5),
    longestWait: Duration = .seconds(60),
    log: @Sendable (String) -> Void,
    sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    _ ask: @Sendable () async throws -> T
) async throws -> T {
    var wait = firstWait
    var attempt = 1
    while true {
        do {
            let answer = try await ask()
            if attempt > 1 { log("\(question): answered on attempt \(attempt)") }
            return answer
        } catch {
            log("\(question): no answer (attempt \(attempt)), asking again in \(wait): \(error)")
        }
        // Throws on cancellation, which is the only way out without an answer.
        try await sleep(wait)
        wait = min(wait * 2, longestWait)
        attempt += 1
    }
}
