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

/// Wire format, version 2.
///
/// ```
/// magic   4   "DAIT"
/// version 1
/// dtype   1
/// rank    1
/// pad     1
/// dims    4 * rank   (little endian uint32)
/// length  4          (little endian uint32, THIS chunk's payload bytes)
/// part    4          (little endian uint32, 0-based)
/// parts   4          (little endian uint32, total chunks in this tensor)
/// payload length
/// ```
///
/// **Every frame is a chunk.** A tensor small enough to travel whole is part 0
/// of 1, so there is one path rather than two and the common case is not a
/// special case.
///
/// Version 1 sent each tensor as a single frame, which made the transport a
/// limit on the model: prefill sends the whole prompt's hidden state at once, so
/// the frame is `tokens x hidden x width` - 10,240 bytes per token on the 32B -
/// and any cap on a frame was a cap on how long a question a split would answer.
/// It was 64 MB, or about 6,550 tokens, a fifth of that model's context. Raising
/// it moved the wall; chunking removes it.
///
/// Both ranks of a gang always run the same build - `gangFor` refuses a gang
/// whose members report different agent fingerprints - so this needs no
/// negotiation and no reading of version 1.
public enum TensorCodec {
    static let magic: [UInt8] = [0x44, 0x41, 0x49, 0x54]  // DAIT
    static let version: UInt8 = 2

    /// Refuses anything implausible rather than trusting a length off the wire.
    ///
    /// A corrupt or hostile header would otherwise have the receiver allocate
    /// whatever number it read.
    public static let maxRank = 8

    /// The largest single frame, and therefore the largest allocation a length
    /// off the wire can ask for.
    ///
    /// Small on purpose now that tensors are chunked. This is the number that
    /// protects the receiver from a corrupt or hostile header; it is no longer
    /// also a limit on how long a prompt a split will answer, which is what it
    /// silently was when a whole hidden state had to fit inside it.
    public static let maxPayload = 8 * 1024 * 1024

    /// How much payload the encoder puts in one chunk.
    ///
    /// Comfortably inside `maxPayload`, and large enough that a full context is
    /// a few dozen frames rather than thousands: at 8 MB a 335 MB hidden state
    /// is 42 chunks.
    public static let chunkBytes = 8 * 1024 * 1024

