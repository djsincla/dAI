import Foundation
import Testing
@testable import DaiAgent

/// Moving a tensor between two machines, exactly.
///
/// The receiving machine feeds whatever arrives straight into the next layers of
/// a model. A tensor that is subtly wrong does not fail: it produces a confident
/// answer from the wrong numbers, on a different machine, with nothing pointing
/// back here. So every check is about refusing bytes rather than accepting them.
struct TensorFrameTests {
    private func frame(shape: [Int] = [1, 8], dtype: TensorFrame.DType = .float16)
        -> TensorFrame {
        let count = shape.reduce(1, *) * dtype.byteWidth
        return TensorFrame(shape: shape, dtype: dtype,
                           bytes: Data((0..<count).map { UInt8($0 % 251) }))
    }

    @Test("a frame survives the round trip unchanged")
    func roundTrip() throws {
        let original = frame(shape: [1, 4096])
        var decoder = TensorFrameDecoder()
        let out = try decoder.push(TensorCodec.encode(original))
        #expect(out == [original])
    }

    @Test("survives being split at every possible byte boundary")
    func splitAnywhere() throws {
        // The test that matters. TCP hands over arbitrary fragments: a header can
        // arrive in three pieces and a payload in twenty. A decoder that assumes
        // a whole frame is present passes every other test and fails on a real
        // socket.
        let original = frame(shape: [2, 33], dtype: .float32)
        let encoded = TensorCodec.encode(original)

        for cut in 1..<encoded.count {
            var decoder = TensorFrameDecoder()
            let first = try decoder.push(encoded.prefix(cut))
            let second = try decoder.push(encoded.suffix(from: cut))
            #expect(first + second == [original], "failed when split at byte \(cut)")
        }
    }

    @Test("survives one byte at a time")
    func byteAtATime() throws {
        let original = frame(shape: [3, 5])
        let encoded = TensorCodec.encode(original)
        var decoder = TensorFrameDecoder()
        var got: [TensorFrame] = []
        for byte in encoded {
            got += try decoder.push(Data([byte]))
        }
        #expect(got == [original])
    }

    @Test("hands back several frames arriving in one fragment")
    func coalesced() throws {
        // The other half of the same problem: two sends can be delivered as one
        // read, and a decoder that returns after the first leaves the second
        // sitting in the buffer until something else happens to arrive.
        let a = frame(shape: [1, 2]), b = frame(shape: [4, 4], dtype: .float32)
        var decoder = TensorFrameDecoder()
        let out = try decoder.push(TensorCodec.encode(a) + TensorCodec.encode(b))
        #expect(out == [a, b])
    }

    @Test("holds nothing back once a frame is complete")
    func consumesExactly() throws {
        var decoder = TensorFrameDecoder()
        _ = try decoder.push(TensorCodec.encode(frame()))
        // A decoder that leaves bytes behind grows without bound over a long
        // conversation, and the leak is invisible until a machine runs out.
        #expect(decoder.pending == 0)
    }

    @Test("refuses a payload that disagrees with its shape")
    func refusesInconsistent() throws {
        // A truncated frame with an honest header. This is what a half-written
        // send looks like, and accepting it feeds a model the wrong numbers.
        var encoded = TensorCodec.encode(frame(shape: [1, 8], dtype: .float32))
        encoded.removeLast(4)
        // Rewrite the declared length so the frame looks whole but is not.
        let lengthAt = 8 + 2 * 4
        encoded[lengthAt] = UInt8(28)
        encoded[lengthAt + 1] = 0; encoded[lengthAt + 2] = 0; encoded[lengthAt + 3] = 0

        var decoder = TensorFrameDecoder()
        #expect(throws: TensorCodec.Failure.self) { try decoder.push(encoded) }
    }

