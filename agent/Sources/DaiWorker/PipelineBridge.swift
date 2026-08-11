import DaiAgent
import Foundation
import MLX
import MLXLLM

/// Turning an MLX tensor into bytes and back.
///
/// The one place where a mistake is silent. Everything downstream feeds whatever
/// comes out of here straight into the second half of a model, so a wrong shape
/// or a misread element type does not fail: it produces a confident answer from
/// the wrong numbers, on a different machine, with nothing pointing back here.
public enum TensorBridge {
    public enum Failure: Error, CustomStringConvertible {
        case unsupportedDType(String)
        case shapeMismatch(expected: [Int], got: [Int])
        case dtypeMismatch(expected: String, got: String)

        public var description: String {
            switch self {
            case let .unsupportedDType(d):
                return "cannot carry element type \(d) between machines"
            case let .shapeMismatch(expected, got):
                return "expected a tensor of shape \(expected), received \(got)"
            case let .dtypeMismatch(expected, got):
                return "expected element type \(expected), received \(got)"
            }
        }
    }

    static func frameDType(_ dtype: DType) throws -> TensorFrame.DType {
        switch dtype {
        case .float32: return .float32
        case .float16: return .float16
        case .bfloat16: return .bfloat16
        case .int32: return .int32
        case .uint32: return .uint32
        case .int8: return .int8
        case .uint8: return .uint8
        default: throw Failure.unsupportedDType(String(describing: dtype))
        }
    }

    static func mlxDType(_ dtype: TensorFrame.DType) -> DType {
        switch dtype {
        case .float32: return .float32
        case .float16: return .float16
        case .bfloat16: return .bfloat16
        case .int32: return .int32
        case .uint32: return .uint32
        case .int8: return .int8
        case .uint8: return .uint8
        }
    }

    /// Flatten a tensor for the wire.
    ///
    /// Evaluated first. MLX is lazy, and serialising an array whose value has
    /// not been computed would send whatever happened to be in the buffer.
    public static func encode(_ array: MLXArray) throws -> TensorFrame {
        let dtype = try frameDType(array.dtype)
        array.eval()
        return TensorFrame(shape: array.shape, dtype: dtype, bytes: array.asData())
    }

    /// Rebuild a tensor, checking it is the one that was expected.
    ///
    /// `expected` is the tensor this machine was about to compute with, so its
    /// shape and type are what the next layers require. Checking against it
    /// turns a wrong tensor into an error here rather than a plausible answer
    /// later.
    public static func decode(_ frame: TensorFrame, expecting expected: MLXArray) throws
        -> MLXArray {
        let wanted = try frameDType(expected.dtype)
        guard frame.dtype == wanted else {
            throw Failure.dtypeMismatch(expected: String(describing: expected.dtype),
                                        got: String(describing: frame.dtype))
        }
        guard frame.shape == expected.shape else {
            throw Failure.shapeMismatch(expected: expected.shape, got: frame.shape)
        }
        return MLXArray(frame.bytes, frame.shape, dtype: mlxDType(frame.dtype))
    }
}

/// Carries hidden states over the fleet's own authenticated link.
///
/// The model library calls this synchronously, because a forward pass is
/// synchronous and a pipeline step has nothing else to do while it waits. The
/// channel underneath is asynchronous, so this blocks the calling thread on
/// purpose. That thread is a compute thread mid-token; there is no other work
/// for it.
public final class ChannelPipelineTransport: PipelineTransport, @unchecked Sendable {
    private let channel: PipelineChannel
    private let timeout: TimeInterval

    public init(channel: PipelineChannel, timeout: TimeInterval = 120) {
        self.channel = channel
        self.timeout = timeout
    }

    public func send(_ x: MLXArray, to rank: Int) throws {
        let frame = try TensorBridge.encode(x)
        try blocking { try await self.channel.send(frame) }
    }

    public func receive(like: MLXArray, from rank: Int) throws -> MLXArray {
        let frame = try blocking { try await self.channel.receive() }
        return try TensorBridge.decode(frame, expecting: like)
    }

    /// Run an async operation and wait for it.
    ///
    /// A semaphore rather than a run loop: this is called from whichever thread
    /// MLX is evaluating on, which is not guaranteed to have one. The deadline
    /// matters more than the mechanism, because without it a machine that went
    /// to sleep mid-token holds this thread forever and the node stops doing
    /// anything at all.
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws
        -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            do { box.set(.success(try await work())) } catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw PipelineChannel.Failure.transport(
                "the other machine did not answer within \(Int(timeout))s")
        }
        return try box.take().get()
    }
}

/// A result handed between a task and the thread waiting on it.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ result: Result<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        value = result
    }

    func take() -> Result<T, Error> {
        lock.lock(); defer { lock.unlock() }
        return value ?? .failure(PipelineChannel.Failure.notConnected)
    }
}
