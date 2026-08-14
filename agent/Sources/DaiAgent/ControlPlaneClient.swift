import Foundation

/// What the worker and the serving loop need from a control plane.
///
/// Extracted so those loops can be tested at all. Every bug that has reached
/// production in this agent has been in them - a lease request that could not
/// be encoded, two heartbeats erasing each other's models, a batch loop
/// releasing the model a serving loop was using - and none was reachable by a
/// test, because exercising either loop meant standing up a real control plane
/// and a real model.
///
/// The protocol is deliberately the existing surface rather than a tidier one.
/// A shape invented for testing tests the shape that was invented.
public protocol ControlPlaneClient: Actor {
    func fetchPolicy() async throws -> [PresenceState: StatePolicy]
    func heartbeat(state: PresenceState, onACPower: Bool?, thermalOK: Bool?,
                   userPaused: Bool, capability: [String: Double],
                   residentModels: [String: Double], storedModels: [String: Double]?,
                   modelInfo: [String: Int], syncFaults: [String: String]?,
                   pipelineAddress: String?) async throws -> ControlPlane.Directives
    func leaseWork(kinds: [WorkKind]) async throws -> ControlPlane.Lease?
    var lastLeaseReason: String? { get }
    func report(unitId: String, completed: [WorkItem], unfinished: [WorkItem],
                seconds: Double, failed: Bool) async throws -> ControlPlane.ReportOutcome
    func awaitDispatch() async throws -> ControlPlane.Dispatch?
    func reportDispatch(id: String, text: String?, error: String?,
                        promptTokens: Int, completionTokens: Int,
                        cachedTokens: Int, toolCalls: [ToolCall],
                        layerPlan: [[Int]]) async throws
    func isDispatchCancelled(id: String) async -> Bool
    func assignedModels() async throws -> [ControlPlane.AssignedModel]
    func downloadModelFile(modelId: String, path: String, to destination: URL) async throws -> String
    /// Trade the certificate this client is presenting for a fresh one.
    ///
    /// On the protocol rather than only on the concrete client because the
    /// renewal loop is exactly the kind of thing that fails once a month and is
    /// never noticed, so it has to be testable without a control plane.
    func renew(csrPEM: String) async throws -> ControlPlane.Renewed
    func sceneManifest(id: String) async throws -> ControlPlane.SceneManifest
    func downloadSceneFile(sceneId: String, path: String, to destination: URL) async throws -> String
    func jobAttachments(jobId: String) async throws -> ControlPlane.SceneManifest
    func downloadBlob(sha256: String, to destination: URL) async throws -> String
    @discardableResult
    func uploadOutput(unitId: String, name: String, file: URL) async throws -> Int
}

extension ControlPlane: ControlPlaneClient {}

/// The defaults the call sites rely on.
///
/// A protocol requirement cannot carry them, so they live here rather than
/// being spelled out at every call - which would make the loops noisier in
/// order to make them testable, and the point of the protocol is that it costs
/// them nothing.
public extension ControlPlaneClient {
    func heartbeat(state: PresenceState, onACPower: Bool?, thermalOK: Bool?,
                   userPaused: Bool = false, capability: [String: Double] = [:],
                   residentModels: [String: Double] = [:],
                   storedModels: [String: Double]? = nil,
                   modelInfo: [String: Int] = [:],
                   syncFaults: [String: String]? = nil,
                   pipelineAddress: String? = PipelineAddress.current())
        async throws -> ControlPlane.Directives {
        try await heartbeat(state: state, onACPower: onACPower, thermalOK: thermalOK,
                            userPaused: userPaused, capability: capability,
                            residentModels: residentModels, storedModels: storedModels,
                            modelInfo: modelInfo, syncFaults: syncFaults,
                            pipelineAddress: pipelineAddress)
    }

    @discardableResult
    func report(unitId: String, completed: [WorkItem], unfinished: [WorkItem],
                seconds: Double, failed: Bool = false) async throws
        -> ControlPlane.ReportOutcome {
        try await report(unitId: unitId, completed: completed, unfinished: unfinished,
                         seconds: seconds, failed: failed)
    }

    func reportDispatch(id: String, text: String?, error: String?,
                        promptTokens: Int = 0, completionTokens: Int = 0,
                        cachedTokens: Int = 0, toolCalls: [ToolCall] = [],
                        layerPlan: [[Int]] = []) async throws {
        try await reportDispatch(id: id, text: text, error: error,
                                 promptTokens: promptTokens,
                                 completionTokens: completionTokens,
                                 cachedTokens: cachedTokens, toolCalls: toolCalls,
                                 layerPlan: layerPlan)
    }
}
