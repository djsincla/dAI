import Foundation
import NIOCore
import NIOSSL

/// Presents the Secure Enclave key to the TLS handshake.
///
/// The key cannot be handed to the TLS stack, because it does not exist outside
/// the Enclave and never will. What can be handed over is the ability to sign
/// with it, which is what this is: TLS calls in with the bytes it needs signed,
/// the Enclave signs them, and the private half stays where it was.
///
/// This is why the agent's HTTP client is not `URLSession`. URLSession can only
/// present a client certificate as a `SecIdentity`, and a `SecIdentity` is a
/// certificate plus a `SecKey`. A CryptoKit Enclave key is not a `SecKey`, and
/// making one would mean storing the key in the keychain, which needs the
/// entitlement and provisioning profile the Enclave route was chosen to avoid.
/// NIO's TLS stack takes a signing callback, so it does not care where the key
/// lives.
public struct EnclaveSigner: NIOSSLCustomPrivateKey, Hashable, Sendable {
    private let key: EnclaveKey
    private let id: UUID

    public init(key: EnclaveKey) {
        self.key = key
        self.id = UUID()
    }

    /// P-256 with SHA-256, and nothing else, because that is the only thing the
    /// Enclave generates. Offering more would advertise capabilities the key
    /// does not have and fail mid-handshake when one was selected.
    public var signatureAlgorithms: [SignatureAlgorithm] { [.ecdsaSecp256R1Sha256] }

    public func sign(channel: Channel, algorithm: SignatureAlgorithm,
                     data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        let loop = channel.eventLoop
        guard algorithm == .ecdsaSecp256R1Sha256 else {
            // Unreachable given the list above, but a signature produced under
            // the wrong algorithm would fail verification at the peer with an
            // error pointing nowhere near here.
            return loop.makeFailedFuture(Failure.unsupported(algorithm))
        }
        do {
            // TLS passes the message to be signed, not its digest, so hashing
            // happens inside the Enclave as part of signing. Hashing here first
            // would sign a digest of a digest.
            let signature = try key.sign(Data(data.readableBytesView))
            return loop.makeSucceededFuture(ByteBuffer(bytes: signature))
        } catch {
            return loop.makeFailedFuture(error)
        }
    }

    /// Never called. An EC key cannot decrypt, and it is only ever offered for
    /// ECDSA, so reaching this means the handshake negotiated something
    /// impossible.
    public func decrypt(channel: Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        channel.eventLoop.makeFailedFuture(Failure.cannotDecrypt)
    }

    public enum Failure: Error, CustomStringConvertible {
        case unsupported(SignatureAlgorithm)
        case cannotDecrypt

        public var description: String {
            switch self {
            case let .unsupported(a): return "the Enclave key cannot sign with \(a)"
            case .cannotDecrypt: return "an EC key cannot decrypt; this key only signs"
            }
        }
    }

    public static func == (a: EnclaveSigner, b: EnclaveSigner) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
