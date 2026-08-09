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
    /// Allocated and filled once, then reused.
    ///
    /// This model is E5's synthetic load generator, whose input is 1x64x256x256
    /// - 4.19 million floats, 16 MB per item. Regenerating that per item cost
    /// 534ms against 7.8ms of actual inference, so 98.5% of the agent's time
    /// went into fabricating input whose contents the model does not care
    /// about, and it was reported as embedding throughput.
    ///
    /// A real embedding model takes a token sequence, which is a few hundred
    /// integers, and none of this applies. The buffer is reused here so the
    /// measured rate reflects the ANE rather than a random number generator;
    /// when a real model replaces this, the per-item fill comes back and is
    /// cheap.
    private var input: MLMultiArray?

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
        let shape = constraint.shape.map(\.intValue)
        self.inputShape = shape

        let buffer = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        buffer.withUnsafeMutableBytes { raw, _ in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<floats.count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                floats[i] = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
            }
        }
        self.input = buffer

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

    /// Where the time actually goes on one item: preparing the input, and the
    /// prediction itself.
    ///
    /// Worth having as a first-class thing rather than a temporary printf. The
    /// first version of this runtime reported 0.66 items/s and looked like slow
    /// inference; almost all of it was tensor preparation, and nothing in the
    /// worker's own numbers could have told them apart.
    public func benchmark(iterations: Int = 50) throws -> (shape: [Int], fill: TimeInterval,
                                                           predict: TimeInterval) {
        guard let model, let inputName, let inputShape else {
            throw Failure.load("not loaded")
        }
        var fill: TimeInterval = 0
        var predict: TimeInterval = 0
        for i in 0..<iterations {
            var t = Date()
            let array = try MLMultiArray(shape: inputShape.map(NSNumber.init(value:)),
                                         dataType: .float32)
            var seed = UInt64(i)
            array.withUnsafeMutableBytes { raw, _ in
                let buffer = raw.bindMemory(to: Float.self)
                for j in 0..<buffer.count {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    buffer[j] = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
                }
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: array])
            fill += Date().timeIntervalSince(t)

            t = Date()
            _ = try model.prediction(from: provider)
            predict += Date().timeIntervalSince(t)
        }
        return (inputShape, fill / Double(iterations), predict / Double(iterations))
    }

    public func unload() -> TimeInterval {
        let t0 = Date()
        model = nil
        placement = nil
        input = nil
        return Date().timeIntervalSince(t0)
    }

    /// Process one work item.
    ///
    /// The payload shape is fixed by the model, so an item supplies data rather
    /// than a prompt. Text is hashed into the input tensor as a stand-in until a
    /// real embedding model is converted; swapping that in changes only this
    /// method.
    /// Overload taking the wire type, so callers do not have to flatten a
    /// JSONValue into an untyped dictionary just to hand it back again.
    @discardableResult
    public func run(item: WorkItem) throws -> WorkItem {
        let text = item["prompt"]?.stringValue ?? item["text"]?.stringValue ?? ""
        let out = try run(item: ["prompt": text, "id": item["id"]?.intValue as Any])
        return .object(["id": item["id"] ?? .null,
                        "keys": .array((out["keys"] as? [String] ?? []).map(JSONValue.string))])
    }

    @discardableResult
    public func run(item: [String: Any]) throws -> [String: Any] {
        guard let model, let inputName, let inputShape else {
            throw Failure.load("not loaded")
        }
        guard let array = input else { throw Failure.load("input buffer missing") }
        let text = (item["prompt"] as? String) ?? (item["text"] as? String) ?? ""
        // Only the leading window varies per item. The model's output is not
        // used for anything yet, and rewriting all 16 MB to change a result
        // nobody reads costs 68x what the inference does.
        array.withUnsafeMutableBytes { raw, _ in
            let buffer = raw.bindMemory(to: Float.self)
            var seed = UInt64(bitPattern: Int64(text.hashValue))
            for i in 0..<min(1024, buffer.count) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                buffer[i] = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: array])
        let out = try model.prediction(from: provider)
        return ["id": item["id"] ?? NSNull(), "keys": out.featureNames.sorted()]
    }
}
