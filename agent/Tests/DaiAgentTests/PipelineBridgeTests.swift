import Foundation
import MLX
import MLXLLM
import NIOPosix
import Testing
@testable import DaiAgent
@testable import DaiWorker

/// Tensors surviving the trip between machines, and the split itself.
///
/// This is the layer where a mistake is silent: whatever comes out is fed
/// straight into the second half of a model, so a wrong shape or a misread
/// element type produces a confident answer from the wrong numbers rather than
/// an error anybody sees.
/// Whether MLX can actually run here.
///
/// SwiftPM cannot compile MLX's Metal shaders, so `swift test` has no shader
/// library and anything creating an MLXArray aborts in C++ rather than throwing.
/// These tests are therefore skipped under SwiftPM and run under xcodebuild,
/// which does produce the bundle. Detected by looking for it rather than by
/// trying a call, because there would be nothing to catch.
///
/// Not private: the split's failure tests need the same gate, and two copies of
/// this would drift the moment one of them was fixed.
let metalAvailable: Bool = {
    // Searched across the loaded bundles rather than next to argv[0]. Under
    // xctest argv[0] is the runner, not the build products directory, so the
    // obvious check skipped these tests everywhere including where they should
    // run - five tests that looked like coverage and never executed once.
    var candidates: [URL] = [Bundle.main.bundleURL.deletingLastPathComponent()]
    candidates += Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
    candidates.append(URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent())
    return candidates.contains {
        FileManager.default.fileExists(
            atPath: $0.appendingPathComponent("mlx-swift_Cmlx.bundle").path)
    }
}()

struct PipelineBridgeTests {

    @Test("a hidden state survives the round trip exactly", .enabled(if: metalAvailable))
    func roundTripsExactly() throws {
        let original = MLXArray(converting: (0..<64).map { Double($0) * 0.5 }, [1, 8, 8])
            .asType(.float32)
        let frame = try TensorBridge.encode(original)
        #expect(frame.shape == [1, 8, 8])
        #expect(frame.isConsistent)

        let back = try TensorBridge.decode(frame, expecting: original)
        #expect(back.shape == original.shape)
        // Compared element by element, not by shape. A tensor of the right size
        // holding the wrong numbers is exactly the failure that stays silent.
        #expect(allClose(back, original).item(Bool.self))
    }

    @Test("carries the element types a hidden state actually uses", .enabled(if: metalAvailable))
    func carriesRealDTypes() throws {
        for dtype in [DType.float32, .float16, .bfloat16] {
            let original = MLXArray(converting: [1.0, 2.0, 3.0, 4.0], [2, 2]).asType(dtype)
            let back = try TensorBridge.decode(try TensorBridge.encode(original),
                                               expecting: original)
            #expect(allClose(back, original).item(Bool.self), "\(dtype) did not survive")
        }
    }

    @Test("refuses a tensor of the wrong shape", .enabled(if: metalAvailable))
    func refusesWrongShape() throws {
        // What a desynchronised pipeline looks like: the other machine sent a
        // hidden state for a different position in the sequence.
        let sent = try TensorBridge.encode(MLXArray.zeros([1, 4], type: Float32.self))
        let expected = MLXArray.zeros([1, 8], type: Float32.self)
        #expect(throws: TensorBridge.Failure.self) {
            try TensorBridge.decode(sent, expecting: expected)
        }
    }

    @Test("refuses a tensor of the wrong element type", .enabled(if: metalAvailable))
    func refusesWrongDType() throws {
        // Reading float16 bytes as float32 yields numbers, not an error, and
        // the model would carry on with them.
        let sent = try TensorBridge.encode(MLXArray.zeros([2, 2], type: Float16.self))
        let expected = MLXArray.zeros([2, 2], type: Float32.self)
        #expect(throws: TensorBridge.Failure.self) {
            try TensorBridge.decode(sent, expecting: expected)
        }
    }

    @Test("a realistic hidden state is small enough that the link never matters", .enabled(if: metalAvailable))
    func realisticSize() throws {
        // One token of a 72B model: hidden dimension 8192 in bfloat16.
        let h = MLXArray.zeros([1, 1, 8192], type: Float16.self)
        let frame = try TensorBridge.encode(h)
        #expect(frame.bytes.count == 16_384)
    }
}

