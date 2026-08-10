import Foundation
@testable import DaiAgent

/// A control plane that records what an agent did to it.
///
/// The loops could not be tested at all before this: exercising either meant a
/// real control plane over mTLS and a real model on real hardware, so nobody
/// did, and every bug that reached production lived in them. This is not a
/// mock of a tidier interface - it implements the surface the loops actually
/// use, so a test of that surface is a test of the thing that ships.
actor FakeControlPlane: ControlPlaneClient {
    // What the agent said.
    private(set) var heartbeats: [(state: PresenceState, paused: Bool,
                                   resident: [String: Double], models: [String: Int])] = []
    private(set) var leaseRequests: [[WorkKind]] = []
    private(set) var results: [(unitId: String, completed: Int, unfinished: Int)] = []
    private(set) var dispatchResults: [(id: String, text: String?, error: String?)] = []

    // What it will be told.
    var policy: [PresenceState: StatePolicy] = defaultPolicy
    var queued: [ControlPlane.Lease] = []
    var dispatches: [ControlPlane.Dispatch] = []
    var cancelled: Set<String> = []
    private(set) var lastLeaseReason: String?

    func setQueued(_ leases: [ControlPlane.Lease]) { queued = leases }
    func setDispatches(_ items: [ControlPlane.Dispatch]) { dispatches = items }
    func cancel(_ id: String) { cancelled.insert(id) }

    func fetchPolicy() async throws -> [PresenceState: StatePolicy] { policy }

    func heartbeat(state: PresenceState, onACPower: Bool?, thermalOK: Bool?,
                   userPaused: Bool, capability: [String: Double],
                   residentModels: [String: Double], modelInfo: [String: Int]) async throws {
        heartbeats.append((state, userPaused, residentModels, modelInfo))
    }

    func leaseWork(kinds: [WorkKind]) async throws -> ControlPlane.Lease? {
        leaseRequests.append(kinds)
        guard !queued.isEmpty else {
            lastLeaseReason = "empty"
            return nil
        }
        // Only work of a kind that was asked for, which is the rule the real
        // scheduler enforces and the one a client bug can silently break.
        guard let index = queued.firstIndex(where: { kinds.contains($0.kind) }) else {
            lastLeaseReason = "none-of-these-kinds"
            return nil
        }
        lastLeaseReason = nil
        return queued.remove(at: index)
    }

    @discardableResult
    func report(unitId: String, completed: [WorkItem], unfinished: [WorkItem],
                seconds: Double, failed: Bool) async throws -> Int {
        results.append((unitId, completed.count, unfinished.count))
        return unfinished.count
    }

    func awaitDispatch() async throws -> ControlPlane.Dispatch? {
        guard !dispatches.isEmpty else {
            // Long-poll timeouts are the common case, and a loop that treats
            // one as an error spins.
            try? await Task.sleep(for: .milliseconds(20))
            return nil
        }
        return dispatches.removeFirst()
    }

    func reportDispatch(id: String, text: String?, error: String?,
                        promptTokens: Int, completionTokens: Int,
                        cachedTokens: Int, toolCalls: [ToolCall]) async throws {
        dispatchResults.append((id, text, error))
    }

    func isDispatchCancelled(id: String) async -> Bool { cancelled.contains(id) }
}

/// Presence the test decides, rather than whatever the machine running it
/// happens to be doing.
struct FixedSignals: SignalSource {
    let signals: Signals
    func read() -> Signals { signals }

    static func present() -> FixedSignals {
        FixedSignals(signals: Signals(hidIdleSeconds: 0, screenLocked: false,
                                      consoleUser: "someone"))
    }

    static func away() -> FixedSignals {
        FixedSignals(signals: Signals(hidIdleSeconds: 9999, screenLocked: true,
                                      consoleUser: "someone"))
    }
}
