import Foundation
import MLX
import MLXLLM
import Testing
@testable import DaiWorker

/// What a split does when the link between the machines fails.
///
/// This is the bug a real gang found: both pipeline failures were `fatalError`,
/// so a peer whose handshake never completed killed the daemon on both machines
/// - taking unrelated harvest work with it, telling the control plane nothing,
/// and leaving the surviving rank to time out on its own. launchd restarting
/// them fifteen seconds later is the only reason the fleet still looked healthy.
///
/// A forward pass cannot throw, so the failure is latched and the caller checks.
/// These tests are the reason that latch can be trusted: they run a real model
/// forward with a transport that refuses, and assert that the process is still
/// here to assert anything at all.
struct PipelineFaultTests {
    /// Small enough to build and run in milliseconds, real enough that it is
    /// the shipped forward pass being exercised rather than a stand-in.
    static func tinyModel(layers: Int = 2) throws -> Qwen2Model {
        let json = """
        {"hidden_size": 8, "num_hidden_layers": \(layers), "intermediate_size": 16,
         "num_attention_heads": 2, "rms_norm_eps": 1e-5, "vocab_size": 32,
         "num_key_value_heads": 1}
        """
        let config = try JSONDecoder().decode(Qwen2Configuration.self,
                                              from: Data(json.utf8))
        return Qwen2Model(config)
    }

    /// A link that is down in both directions.
    final class Broken: PipelineTransport, @unchecked Sendable {
        struct Down: Error {}
        func send(_ x: MLXArray, to rank: Int) throws { throw Down() }
        func receive(like: MLXArray, from rank: Int) throws -> MLXArray { throw Down() }
    }

    @Test("a peer that cannot be reached fails the request, not the process",
          .enabled(if: metalAvailable))
    func sendFailureIsRecorded() throws {
        let model = try Self.tinyModel()
        let fault = PipelineFault()
        // Rank 1 of 2 holds the first layers, so it sends and never receives.
        model.pipeline(PipelineSplit(rank: 1, size: 2, layerCount: 2),
                       transport: Broken(), fault: fault)

        _ = model(MLXArray([Int32(1), 2, 3]).reshaped([1, -1]), cache: nil)

        let error = try #require(fault.take())
        // Names the rank, because a gang reports one line per machine and the
        // transport's own error says what happened to a socket, not to whom.
        #expect("\(error)".contains("rank 1"))
        #expect("\(error)".contains("hand its hidden state on"))
    }

    @Test("a hidden state that never arrives is not sampled anyway",
          .enabled(if: metalAvailable))
    func receiveFailureIsRecorded() throws {
        let model = try Self.tinyModel()
        let fault = PipelineFault()
        // Rank 0 holds the last layers and the head: it receives, and it is the
        // one that would otherwise sample a token from its own embeddings.
        model.pipeline(PipelineSplit(rank: 0, size: 2, layerCount: 2),
                       transport: Broken(), fault: fault)

        _ = model(MLXArray([Int32(1), 2, 3]).reshaped([1, -1]), cache: nil)

        let error = try #require(fault.take())
        #expect("\(error)".contains("rank 0"))
        #expect("\(error)".contains("never received"))
    }

    @Test("the first failure is the one reported")
    func firstFailureWins() {
        struct First: Error {}
        struct Second: Error {}
        let fault = PipelineFault()
        fault.record(First())
        fault.record(Second())
        // A send that fails because the peer went away reports the same broken
        // link twice, and only the first report says what actually happened.
        #expect(fault.take() is First)
    }

    @Test("a fault that has been handled is not handed over twice")
    func takeClears() {
        struct Once: Error {}
        let fault = PipelineFault()
        fault.record(Once())
        #expect(fault.occurred)
        _ = fault.take()
        #expect(!fault.occurred)
        #expect(fault.take() == nil)
    }
}
