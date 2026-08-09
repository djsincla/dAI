import Foundation

/// Just enough DER to build a PKCS#10 certificate request.
///
/// Swift has no CSR builder. CryptoKit signs and Security parses certificates,
/// but nothing in the SDK produces the request that sits between them, so the
/// bytes get assembled here.
///
/// Encoding only, and deliberately so. A decoder would have to be defensive
/// about hostile input; this only ever serialises values the agent already
/// holds, which keeps it small enough to read in one sitting.
enum ASN1 {
    /// A DER element: tag, then length, then contents.
    ///
    /// Length uses the short form below 128 and the long form above, where the
    /// first byte carries the count of length bytes that follow. Getting this
    /// wrong produces a structure that parses locally and is rejected by every
    /// other implementation, so it is the one part worth reading twice.
    static func element(tag: UInt8, _ contents: Data) -> Data {
        var out = Data([tag])
        let n = contents.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var length = Data()
            var remaining = n
            while remaining > 0 {
                length.insert(UInt8(remaining & 0xff), at: 0)
                remaining >>= 8
            }
            out.append(UInt8(0x80 | length.count))
            out.append(length)
        }
        out.append(contents)
        return out
    }

    static func sequence(_ parts: Data...) -> Data { sequence(parts) }
    static func sequence(_ parts: [Data]) -> Data {
        element(tag: 0x30, parts.reduce(Data(), +))
    }

    static func set(_ parts: Data...) -> Data {
        element(tag: 0x31, parts.reduce(Data(), +))
    }

    static func integer(_ value: Int) -> Data {
        var bytes = Data()
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        } while remaining > 0
        // DER integers are signed, so a leading bit of 1 would read as negative.
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return element(tag: 0x02, bytes)
    }

    /// A BIT STRING whose contents are a whole number of bytes, which is every
    /// case here. The leading zero is the count of unused trailing bits.
    static func bitString(_ contents: Data) -> Data {
        element(tag: 0x03, Data([0]) + contents)
    }

    static func utf8String(_ value: String) -> Data {
        element(tag: 0x0c, Data(value.utf8))
    }

    /// An OID in dotted form, encoded base-128 with a continuation bit.
    ///
    /// The first two arcs share a byte as `40 * first + second`, which is the
    /// part everyone forgets.
    static func objectIdentifier(_ dotted: String) -> Data {
        let arcs = dotted.split(separator: ".").compactMap { Int($0) }
        precondition(arcs.count >= 2, "an OID needs at least two arcs")

        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunks = [UInt8(arc & 0x7f)]
            var remaining = arc >> 7
            while remaining > 0 {
                chunks.insert(UInt8((remaining & 0x7f) | 0x80), at: 0)
                remaining >>= 7
            }
            body.append(contentsOf: chunks)
        }
        return element(tag: 0x06, body)
    }

    /// A context-specific constructed tag, `[n]`.
    static func contextSpecific(_ number: UInt8, _ contents: Data) -> Data {
        element(tag: 0xa0 | number, contents)
    }
}
