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
