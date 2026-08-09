import DaiAgent
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// MLX runtime for `generate` work.
///
/// E4 measured model load at 1.4s warm and 2.8s cold for a 14B, roughly 20x
/// cheaper than the plan assumed, because unified memory has no host-to-device
/// transfer step. That is what makes preemption affordable and why this releases
/// eagerly rather than holding a model against a possible return.
public actor MLXRuntime {
    private let modelId: String
    private var container: ModelContainer?

    public init(modelId: String) { self.modelId = modelId }

    public var isLoaded: Bool { container != nil }
    public var name: String { modelId }

    @discardableResult
    public func load() async throws -> TimeInterval {
        if container != nil { return 0 }
        let t0 = Date()
        container = try await LLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: modelId))
        return Date().timeIntervalSince(t0)
    }

    public func unload() -> TimeInterval {
        let t0 = Date()
        container = nil
        // Releasing the container is not enough on its own: MLX keeps a buffer
        // cache that would otherwise stay resident on a machine whose owner has
        // just come back.
        MLX.GPU.clearCache()
        return Date().timeIntervalSince(t0)
    }

    public var residentGb: Double {
        Double(MLX.GPU.snapshot().activeMemory) / 1_073_741_824
    }

    /// Generate a completion.
    ///
    /// The streaming overload is used rather than the batch one because it
    /// yields per token, which is what a mid-generation stop will need: a single
    /// request has no seam to yield at, and `maxCompletionTokens` bounds the
    /// worst case only because the loop can be cut short here.
    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        guard let container else { throw Failure.notLoaded }
        return try await container.perform { context in
            let input = try await context.processor.prepare(
                input: .init(messages: [["role": "user", "content": prompt]]))
            // Greedy. Determinism matters for batch work, where the same item
            // dispatched to a different node after a requeue should not produce
            // a different answer.
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
                context: context)

            var text = ""
            for await item in stream {
                if case let .chunk(chunk) = item { text += chunk }
            }
            return text
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notLoaded
        public var description: String { "MLX runtime not loaded" }
    }
}
