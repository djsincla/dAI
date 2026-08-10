import Foundation

/// Coerce tool arguments to the types the tool declared.
///
/// Models emit JSON that looks right and is loosely typed: a field declared
/// integer comes back as `"24"`, a boolean as `"true"`, a number as `"3.5"`.
/// Passing that through makes the client's own validation reject a call the
/// model got substantively right, and the client cannot tell a type slip from a
/// hallucinated argument.
///
/// Deliberately narrow. It converts between representations of the same value
/// and nothing else: `"24"` becomes `24`, but `"soon"` stays a string rather
/// than becoming `0`. Inventing a value the model did not supply would be worse
/// than the mismatch, because the call would then run with an argument nobody
/// chose.
public enum ToolSchema {
    public static func coerce(_ arguments: JSONValue, to schema: JSONValue?) -> JSONValue {
        guard let properties = schema?["properties"]?.objectValue,
              let given = arguments.objectValue else { return arguments }

        var out: [String: JSONValue] = [:]
        for (key, value) in given {
            guard let declared = properties[key] else {
                out[key] = value  // undeclared: pass through untouched
                continue
            }
            out[key] = coerce(value: value, to: declared)
        }
        return .object(out)
    }

    private static func coerce(value: JSONValue, to declared: JSONValue) -> JSONValue {
        let type = declared["type"]?.stringValue

        switch type {
        case "integer":
            if case let .string(s) = value, let n = Int(s.trimmingCharacters(in: .whitespaces)) {
                return .number(Double(n))
            }
            // A whole-valued double is already the right number in the wrong
            // spelling, which JSONValue encodes as an integer anyway.
            return value

        case "number":
            if case let .string(s) = value, let n = Double(s.trimmingCharacters(in: .whitespaces)) {
                return .number(n)
            }
            return value

        case "boolean":
            if case let .string(s) = value {
                switch s.lowercased().trimmingCharacters(in: .whitespaces) {
                case "true", "yes", "1": return .bool(true)
                case "false", "no", "0": return .bool(false)
                default: return value
                }
            }
            return value

        case "string":
            // The other direction, which happens just as often: a path or an id
            // that looks numeric arrives as a number.
            if case let .number(n) = value {
                return .string(n == n.rounded() && abs(n) < 9e15
                    ? String(Int(n)) : String(n))
            }
            return value

        case "array":
            guard case let .array(items) = value else {
                // A single value where a list was declared is a shape the
                // models get wrong constantly, and wrapping it loses nothing.
                return .array([coerce(value: value, to: declared["items"] ?? .null)])
            }
            guard let itemSchema = declared["items"] else { return value }
            return .array(items.map { coerce(value: $0, to: itemSchema) })

        case "object":
            return coerce(value, to: declared)

        default:
            return value
        }
    }
}
