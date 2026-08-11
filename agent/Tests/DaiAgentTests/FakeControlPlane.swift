import CryptoKit
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
    private(set) var lastStoredModels: [String: Double]?

    func setQueued(_ leases: [ControlPlane.Lease]) { queued = leases }

    /// Refuse every lease with a fixed reason, which is how the server reports
    /// an operator pause. The node learns it is paused only by being told no.
    var refuseWith: String?
    func setRefuseWith(_ reason: String?) { refuseWith = reason }
    func setDispatches(_ items: [ControlPlane.Dispatch]) { dispatches = items }
    func cancel(_ id: String) { cancelled.insert(id) }

    func fetchPolicy() async throws -> [PresenceState: StatePolicy] { policy }

    func heartbeat(state: PresenceState, onACPower: Bool?, thermalOK: Bool?,
                   userPaused: Bool, capability: [String: Double],
                   residentModels: [String: Double], storedModels: [String: Double]?,
                   modelInfo: [String: Int]) async throws {
        heartbeats.append((state, userPaused, residentModels, modelInfo))
        if let storedModels { lastStoredModels = storedModels }
    }

    func leaseWork(kinds: [WorkKind]) async throws -> ControlPlane.Lease? {
        leaseRequests.append(kinds)
        if let refuseWith {
            lastLeaseReason = refuseWith
            return nil
        }
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

    // Model distribution. `contents` is what the repository would serve, so a
    // test can hand back the wrong bytes and check that the node refuses them.
    var assigned: [ControlPlane.AssignedModel] = []
    var contents: [String: Data] = [:]
    private(set) var downloads: [String] = []

    func setAssigned(_ models: [ControlPlane.AssignedModel]) { assigned = models }
    func setContents(_ c: [String: Data]) { contents = c }

    func assignedModels() async throws -> [ControlPlane.AssignedModel] { assigned }

    /// What renewal should hand back. Nil makes renewal fail, which is the
    /// case that matters: a node whose renewal keeps failing eventually drops
    /// out of the fleet, and the loop has to survive that rather than stop.
    var renewal: ControlPlane.Renewed?
    private(set) var renewalRequests: [String] = []
    struct RenewalRefused: Error {}

    func renew(csrPEM: String) async throws -> ControlPlane.Renewed {
        renewalRequests.append(csrPEM)
        guard let renewal else { throw RenewalRefused() }
        return renewal
    }

    func downloadModelFile(modelId: String, path: String,
                           to destination: URL) async throws -> String {
        downloads.append("\(modelId)/\(path)")
        let data = contents["\(modelId)/\(path)"] ?? Data()
        let temp = destination.appendingPathExtension("partial")
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: temp)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
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

/// A control plane that cannot be reached, for the paths where the difference
/// between "nothing assigned" and "could not ask" is the whole point.
actor FailingControlPlane: ControlPlaneClient {
    struct Unreachable: Error {}

    func fetchPolicy() async throws -> [PresenceState: StatePolicy] { throw Unreachable() }
    func heartbeat(state: PresenceState, onACPower: Bool?, thermalOK: Bool?,
                   userPaused: Bool, capability: [String: Double],
                   residentModels: [String: Double], storedModels: [String: Double]?,
                   modelInfo: [String: Int]) async throws { throw Unreachable() }
    func leaseWork(kinds: [WorkKind]) async throws -> ControlPlane.Lease? { throw Unreachable() }
    var lastLeaseReason: String? { nil }
    func report(unitId: String, completed: [WorkItem], unfinished: [WorkItem],
                seconds: Double, failed: Bool) async throws -> Int { throw Unreachable() }
    func awaitDispatch() async throws -> ControlPlane.Dispatch? { throw Unreachable() }
    func reportDispatch(id: String, text: String?, error: String?,
                        promptTokens: Int, completionTokens: Int,
                        cachedTokens: Int, toolCalls: [ToolCall]) async throws {
        throw Unreachable()
    }
    func isDispatchCancelled(id: String) async -> Bool { false }
    func assignedModels() async throws -> [ControlPlane.AssignedModel] { throw Unreachable() }
    func downloadModelFile(modelId: String, path: String,
                           to destination: URL) async throws -> String { throw Unreachable() }
    func renew(csrPEM: String) async throws -> ControlPlane.Renewed { throw Unreachable() }
}
