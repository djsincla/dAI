import CryptoKit
import Foundation

/// The node's private key, held in the Secure Enclave.
///
/// This is what makes a node certificate an identity rather than a file. The
/// previous scheme wrote a PEM to disk at mode 0600, which means the key is
/// exactly as safe as the filesystem: anyone who can read that file can be that
/// node from anywhere, and nothing on the control plane could tell the
/// difference. A key generated in the Enclave never exists outside it. What gets
/// persisted is a blob the Enclave itself encrypted, useless on any other
/// machine, so copying it off achieves nothing.
///
/// It also fixed a bug, which is how it stopped being a nice-to-have. Importing
/// a PEM through `SecPKCS12Import` puts the key under a keychain ACL that
/// prompts for authorisation on every process that signs with it. Interactively
/// that is a dialog; under `launchd` there is nobody to answer it and the TLS
/// handshake simply stalls. An Enclave key has no ACL to negotiate.
///
/// **Why CryptoKit rather than `SecKeyCreateRandomKey`.** The Security framework
/// route stores the key in the keychain, and the keychain refuses
/// (`errSecMissingEntitlement`, -34018) unless the binary carries a
/// `keychain-access-groups` entitlement backed by a provisioning profile. The
/// CryptoKit route hands back a sealed blob to store wherever we like, needs no
/// entitlement and no profile, and was verified working from an unsigned command
/// line tool. The cost is that the key is not a `SecKey`, so it cannot be made
/// into a `SecIdentity` - see ``EnclaveIdentity`` for what that forces.
public struct EnclaveKey: Sendable {
    private let key: SecureEnclave.P256.Signing.PrivateKey

    public enum Failure: Error, CustomStringConvertible {
        case unavailable
        case unreadable(String)

        public var description: String {
            switch self {
            case .unavailable:
                return "this machine has no Secure Enclave"
            case let .unreadable(m):
                return "could not load the stored key: \(m)"
            }
        }
    }

    /// Load the node's key, generating one on first run.
    ///
    /// Generating is not idempotent in the way it looks: a new key means a new
    /// identity, and the certificate held against the old one stops matching. So
    /// an existing blob is always preferred, and a blob that fails to load is an
    /// error rather than a reason to quietly mint a replacement - the node
    /// should stop and be re-enrolled deliberately.
    public static func loadOrCreate(at url: URL) throws -> EnclaveKey {
        guard SecureEnclave.isAvailable else { throw Failure.unavailable }

        if FileManager.default.fileExists(atPath: url.path) {
            let blob = try Data(contentsOf: url)
            do {
                return EnclaveKey(key: try SecureEnclave.P256.Signing
                    .PrivateKey(dataRepresentation: blob))
            } catch {
                // Reached if the blob is corrupt, or if it was sealed by a
                // different machine's Enclave. Both mean this node has no usable
                // identity, and generating a new one would leave it holding a
                // certificate for a key it cannot use.
                throw Failure.unreadable(String(describing: error))
            }
        }

        let key = try SecureEnclave.P256.Signing.PrivateKey()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.dataRepresentation.write(to: url, options: .atomic)
        // 0600 out of habit rather than necessity. The blob is already useless
        // off this machine, which is the entire point, but there is no reason to
        // leave it readable either.
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
        return EnclaveKey(key: key)
    }

    private init(key: SecureEnclave.P256.Signing.PrivateKey) { self.key = key }

    /// The public key as a DER `SubjectPublicKeyInfo`, which is the form a CSR
    /// carries it in.
    public var subjectPublicKeyInfo: Data { key.publicKey.derRepresentation }

    /// Sign with ECDSA over SHA-256, returning the DER form X.509 expects.
    public func sign(_ message: Data) throws -> Data {
        try key.signature(for: message).derRepresentation
    }

    /// Sign a pre-computed SHA-256 digest.
    ///
    /// TLS hands the transcript hash to be signed rather than the message, so
    /// this exists for the handshake path where hashing has already happened.
    public func signDigest(_ digest: Data) throws -> Data {
        try key.signature(for: PrecomputedDigest(bytes: digest)).derRepresentation
    }
}

/// Lets an already-hashed value be passed where CryptoKit expects a digest.
///
/// `signature(for:)` takes a `Digest` and hashes anything else itself, so
/// handing it TLS's transcript hash directly would hash it twice and produce a
/// signature no peer will verify.
private struct PrecomputedDigest: Digest {
    let bytes: Data
    static var byteCount: Int { SHA256.byteCount }

    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
    static func == (a: PrecomputedDigest, b: PrecomputedDigest) -> Bool { a.bytes == b.bytes }
}