    @Test("refuses bytes that are not a frame at all")
    func refusesGarbage() {
        var decoder = TensorFrameDecoder()
        #expect(throws: TensorCodec.Failure.badMagic) {
            try decoder.push(Data("hello there, not a tensor".utf8))
        }
    }

    @Test("refuses a length nobody could mean")
    func refusesAbsurdLength() {
        // Without this the receiver allocates whatever number it read off the
        // wire, which is a denial of service written in four bytes.
        var encoded = TensorCodec.encode(frame(shape: [1, 2]))
        let lengthAt = 8 + 2 * 4
        encoded[lengthAt] = 0xff; encoded[lengthAt + 1] = 0xff
        encoded[lengthAt + 2] = 0xff; encoded[lengthAt + 3] = 0x7f

        var decoder = TensorFrameDecoder()
        #expect(throws: TensorCodec.Failure.self) { try decoder.push(encoded) }
    }

    @Test("refuses a rank nobody could mean")
    func refusesAbsurdRank() {
        var encoded = TensorCodec.encode(frame())
        encoded[6] = 200
        var decoder = TensorFrameDecoder()
        #expect(throws: TensorCodec.Failure.implausibleRank(200)) {
            try decoder.push(encoded)
        }
    }

    @Test("refuses a version it does not understand")
    func refusesFutureVersion() {
        // A machine running a newer agent must not have its frames silently
        // misread by an older one during a rolling upgrade.
        var encoded = TensorCodec.encode(frame())
        encoded[4] = 99
        var decoder = TensorFrameDecoder()
        #expect(throws: TensorCodec.Failure.unsupportedVersion(99)) {
            try decoder.push(encoded)
        }
    }

    @Test("refuses an element type it cannot size")
    func refusesUnknownDType() {
        var encoded = TensorCodec.encode(frame())
        encoded[5] = 77
        var decoder = TensorFrameDecoder()
        #expect(throws: TensorCodec.Failure.unknownDType(77)) { try decoder.push(encoded) }
    }

    @Test("carries every element type a hidden state uses")
    func everyDType() throws {
        for dtype in TensorFrame.DType.allCases {
            let original = frame(shape: [2, 16], dtype: dtype)
            var decoder = TensorFrameDecoder()
            #expect(try decoder.push(TensorCodec.encode(original)) == [original],
                    "\(dtype) did not survive")
        }
    }

    @Test("carries a realistic hidden state")
    func realisticSize() throws {
        // One token of a 72B model: hidden dimension 8192 in bfloat16. The whole
        // reason bandwidth was never the constraint.
        let original = frame(shape: [1, 1, 8192], dtype: .bfloat16)
        #expect(original.bytes.count == 16_384)
        var decoder = TensorFrameDecoder()
        #expect(try decoder.push(TensorCodec.encode(original)) == [original])
    }
}

/// How long a prompt this link will carry.
///
/// The cap was 64 MB and its comment called that "far above any real hidden
/// state". Prefill sends the whole prompt's hidden state as one frame, so on the
/// 32B - hidden 5120, bfloat16 - it is 10,240 bytes per token, and 64 MB was a
/// limit of about 6,550 tokens: a fifth of that model's context, and squarely
/// inside the long-document work a split exists for.
///
/// A ~10,800 token question produced a 121 MB frame, was refused by the decoder,
/// and surfaced as a torn-down link and a gang reporting a transport fault. A
/// context limit nobody had chosen, arriving as a broken pipeline.
@Suite("what length of prompt a split link accepts")
struct HiddenStateCeilingTests {
    /// The 32B this fleet runs: hidden 5120 at bfloat16.
    static let bytesPerToken = 5120 * 2

    @Test("carries a full context window of the model this fleet runs")
    func coversFullContext() {
        // 32,768 tokens is the 32B's context. A transport that cannot carry what
        // the model can read is a limit on the product, not on the wire.
        let fullContext = 32_768 * Self.bytesPerToken
        #expect(TensorCodec.maxPayload >= fullContext,
                "a split cannot serve prompts the model itself would accept")
    }

    @Test("the prompt that broke it now fits")
    func theRealFailure() {
        // 121,026,560 bytes, measured on this fleet.
        #expect(121_026_560 <= TensorCodec.maxPayload)
    }

    @Test("still refuses a length no hidden state could have")
    func stillBounded() {
        // The cap is not decoration: it is what stops a corrupt or hostile
        // length making this process allocate whatever number it read.
        //
        // Built by encoding a real frame and overwriting its length, rather than
        // by hand-assembling a header - the first attempt guessed the offsets
        // wrong, and a test that fails to reach the check it is testing passes
        // for the wrong reason.
        let real = TensorFrame(shape: [4], dtype: .bfloat16,
                               bytes: Data(repeating: 0, count: 8))
        var wire = TensorCodec.encode(real)
        let lengthAt = wire.count - 8 - 4     // header ends with shape then length
        wire.replaceSubrange(lengthAt ..< lengthAt + 4,
                             with: [0xff, 0xff, 0xff, 0x7f])   // ~2 GB

        var decoder = TensorFrameDecoder()
        #expect(throws: (any Error).self) { _ = try decoder.push(wire) }
    }

    @Test("says how long a prompt it will take, not how many bytes it refused")
    func errorIsActionable() {
        // "payload of 121026560 bytes is out of range" is a prompt length
        // wearing a disguise, and it sent somebody looking at the network.
        let said = String(describing: TensorCodec.Failure.implausiblePayload(999_999_999))
        #expect(said.contains("tokens"), "the reader's question is how long a prompt")
        #expect(said.contains("limit"))
    }
}
