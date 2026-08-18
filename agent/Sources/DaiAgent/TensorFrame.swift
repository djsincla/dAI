import Foundation

/// Moving a tensor between two machines.
///
/// Pipeline parallelism needs exactly two operations, send a tensor and receive
/// one, and the payload is small: a hidden state is a few kilobytes per token.
/// What it needs instead of throughput is to be exactly right, because the
/// receiving machine will feed whatever arrives straight into the next layers
/// of a model and produce confident nonsense from a tensor that was subtly
/// wrong.
///
/// MLX ships its own distributed transport and mlx-swift does not compile it:
/// the package excludes `ring.cpp` and builds a stub instead. Rather than fork a
/// C++ build to get it back, this carries tensors over a channel the fleet
/// already has certificates for. The payload is tiny and we already know which
/// machines are up, which is most of what a transport layer is for.
///
/// Length-prefixed, self-describing, and validated on arrival. TCP hands over
/// arbitrary fragments, so the decoder is a state machine rather than a parser
/// that assumes a whole frame is present.
public struct TensorFrame: Sendable, Equatable {
    /// The element types a hidden state is ever carried in.
    public enum DType: UInt8, Sendable, CaseIterable {
        case float32 = 1
        case float16 = 2
        case bfloat16 = 3
        case int32 = 4
        case uint32 = 5
        case int8 = 6
        case uint8 = 7

        public var byteWidth: Int {
            switch self {
            case .float32, .int32, .uint32: return 4
            case .float16, .bfloat16: return 2
            case .int8, .uint8: return 1
            }
        }
    }

    public let shape: [Int]
    public let dtype: DType
    public let bytes: Data

    public init(shape: [Int], dtype: DType, bytes: Data) {
        self.shape = shape
        self.dtype = dtype
        self.bytes = bytes
    }

    /// Elements implied by the shape.
    public var elementCount: Int { shape.reduce(1, *) }

    /// Whether the payload is the size the shape and type require.
    ///
    /// The check that matters. A frame whose length disagrees with its shape has
    /// been truncated or is not the frame it claims to be, and feeding it into a
    /// model produces a plausible answer from the wrong numbers rather than an
    /// error anybody would notice.
    public var isConsistent: Bool {
        !shape.isEmpty
            && !shape.contains(where: { $0 <= 0 })
            && bytes.count == elementCount * dtype.byteWidth
    }
}

/// Wire format.
///
/// ```
/// magic   4   "DAIT"
/// version 1
/// dtype   1
/// rank    1
/// pad     1
/// dims    4 * rank   (little endian uint32)
/// length  4          (little endian uint32, payload bytes)
/// payload length
/// ```
public enum TensorCodec {
    static let magic: [UInt8] = [0x44, 0x41, 0x49, 0x54]  // DAIT
    static let version: UInt8 = 1

    /// Refuses anything implausible rather than trusting a length off the wire.
    ///
    /// A corrupt or hostile header would otherwise have the receiver allocate
    /// whatever number it read.
    public static let maxRank = 8

    /// The largest hidden state this link will carry, in bytes.
    ///
    /// This was 64 MB, described as "far above any real hidden state". That
    /// stopped being true the first time somebody asked a split a long question:
    /// prefill sends the whole prompt's hidden state as one frame, so the size
    /// is `tokens x hidden x width`, and on the 32B - hidden 5120, bfloat16 -
    /// that is **10,240 bytes per token**. 64 MB is therefore a limit of about
    /// 6,550 tokens, which is a fifth of that model's context window and well
    /// inside the long-document work a split exists to do.
    ///
    /// Nothing said so. The refusal arrived as "payload of 121026560 bytes is
    /// out of range" from the frame decoder, the link was torn down, and the
    /// gang reported a transport fault - so a context limit nobody had chosen
    /// read as a broken pipeline.
    ///
    /// Derived rather than picked: 32,768 tokens - the 32B's full context - at
    /// 10,240 bytes each is 335 MB, and 512 MB clears that with room for a wider
    /// hidden dimension. It remains a bound on what a corrupt length can make
    /// this process allocate, which is what it is for.
    ///
    /// The honest limit of this approach is that one frame must be held whole at
    /// both ends. Chunking prefill across several frames would remove the
    /// ceiling rather than move it, at the cost of a wire-format version and
    /// reassembly on the receiver; worth doing if a model ever needs more than
    /// this, and not worth doing before that.
    public static let maxPayload = 512 * 1024 * 1024

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badMagic
        case unsupportedVersion(UInt8)
        case unknownDType(UInt8)
        case implausibleRank(Int)
        case implausiblePayload(Int)
        case inconsistent(expected: Int, got: Int)

