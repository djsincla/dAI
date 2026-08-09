import CryptoKit
import Foundation

/// Builds the PKCS#10 certificate request a node presents at enrollment.
///
/// The request proves possession: it carries the public key and is signed by the
/// matching private key, so the control plane can check that whoever asked for
/// the certificate actually holds the key it will be bound to. With the key in
/// the Secure Enclave, that proof is worth something - it says the key is on
/// this machine and cannot be anywhere else.
///
/// The subject here is a formality. The CA replaces it with the node's id, so a
/// node cannot choose the name it is known by, and there is a test on the server
/// asserting exactly that. The hostname goes in because a human reading a
/// pending queue needs something to recognise.
public enum CSR {
    private enum OID {
        static let commonName = "2.5.4.3"
        static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
    }

    public static func create(commonName: String, key: EnclaveKey) throws -> String {
        // CertificationRequestInfo ::= SEQUENCE {
        //   version INTEGER (0), subject Name,
        //   subjectPKInfo SubjectPublicKeyInfo,
        //   attributes [0] IMPLICIT SET OF Attribute }
        //
        // The attribute set is present and empty. Omitting it entirely is a
        // common shortcut and produces a request that some parsers accept and
        // others reject, which is a bad way to find out.
        let subject = ASN1.sequence(ASN1.set(ASN1.sequence(
            ASN1.objectIdentifier(OID.commonName),
            ASN1.utf8String(commonName))))

        let info = ASN1.sequence(
            ASN1.integer(0),
            subject,
            key.subjectPublicKeyInfo,
            ASN1.contextSpecific(0, Data()))

        // Signed over the DER of the info block exactly as it will be
        // transmitted. Re-encoding it afterwards would be free to produce
        // different bytes and silently break verification.
        let signature = try key.sign(info)

        let request = ASN1.sequence(
            info,
            // ecdsa-with-SHA256 takes no parameters. An explicit NULL here, the
            // habit carried over from RSA, makes the algorithm identifier wrong.
            ASN1.sequence(ASN1.objectIdentifier(OID.ecdsaWithSHA256)),
            ASN1.bitString(signature))

        return pem(request, label: "CERTIFICATE REQUEST")
    }

    static func pem(_ der: Data, label: String) -> String {
        let body = der.base64EncodedString()
        let lines = stride(from: 0, to: body.count, by: 64).map { start -> String in
            let from = body.index(body.startIndex, offsetBy: start)
            let to = body.index(from, offsetBy: min(64, body.count - start))
            return String(body[from..<to])
        }
        return "-----BEGIN \(label)-----\n\(lines.joined(separator: "\n"))\n-----END \(label)-----\n"
    }
}
