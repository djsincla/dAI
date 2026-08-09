import Foundation

/// A JSON value that is `Sendable` and round-trips unknown fields.
///
/// Work item payloads are `additionalProperties: true` in the schema, so the
/// agent cannot know their shape. Decoding into a struct with known fields would
/// be tidier but is wrong here: unfinished items are handed *back* to the
/// control plane for requeue, and anything the agent failed to model would be
/// silently dropped on the way through, corrupting work it never even looked at.
///
/// `[String: Any]` would express this too, except Swift 6 will not carry it
/// across a concurrency boundary, which is a fair objection to passing untyped
/// data between actors.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(v): try c.encode(v)
        case let .number(v):
            // Encode whole numbers as integers so an `id` survives the round
            // trip as `3` rather than `3.0`, which some consumers treat as a
            // different value.
            if v == v.rounded(), abs(v) < 9e15 { try c.encode(Int(v)) } else { try c.encode(v) }
        case let .string(v): try c.encode(v)
        case let .array(v): try c.encode(v)
        case let .object(v): try c.encode(v)
        }
    }

    // Convenience accessors for the few fields the agent actually reads.
    public subscript(key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }
    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var intValue: Int? { if case let .number(n) = self { return Int(n) }; return nil }
}

public typealias WorkItem = JSONValue