/// Dividing a model's layers between machines.
struct PipelineSplitTests {
    @Test("two machines each take half")
    func halves() {
        let a = PipelineSplit(rank: 0, size: 2, layerCount: 80)
        let b = PipelineSplit(rank: 1, size: 2, layerCount: 80)
        #expect(b.startIndex == 0 && b.endIndex == 40)
        #expect(a.startIndex == 40 && a.endIndex == 80)
    }

    @Test("rank zero holds the last layers, and therefore the output")
    func rankZeroIsLast() {
        // Assigned in reverse on purpose: rank 0 owns the final norm and head,
        // so it is the machine that produces a token and the one a scheduler
        // addresses.
        let last = PipelineSplit(rank: 0, size: 2, layerCount: 80)
        #expect(last.isLast)
        #expect(!last.isFirst)
        #expect(PipelineSplit(rank: 1, size: 2, layerCount: 80).isFirst)
    }

    @Test("every layer is owned exactly once, for every division")
    func coversEveryLayer() {
        // Exhaustive rather than a handful of cases, because this already went
        // wrong once: the obvious formula loses a layer whenever the count does
        // not divide evenly, and 80 over 3 drops layer 26. A skipped layer does
        // not fail. The model computes without it and answers fluently from the
        // wrong network, on a machine nobody is looking at.
        for count in 1...100 {
            for size in 1...8 where size <= count {
                var seen: [Int] = []
                for rank in 0..<size {
                    let s = PipelineSplit(rank: rank, size: size, layerCount: count)
                    seen += Array(s.startIndex..<s.endIndex)
                }
                #expect(seen.sorted() == Array(0..<count),
                        "\(count) layers over \(size) machines left a gap or an overlap")
            }
        }
    }

    @Test("the division is balanced, for every division")
    func balancedEverywhere() {
        // A pipeline waits for its slowest link every token, so an extra layer
        // on one machine is a tax on every token rather than a one-off. The
        // spread must never exceed one layer.
        for count in 1...100 {
            for size in 1...8 where size <= count {
                let sizes = (0..<size).map { rank -> Int in
                    let s = PipelineSplit(rank: rank, size: size, layerCount: count)
                    return s.endIndex - s.startIndex
                }
                #expect(sizes.max()! - sizes.min()! <= 1,
                        "\(count) over \(size) split as \(sizes)")
                #expect(sizes.reduce(0, +) == count)
                #expect(!sizes.contains(0), "\(count) over \(size) left a machine with nothing")
            }
        }
    }

    @Test("awkward numbers divide correctly")
    func awkwardNumbers() {
        // The cases somebody will actually hit: a prime layer count, three
        // machines, and models whose depth is nothing like a round number.
        // Qwen2.5-72B has 80 layers, Llama-3.3-70B has 80, a 32B has 64.
        for (count, size, expected) in [
            (80, 3, [27, 27, 26]),
            (79, 3, [27, 26, 26]),
            (7, 3, [3, 2, 2]),
            (13, 4, [4, 3, 3, 3]),
            (64, 3, [22, 21, 21]),
            (1, 1, [1]),
        ] {
            let sizes = (0..<size).map { rank -> Int in
                let s = PipelineSplit(rank: rank, size: size, layerCount: count)
                return s.endIndex - s.startIndex
            }
            #expect(sizes == expected, "\(count) over \(size) gave \(sizes)")
        }
    }

    @Test("the first layers and the output head land on different machines")
    func endsAreDistinct() {
        // Rank 0 owns the output head; the highest rank owns the embeddings.
        // If a division ever made one machine both, the hidden state would be
        // sent to nobody.
        for count in 2...100 {
            for size in 2...8 where size <= count {
                let first = PipelineSplit(rank: size - 1, size: size, layerCount: count)
                let last = PipelineSplit(rank: 0, size: size, layerCount: count)
                #expect(first.isFirst && !first.isLast)
                #expect(last.isLast && !last.isFirst)
                #expect(first.startIndex == 0, "\(count)/\(size): first slice does not start at 0")
                #expect(last.endIndex == count, "\(count)/\(size): last slice does not end at \(count)")
            }
        }
    }

    @Test("one machine holds the whole model")
    func wholeModel() {
        let s = PipelineSplit.whole(layerCount: 80)
        #expect(s.startIndex == 0 && s.endIndex == 80)
        #expect(s.isFirst && s.isLast)
    }
}