    /// The largest tensor the decoder will reassemble.
    ///
    /// Chunking bounds each allocation but not the total, so without this a
    /// sender could stream chunks until the receiver ran out of memory. Derived
    /// like the old frame cap was, but from a figure that is no longer in the
    /// way: 100,000 tokens at 10,240 bytes is about 1 GB, which is well past any
    /// context window this fleet runs and still an amount a machine can hold
    /// beside the model.
    public static let maxTensorBytes = 1024 * 1024 * 1024

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badMagic
        case unsupportedVersion(UInt8)
        case unknownDType(UInt8)
        case implausibleRank(Int)
        case implausiblePayload(Int)
        case inconsistent(expected: Int, got: Int)
        case tensorTooLarge(Int)
        case chunksOutOfOrder(expected: Int, got: Int)

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
            // A chunk this large is a corrupt header rather than a long prompt.
            // Prompt length is bounded by tensorTooLarge now, and says so there.
            case let .implausiblePayload(n):
                return "a single frame claiming \(n) bytes is not one this link sends; "
                    + "chunks are at most \(TensorCodec.chunkBytes / (1024 * 1024)) MB"
            case let .inconsistent(expected, got):
                return "shape needs \(expected) bytes, frame carries \(got)"
            // The limit somebody can actually hit, so it is stated in the terms
            // they hit it in. A hidden state is one slice per token.
            case let .tensorTooLarge(n):
                return "a hidden state of \(n / (1024 * 1024)) MB is beyond this link's "
                    + "\(TensorCodec.maxTensorBytes / (1024 * 1024)) MB limit. On a "
                    + "5120-wide model at bfloat16 that is roughly "
                    + "\(TensorCodec.maxTensorBytes / 10_240) tokens of prompt"
            case let .chunksOutOfOrder(expected, got):
                return "expected chunk \(expected) of this tensor and got \(got); "
                    + "the stream is not one this decoder can reassemble"
            }
        }
    }

    /// One tensor, as one or more chunk frames back to back.
    ///
    /// The caller sends the result as a single write; the decoder puts it back
    /// together. A tensor that fits in one chunk is part 0 of 1, which is the
    /// same path rather than a shortcut around it.
    public static func encode(_ frame: TensorFrame) -> Data {
        let payload = frame.bytes
        // An empty payload is still one chunk. Zero chunks would encode a tensor
        // that never arrives, and the receiver would wait for it.
        let parts = max(1, (payload.count + chunkBytes - 1) / chunkBytes)

        var out = Data()
        out.reserveCapacity(payload.count + parts * 32)
        for part in 0 ..< parts {
            let start = payload.startIndex + part * chunkBytes
            let end = min(start + chunkBytes, payload.endIndex)
            let slice = payload[start ..< end]

            out.append(contentsOf: magic)
            out.append(version)
            out.append(frame.dtype.rawValue)
            out.append(UInt8(frame.shape.count))
            out.append(0)  // reserved, keeps the header aligned
            for dim in frame.shape { out.append(le32(UInt32(dim))) }
            out.append(le32(UInt32(slice.count)))
            out.append(le32(UInt32(part)))
            out.append(le32(UInt32(parts)))
            out.append(slice)
        }
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
    /// Chunks of the tensor currently being reassembled.
    ///
    /// One tensor at a time, because one link carries one pipeline stage in
    /// order. Anything else is a stream this decoder is not meant to be reading,
    /// and it says so rather than guessing.
    private var partial = Data()
    private var expectedPart = 0
    private var expectedParts = 0

    public init() {}

    /// Bytes held so far, exposed so a caller can notice a peer that is sending
    /// a header and then going quiet.
    public var pending: Int { buffer.count }

    /// What one pass over the buffer achieved.
    ///
    /// A chunk consumed without finishing a tensor is progress and the loop has
    /// to continue; running out of bytes is not. Collapsing the two into an
    /// optional stopped the loop on the first chunk of a multi-chunk tensor and
    /// left the rest sitting in the buffer, so nothing ever arrived.
    private enum Step {
        case frame(TensorFrame)
        case consumedChunk
        case needsMoreBytes
    }

    /// Feed the decoder, take whatever frames are complete.
    public mutating func push(_ incoming: Data) throws -> [TensorFrame] {
        buffer.append(incoming)
        var frames: [TensorFrame] = []
        while true {
            switch try takeOne() {
            case let .frame(frame): frames.append(frame)
            case .consumedChunk: continue
            case .needsMoreBytes: return frames
            }
        }
    }

    private mutating func takeOne() throws -> Step {
        // Enough for magic, version, dtype, rank, pad.
        guard buffer.count >= 8 else { return .needsMoreBytes }

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

        // dims, this chunk's length, then part and parts.
        let headerSize = 8 + rank * 4 + 4 + 8
        guard buffer.count >= headerSize else { return .needsMoreBytes }

        var shape: [Int] = []
        shape.reserveCapacity(rank)
        for i in 0..<rank {
            shape.append(Int(readLE32(at: 8 + i * 4)))
        }
        let length = Int(readLE32(at: 8 + rank * 4))
        guard length >= 0, length <= TensorCodec.maxPayload else {
            throw TensorCodec.Failure.implausiblePayload(length)
        }
        let part = Int(readLE32(at: 8 + rank * 4 + 4))
        let parts = Int(readLE32(at: 8 + rank * 4 + 8))
        guard parts > 0, part >= 0, part < parts else {
            throw TensorCodec.Failure.chunksOutOfOrder(expected: expectedPart, got: part)
        }

        // Not yet whole. Nothing is consumed, so the next fragment resumes here.
        guard buffer.count >= headerSize + length else { return .needsMoreBytes }

        let payload = buffer.subdata(in: (buffer.startIndex + headerSize)
                                        ..< (buffer.startIndex + headerSize + length))
        buffer.removeFirst(headerSize + length)

        // A chunk arriving out of turn means this is not the stream it claims to
        // be. Guessing where the tensor restarts would hand the model a hidden
        // state assembled from two different ones, which is the failure this
        // whole file is careful about.
        if part == 0 {
            partial = Data()
            expectedPart = 0
            expectedParts = parts
        }
        guard part == expectedPart, parts == expectedParts else {
            partial = Data()
            expectedPart = 0
            expectedParts = 0
            throw TensorCodec.Failure.chunksOutOfOrder(expected: expectedPart, got: part)
        }

        guard partial.count + payload.count <= TensorCodec.maxTensorBytes else {
            partial = Data()
            expectedPart = 0
            expectedParts = 0
            throw TensorCodec.Failure.tensorTooLarge(partial.count + payload.count)
        }
        partial.append(payload)
        expectedPart += 1

        // Still collecting: this is progress, not a shortage of bytes, and the
        // loop above has to come back for the next chunk. Reporting it as a
        // shortage stopped the loop on the first chunk and left the rest of
        // the tensor sitting in the buffer, so nothing ever arrived.
        guard expectedPart == expectedParts else { return .consumedChunk }

        let whole = partial
        partial = Data()
        expectedPart = 0
        expectedParts = 0

        let frame = TensorFrame(shape: shape, dtype: dtype, bytes: whole)
        guard frame.isConsistent else {
            throw TensorCodec.Failure.inconsistent(
                expected: frame.elementCount * dtype.byteWidth, got: whole.count)
        }
        return .frame(frame)
    }

    private func readLE32(at offset: Int) -> UInt32 {
        let i = buffer.startIndex + offset
        return UInt32(buffer[i])
            | UInt32(buffer[i + 1]) << 8
            | UInt32(buffer[i + 2]) << 16
            | UInt32(buffer[i + 3]) << 24
    }
}
