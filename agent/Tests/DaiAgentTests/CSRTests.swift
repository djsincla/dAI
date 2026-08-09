import CryptoKit
import Foundation
import Testing
@testable import DaiAgent

/// These check the bytes against `openssl` rather than against the encoder that
/// produced them. A hand-rolled DER encoder that only ever validates itself will
/// happily agree with its own mistakes, and the failure would surface as a
/// rejected enrollment with no useful message.
@Suite(.serialized)
struct CSRTests {
    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dai-csr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func openssl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "openssl", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }

    @Test("the request parses and its self-signature verifies")
    func selfSignatureVerifies() throws {
        // The property the control plane relies on: a request whose signature
        // does not verify means the requester does not hold the key, and signing
        // it would bind an identity to somebody else's key.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let key = try EnclaveKey.loadOrCreate(at: dir.appendingPathComponent("node.key"))
        let csr = try CSR.create(commonName: "orca.local", key: key)
        let path = dir.appendingPathComponent("node.csr")
        try csr.write(to: path, atomically: true, encoding: .utf8)

        let text = try openssl(["req", "-in", path.path, "-noout", "-verify", "-text"])
        #expect(text.contains("verify OK") || text.contains("Certificate request self-signature verify OK"))
        #expect(text.contains("CN=orca.local"))
        #expect(text.contains("prime256v1"))
        #expect(text.contains("ecdsa-with-SHA256"))
    }

    @Test("the key stays in the Enclave across restarts")
    func keyPersists() throws {
        // A regenerated key is a new identity, and the certificate issued
        // against the old one silently stops matching. Reloading has to produce
        // the same key.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("node.key")

        let first = try EnclaveKey.loadOrCreate(at: path)
        let second = try EnclaveKey.loadOrCreate(at: path)
        #expect(first.subjectPublicKeyInfo == second.subjectPublicKeyInfo)
    }

    @Test("a stored key is never a readable private key")
    func storedBlobIsNotAKey() throws {
        // The whole reason for the Enclave. If this file were a usable key,
        // nothing would have been gained over the PEM it replaced.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("node.key")
        _ = try EnclaveKey.loadOrCreate(at: path)

        let blob = try Data(contentsOf: path)
        let asText = String(data: blob, encoding: .utf8) ?? ""
        #expect(!asText.contains("PRIVATE KEY"))
        #expect((try? openssl(["ec", "-in", path.path, "-noout"])) == nil)

        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]
        #expect(mode as? NSNumber == 0o600)
    }

    @Test("a corrupt key file is an error, not a new identity")
    func corruptBlobRefusesToRegenerate() throws {
        // Quietly minting a replacement would leave the node holding a
        // certificate for a key it can no longer use, and the symptom would be a
        // handshake failure a long way from the cause.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("node.key")
        _ = try EnclaveKey.loadOrCreate(at: path)
        try Data(repeating: 0x41, count: 284).write(to: path)

        #expect(throws: EnclaveKey.Failure.self) {
            _ = try EnclaveKey.loadOrCreate(at: path)
        }
    }

    @Test("DER length encoding crosses the 127-byte boundary correctly")
    func longFormLengths() throws {
        // Short form below 128, long form above. Getting this wrong yields a
        // structure that round-trips through this encoder and is rejected by
        // everything else, so it is checked directly.
        let short = ASN1.element(tag: 0x04, Data(repeating: 0, count: 127))
        #expect(Array(short.prefix(2)) == [0x04, 127])

        let boundary = ASN1.element(tag: 0x04, Data(repeating: 0, count: 128))
        #expect(Array(boundary.prefix(3)) == [0x04, 0x81, 128])

        let long = ASN1.element(tag: 0x04, Data(repeating: 0, count: 300))
        #expect(Array(long.prefix(4)) == [0x04, 0x82, 0x01, 0x2c])
    }

    @Test("object identifiers encode to the known bytes")
    func objectIdentifiers() throws {
        // ecdsa-with-SHA256, whose first two arcs share a byte as 40*1+2 = 42.
        #expect(Array(ASN1.objectIdentifier("1.2.840.10045.4.3.2"))
                == [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])
        // commonName, 2.5.4.3 -> 40*2+5 = 85.
        #expect(Array(ASN1.objectIdentifier("2.5.4.3")) == [0x06, 0x03, 0x55, 0x04, 0x03])
    }
}