/// The way a model actually calls the link: synchronously, from inside an actor.
///
/// Every other test here drives `PipelineChannel` with `await` from a test
/// function. Nothing exercised the shape the split really has - a synchronous
/// forward pass on an actor, blocking a thread on a semaphore while an
/// unstructured task does the asynchronous work underneath. That seam is where
/// a fleet split stopped: two machines connected over a real socket and then
/// exchanged nothing at all, twice, with no error on either side.
struct SyncBridgeTests {
    /// Stands in for the model: an actor that hands a tensor over and waits,
    /// exactly as `SplitRunner` does inside a forward pass.
    actor Compute {
        private let transport: ChannelPipelineTransport

        init(channel: PipelineChannel, timeout: TimeInterval = 10) {
            transport = ChannelPipelineTransport(channel: channel, timeout: timeout)
        }

        /// Plain numbers in and out. An MLXArray is not Sendable, so a test
        /// that handed one to an actor would be testing something the split
        /// never does: the tensor is built where it is used, on the machine
        /// that owns those layers.
        func handOver(values: [Float], shape: [Int]) throws {
            try transport.send(MLXArray(values).reshaped(shape), to: 0)
        }

        func takeOver(shape: [Int]) throws -> [Float] {
            let expected = MLXArray.zeros(shape, type: Float32.self)
            return try transport.receive(like: expected, from: 1).asArray(Float.self)
        }
    }

    @Test("a hidden state crosses when the model calls the link from an actor",
          .enabled(if: metalAvailable))
    func crossesFromInsideAnActor() async throws {
        let fx = try PipelineChannelSocketTests().fixture()
        defer { try? FileManager.default.removeItem(at: fx.dir) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let later = PipelineChannel(group: group)
        let earlier = PipelineChannel(group: group)
        let port = try await later.listen(port: 0, tls: fx.serverContext)
        try await earlier.connect(host: "127.0.0.1", port: port,
                                  tls: fx.clientContext, serverName: "localhost")

        let sender = Compute(channel: earlier)
        let receiver = Compute(channel: later)
        let values = (0..<32).map { Float($0) * 0.25 }

        // Both halves blocking at once, which is the real arrangement: neither
        // machine has anything else to do until the tensor has crossed, and
        // each is inside an actor while it waits.
        async let arrived = receiver.takeOver(shape: [1, 8, 4])
        try await sender.handOver(values: values, shape: [1, 8, 4])
        let got = try await arrived

        #expect(got == values)

        await earlier.close()
        await later.close()
        try? await group.shutdownGracefully()
    }
}

/// What a split request says it cost.
///
/// A split under-reported itself: `SplitRunner` returned only the tokens it
/// produced, so a caller reading usage saw "0 in" and could not compare a split
/// request with a single-machine one, or bill for either.
struct SplitUsageTests {
    static func done(isHead: Bool, prompt: Int, produced: Int,
                     totalLayers: Int = 48, size: Int = 2) -> SplitRunner.Completed {
        SplitRunner.Completed(
            outcome: SplitRunner.Outcome(text: isHead ? "hello" : "", tokens: produced,
                                         promptTokens: prompt, promptSeconds: 0.1, reusedTokens: 0,
                                         decodeSeconds: 0.2, residentGb: 4.5),
            isHead: isHead, layers: 0..<24, totalLayers: totalLayers, size: size)
    }

    @Test("the rank holding the head reports both counts")
    func headReportsBoth() {
        let reported = Self.done(isHead: true, prompt: 935, produced: 205).reported
        #expect(reported.prompt == 935)
        #expect(reported.completion == 205)
    }

    @Test("every other rank reports nothing")
    func othersReportNothing() {
        // Not because their work did not happen - they ran half the layers - but
        // because the control plane answers from rank 0. Two ranks reporting the
        // same prompt is the shape of a bill that says a request cost twice what
        // it did.
        let reported = Self.done(isHead: false, prompt: 935, produced: 205).reported
        #expect(reported.prompt == 0)
        #expect(reported.completion == 0)
    }
}