        public var description: String {
            switch self {
            case .badMagic: return "not a tensor frame"
            case let .unsupportedVersion(v): return "tensor frame version \(v) is not supported"
            case let .unknownDType(d): return "unknown element type \(d)"
            case let .implausibleRank(r): return "rank \(r) is out of range"
            // Said in the terms somebody can act on. A hidden state is one
            // slice per token, so "121026560 bytes" is a prompt length wearing a
            // disguise - and the reader's next question is always how long a
            // prompt this link will take.
            case let .implausiblePayload(n):
                return "a hidden state of \(n / (1024 * 1024)) MB is beyond this link's "
                    + "\(TensorCodec.maxPayload / (1024 * 1024)) MB limit. On a 5120-wide "
                    + "model at bfloat16 that is roughly "
                    + "\(TensorCodec.maxPayload / 10_240) tokens of prompt"
            case let .inconsistent(expected, got):
                return "shape needs \(expected) bytes, frame carries \(got)"
            }
        }
    }

    public static func encode(_ frame: TensorFrame) -> Data {
        var out = Data()
        out.append(contentsOf: magic)
        out.append(version)
        out.append(frame.dtype.rawValue)
        out.append(UInt8(frame.shape.count))
        out.append(0)  // reserved, keeps the header aligned
        for dim in frame.shape { out.append(le32(UInt32(dim))) }
        out.append(le32(UInt32(frame.bytes.count)))
        out.append(frame.bytes)
        return out
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
              UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }
}

/// Turns a stream of arbitrary fragments into whole frames.
///
/// A decoder written as `parse(data)` works in a test and fails on a real
/// socket, because TCP splits wherever it likes: a header can arrive in three
/// pieces and two frames can arrive in one. This buffers until a frame is whole
/// and hands back however many completed, which may be none.
public struct TensorFrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    /// Bytes held so far, exposed so a caller can notice a peer that is sending
    /// a header and then going quiet.
    public var pending: Int { buffer.count }

    /// Feed the decoder, take whatever frames are complete.
    public mutating func push(_ incoming: Data) throws -> [TensorFrame] {
        buffer.append(incoming)
        var frames: [TensorFrame] = []
        while let frame = try takeOne() { frames.append(frame) }
        return frames
    }

    private mutating func takeOne() throws -> TensorFrame? {
        // Enough for magic, version, dtype, rank, pad.
        guard buffer.count >= 8 else { return nil }

        let head = [UInt8](buffer.prefix(8))
        guard Array(head[0..<4]) == TensorCodec.magic else { throw TensorCodec.Failure.badMagic }
        guard head[4] == TensorCodec.version else {
            throw TensorCodec.Failure.unsupportedVersion(head[4])
        }
        guard let dtype = TensorFrame.DType(rawValue: head[5]) else {
            throw TensorCodec.Failure.unknownDType(head[5])
        }
        let rank = Int(head[6])
        guard rank > 0, rank <= TensorCodec.maxRank else {
            throw TensorCodec.Failure.implausibleRank(rank)
        }

        let headerSize = 8 + rank * 4 + 4
        guard buffer.count >= headerSize else { return nil }

        var shape: [Int] = []
        shape.reserveCapacity(rank)
        for i in 0..<rank {
            shape.append(Int(readLE32(at: 8 + i * 4)))
        }
        let length = Int(readLE32(at: 8 + rank * 4))
        guard length >= 0, length <= TensorCodec.maxPayload else {
            throw TensorCodec.Failure.implausiblePayload(length)
        }

        // Not yet whole. Nothing is consumed, so the next fragment resumes here.
        guard buffer.count >= headerSize + length else { return nil }

        let payload = buffer.subdata(in: (buffer.startIndex + headerSize)
                                        ..< (buffer.startIndex + headerSize + length))
        buffer.removeFirst(headerSize + length)

        let frame = TensorFrame(shape: shape, dtype: dtype, bytes: payload)
        guard frame.isConsistent else {
            throw TensorCodec.Failure.inconsistent(
                expected: frame.elementCount * dtype.byteWidth, got: payload.count)
        }
        return frame
    }

    private func readLE32(at offset: Int) -> UInt32 {
        let i = buffer.startIndex + offset
        return UInt32(buffer[i])
            | UInt32(buffer[i + 1]) << 8
            | UInt32(buffer[i + 2]) << 16
            | UInt32(buffer[i + 3]) << 24
    }
}
