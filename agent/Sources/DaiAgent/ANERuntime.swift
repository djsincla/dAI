import CoreML
import Foundation

/// Core ML runtime, pinned to the Neural Engine.
///
/// This is the piece that has no Node equivalent and is the reason the agent is
/// Swift. E2 found no GPU setting imperceptible while a user is present, and the
/// worker then found background QoS costing ~26x on bursty work, which together
/// confine GPU work to LOCKED and ABSENT. E5 measured a saturating ANE workload
/// as statistically indistinguishable from no load. So ANE work is the entire
/// contribution a logged-in machine makes, across three of five states.
///
/// **The safety property is placement verification.** Core ML treats
/// `.cpuAndNeuralEngine` as a *preference*: unsupported ops, dtypes or shapes
/// fall back to CPU silently. A worker that believed it was on the ANE while
/// actually running on the CPU would be disturbing the very user it is trying to
/// avoid, and every log would look fine. So placement is checked with
/// `MLComputePlan` at load and the runtime refuses to start below a threshold.
///
/// `MLComputePlan` requires macOS 14.4, which sets this package's floor. Making
/// the check conditional on availability was the alternative and is worse: an
/// agent that silently skips verification on older systems is exactly the
/// failure mode the verification exists to prevent.
public actor ANERuntime {
    /// Below this share of compute ops on the ANE, the model is not doing what
    /// the policy assumes and running it would disturb someone.
    public static let minANEShare = 0.8

    public struct Placement: Sendable {
        public let devices: [String: Int]
        public let totalOps: Int
        public let aneShare: Double
    }

    public enum Failure: Error, CustomStringConvertible {
        case notANEResident(share: Double, ops: Int)
        case noComputePlan
        case load(String)

        public var description: String {
            switch self {
            case let .notANEResident(share, ops):
                return String(format: "only %.0f%% of %d compute ops are on the ANE " +
                              "(need >=%.0f%%). Running anyway would disturb the user " +
                              "while reporting ANE-safe operation.",
                              share * 100, ops, Self.minShare * 100)
            case .noComputePlan:
                return "no compute plan available; placement unverifiable"
            case let .load(m): return "could not load model: \(m)"
            }
        }
        private static let minShare = ANERuntime.minANEShare
    }

    private let url: URL
    private var model: MLModel?
    private(set) public var placement: Placement?
    private var inputName: String?
    private var inputShape: [Int]?

    public init(modelURL: URL) { self.url = modelURL }

    public var isLoaded: Bool { model != nil }

    @discardableResult
    public func load() async throws -> TimeInterval {
        if model != nil { return 0 }
        let t0 = Date()

        let config = MLModelConfiguration()
        // .cpuAndNeuralEngine rather than .all is deliberate: .all would let
        // Core ML schedule onto the GPU and silently reintroduce exactly the
        // contention this runtime exists to avoid.
        config.computeUnits = .cpuAndNeuralEngine

        // Compiling first is required for MLComputePlan, which cannot read an
        // .mlpackage.
        let compiled = url.pathExtension == "mlmodelc"
            ? url
            : try await MLModel.compileModel(at: url)

        let loaded: MLModel
        do {
            loaded = try MLModel(contentsOf: compiled, configuration: config)
        } catch {
            throw Failure.load(String(describing: error))
        }

        let placement = try await verifyPlacement(compiled: compiled)
        guard placement.aneShare >= Self.minANEShare else {
            throw Failure.notANEResident(share: placement.aneShare, ops: placement.totalOps)
        }

        let desc = loaded.modelDescription.inputDescriptionsByName
        guard let (name, feature) = desc.first,
              let constraint = feature.multiArrayConstraint else {
            throw Failure.load("model has no multi-array input")
        }

        self.model = loaded
        self.placement = placement
        self.inputName = name
        self.inputShape = constraint.shape.map(\.intValue)

        // First prediction pays compilation; do it here so it is attributed to
        // load rather than to the first work item.
        _ = try? run(item: [:])
        return Date().timeIntervalSince(t0)
    }

    /// Report which compute device each operation actually landed on.
    private func verifyPlacement(compiled: URL) async throws -> Placement {
        // Built here rather than passed in: MLModelConfiguration is not Sendable
        // and Swift 6 will not let it cross the async boundary. It must match
        // the configuration the model is actually loaded with, or the plan
        // describes a placement that is not the one being used.
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: config)
        guard case let .program(program) = plan.modelStructure,
              let function = program.functions["main"] else {
            throw Failure.noComputePlan
        }

        var counts: [String: Int] = [:]
        var total = 0
        for operation in function.block.operations {
            // Const ops are metadata, not compute; counting them dilutes the
            // signal we actually care about.
            if operation.operatorName == "const" { continue }
            guard let usage = plan.deviceUsage(for: operation) else { continue }
            // MLComputeDevice is an enum, so type(of:) reports the same name for
            // every case and every op looked like "not the ANE". The verifier
            // failed closed and refused a model that was in fact 100% resident,
            // which is the right direction to be wrong in but still wrong.
            let device: String
            switch usage.preferred {
            case .cpu: device = "CPU"
            case .gpu: device = "GPU"
            case .neuralEngine: device = "NeuralEngine"
            @unknown default: device = "unknown"
            }
            counts[device, default: 0] += 1
            total += 1
        }
        guard total > 0 else { throw Failure.noComputePlan }

        let ane = counts.filter { $0.key.contains("NeuralEngine") }.values.reduce(0, +)
        return Placement(devices: counts, totalOps: total,
                         aneShare: Double(ane) / Double(total))
    }

    public func unload() -> TimeInterval {
        let t0 = Date()
        model = nil
        placement = nil
        return Date().timeIntervalSince(t0)
    }

    /// Process one work item.
    ///
    /// The payload shape is fixed by the model, so an item supplies data rather
    /// than a prompt. Text is hashed into the input tensor as a stand-in until a
    /// real embedding model is converted; swapping that in changes only this
    /// method.
    @discardableResult
    public func run(item: [String: Any]) throws -> [String: Any] {
        guard let model, let inputName, let inputShape else {
            throw Failure.load("not loaded")
        }
        let array = try MLMultiArray(shape: inputShape.map(NSNumber.init(value:)),
                                     dataType: .float32)
        let text = (item["prompt"] as? String) ?? (item["text"] as? String) ?? ""
        var seed = UInt64(bitPattern: Int64(text.hashValue))
        for i in 0..<array.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            array[i] = NSNumber(value: Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max))
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: array])
        let out = try model.prediction(from: provider)
        return ["id": item["id"] ?? NSNull(), "keys": out.featureNames.sorted()]
    }
}
