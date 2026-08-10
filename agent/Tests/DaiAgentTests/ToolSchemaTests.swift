import Foundation
import Testing
@testable import DaiAgent

/// Models emit loosely typed JSON. The client validates strictly, so a value
/// spelled as the wrong type makes it reject a call the model got right.
@Suite struct ToolSchemaTests {
    private let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "file_path": .object(["type": .string("string")]),
            "limit": .object(["type": .string("integer")]),
            "ratio": .object(["type": .string("number")]),
            "recursive": .object(["type": .string("boolean")]),
            "paths": .object(["type": .string("array"),
                              "items": .object(["type": .string("string")])]),
        ]),
    ])

    @Test("a number spelled as a string becomes a number")
    func stringToInteger() {
        // The exact case reported: {"limit": "24"} against a declared integer.
        let out = ToolSchema.coerce(.object(["limit": .string("24")]), to: schema)
        #expect(out["limit"]?.intValue == 24)
        if case .string = out["limit"]! { Issue.record("still a string") }
    }

    @Test("a path that looks numeric stays a string")
    func numberToString() {
        let out = ToolSchema.coerce(.object(["file_path": .number(2024)]), to: schema)
        #expect(out["file_path"]?.stringValue == "2024")
    }

    @Test("booleans and decimals are coerced too")
    func otherScalars() {
        let out = ToolSchema.coerce(
            .object(["recursive": .string("true"), "ratio": .string("0.75")]), to: schema)
        #expect(out["recursive"] == .bool(true))
        #expect(out["ratio"] == .number(0.75))
    }

    @Test("a single value where a list was declared is wrapped")
    func singleValueToArray() {
        // Models get this shape wrong constantly, and wrapping loses nothing.
        let out = ToolSchema.coerce(.object(["paths": .string("/a/b")]), to: schema)
        #expect(out["paths"] == .array([.string("/a/b")]))
    }

    @Test("a value that is not a number is left alone")
    func doesNotInvent() {
        // The important limit. Turning "soon" into 0 would run the call with an
        // argument nobody chose, which is worse than the type mismatch.
        let out = ToolSchema.coerce(.object(["limit": .string("soon")]), to: schema)
        #expect(out["limit"]?.stringValue == "soon")
    }

    @Test("undeclared arguments pass through untouched")
    func undeclaredUntouched() {
        let out = ToolSchema.coerce(.object(["extra": .string("7")]), to: schema)
        #expect(out["extra"]?.stringValue == "7")
    }

    @Test("no schema means no coercion")
    func noSchema() {
        let args = JSONValue.object(["limit": .string("24")])
        #expect(ToolSchema.coerce(args, to: nil) == args)
    }
}
