import Foundation

/// How to read a tool call out of a model's output.
///
/// Chat templates are one-directional. The template in a model's
/// `tokenizer_config.json` says how to render tool definitions *into* a prompt,
/// and MLX applies it, so that half needs no configuration at all. Nothing says
/// how to read a call back out of generated text, and every family invented its
/// own spelling: Qwen and Hermes wrap JSON in `<tool_call>` tags, Llama emits a
/// bare object, Mistral prefixes an array with `[TOOL_CALLS]`. That asymmetry is
/// the whole reason this file exists.
///
/// **Matched on the template, not the model name.** Names are unstable in
/// exactly the ways that matter here: quantised forks, renames, and fine-tunes
/// all produce new names for a model that still speaks its parent's dialect. A
/// fine-tune of Qwen keeps Qwen's template, so matching on the template gets it
/// right for models nobody has heard of yet.
public struct ToolDialect: Codable, Sendable, Equatable {
    public struct Match: Codable, Sendable, Equatable {
        /// Substrings that must appear in the model's chat template.
        public var templateContains: [String]?
        /// Fallback for models whose template gives nothing away.
        public var modelContains: [String]?
    }

    public struct Parse: Codable, Sendable, Equatable {
        public enum Style: String, Codable, Sendable {
            /// `<tool_call>{...}</tool_call>`
            case taggedJSON = "tagged-json"
            /// `[TOOL_CALLS] [{...}]`
            case prefixedJSON = "prefixed-json"
            /// A bare `{...}` in the output, with no marker at all.
            case bareJSON = "bare-json"
        }
        public var style: Style
        public var open: String?
        public var close: String?
        public var prefix: String?
        public var nameField: String = "name"
        public var argsField: String = "arguments"
    }

    public var id: String
    public var match: Match
    public var parse: Parse
    /// Sequences that should end sampling.
    ///
    /// A generation concern, and not the same thing as ``truncateAt``: Hermes
    /// stops at `</tool_call>`, which is the closing delimiter of the call
    /// itself and must be kept.
    public var stop: [String]?

    /// Everything from here on is discarded before parsing.
    ///
    /// Only for markers that sit *after* a finished call. Llama emits
    /// `<|eom_id|>` and then, left to itself, opens a fresh assistant turn and
    /// repeats the whole call, so a model that asked once produced two calls a
    /// client would have executed twice. Conflating this with ``stop`` deleted
    /// the call instead of the noise after it.
    public var truncateAt: [String]?
}

public struct ToolCall: Sendable, Equatable {
    public let name: String
    public let arguments: JSONValue
}

/// What a model actually said: prose, calls, or both.
public struct ToolParse: Sendable, Equatable {
    public let text: String
    public let calls: [ToolCall]
}

public enum ToolDialects {
    /// The dialects that ship with the agent.
    ///
    /// Data rather than code so adding a model family is an edit, not a build.
    /// `DAI_TOOL_DIALECTS` points at a replacement file, which is how a fleet
    /// adopts a new model before the agent that knows about it is rolled out.
    public static let builtinJSON = """
    [
      {
        "id": "hermes-qwen",
        "match": { "templateContains": ["<tool_call>"] },
        "parse": { "style": "tagged-json", "open": "<tool_call>", "close": "</tool_call>",
                   "nameField": "name", "argsField": "arguments" },
        "stop": ["</tool_call>"]
      },
      {
        "id": "mistral",
        "match": { "templateContains": ["[TOOL_CALLS]"] },
        "parse": { "style": "prefixed-json", "prefix": "[TOOL_CALLS]",
                   "nameField": "name", "argsField": "arguments" }
      },
      {
        "id": "llama-3",
        "match": { "templateContains": ["<|python_tag|>", "ipython"],
                   "modelContains": ["llama-3", "llama3"] },
        "parse": { "style": "bare-json", "nameField": "name", "argsField": "parameters" },
        "stop": ["<|eom_id|>", "<|eot_id|>"],
        "truncateAt": ["<|eom_id|>", "<|eot_id|>"]
      },
      {
        "id": "generic-json",
        "match": {},
        "parse": { "style": "bare-json", "nameField": "name", "argsField": "arguments" }
      }
    ]
    """

    public static func load() -> [ToolDialect] {
        let decoder = JSONDecoder()
        if let path = ProcessInfo.processInfo.environment["DAI_TOOL_DIALECTS"],
           let data = FileManager.default.contents(atPath: path),
           let custom = try? decoder.decode([ToolDialect].self, from: data) {
            return custom
        }
        return (try? decoder.decode([ToolDialect].self,
                                    from: Data(builtinJSON.utf8))) ?? []
    }

    /// Pick the dialect for a model.
    ///
    /// Template first, name second, and the catch-all last: a dialect with no
    /// criteria matches anything, so ordering in the file is what makes it a
    /// fallback rather than a competitor.
    public static func select(template: String?, modelId: String,
                              from dialects: [ToolDialect] = load()) -> ToolDialect? {
        let name = modelId.lowercased()
        for dialect in dialects {
            if let needles = dialect.match.templateContains, let template {
                if needles.contains(where: { template.contains($0) }) { return dialect }
            }
            if let needles = dialect.match.modelContains {
                if needles.contains(where: { name.contains($0.lowercased()) }) { return dialect }
            }
            if dialect.match.templateContains == nil && dialect.match.modelContains == nil {
                return dialect
            }
        }
        return nil
    }
}

public extension ToolDialect {
    /// Read calls out of generated text.
    ///
    /// Returns the prose alongside them, because a model often explains itself
    /// before asking for something and dropping that loses the explanation.
    ///
    /// **Never invents a call.** Anything that does not parse cleanly is left as
    /// text. A fabricated call makes the client execute something the model did
    /// not ask for, which is the one failure here with consequences outside the
    /// conversation.
    func parseCalls(from output: String) -> ToolParse {
        // Truncated at the first stop sequence before anything else.
        //
        // Llama ends a tool call with <|eom_id|> and then, left to itself,
        // carries on: it opened a fresh assistant turn, repeated the call, and
        // narrated what the result would be. That produced duplicate calls
        // from a model that had asked once, which a client would execute twice.
        var output = output
        for marker in truncateAt ?? [] {
            if let cut = output.range(of: marker) {
                output = String(output[output.startIndex..<cut.lowerBound])
                break
            }
        }

        let parsed: ToolParse
        switch parse.style {
        case .taggedJSON:
            parsed = parseTagged(output)
        case .prefixedJSON:
            parsed = parsePrefixed(output)
        case .bareJSON:
            parsed = parseBare(output)
        }
        return ToolParse(text: Self.stripControlTokens(parsed.text), calls: parsed.calls)
    }

    /// Remove the model's own control tokens from prose.
    ///
    /// These are scaffolding the tokeniser would normally consume, and they
    /// reach the text whenever generation runs past where it should have
    /// stopped. Shipping them to a client shows the user the model's plumbing.
    static func stripControlTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[a-z_]+\\|>", with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseTagged(_ output: String) -> ToolParse {
        guard let open = parse.open, let close = parse.close else {
            return ToolParse(text: output, calls: [])
        }
        var text = ""
        var calls: [ToolCall] = []
        var rest = Substring(output)

        while let start = rest.range(of: open) {
            text += rest[rest.startIndex..<start.lowerBound]
            let after = rest[start.upperBound...]
            guard let end = after.range(of: close) else {
                // An unterminated tag means generation stopped mid-call. Treat
                // the remainder as text rather than guessing at the rest.
                text += after
                return ToolParse(text: text.trimmed, calls: calls)
            }
            if let call = call(fromJSON: String(after[after.startIndex..<end.lowerBound])) {
                calls.append(call)
            }
            rest = after[end.upperBound...]
        }
        text += rest
        return ToolParse(text: text.trimmed, calls: calls)
    }

    private func parsePrefixed(_ output: String) -> ToolParse {
        guard let prefix = parse.prefix, let start = output.range(of: prefix) else {
            return ToolParse(text: output.trimmed, calls: [])
        }
        let text = String(output[output.startIndex..<start.lowerBound])
        let body = String(output[start.upperBound...])
        // An array of calls, or a single one. Both appear in the wild.
        if let calls = callsFromArray(body), !calls.isEmpty {
            return ToolParse(text: text.trimmed, calls: calls)
        }
        if let call = call(fromJSON: body) {
            return ToolParse(text: text.trimmed, calls: [call])
        }
        return ToolParse(text: output.trimmed, calls: [])
    }

    private func parseBare(_ output: String) -> ToolParse {
        // Scan for balanced objects rather than trusting the whole output to be
        // JSON: models routinely wrap a call in prose or a fenced block.
        var calls: [ToolCall] = []
        var text = ""
        var index = output.startIndex

        while index < output.endIndex {
            guard let open = output[index...].firstIndex(of: "{") else {
                text += output[index...]
                break
            }
            text += output[index..<open]
            guard let close = balancedEnd(of: output, from: open) else {
                text += output[open...]
                break
            }
            let candidate = String(output[open...close])
            if let call = call(fromJSON: candidate) {
                calls.append(call)
            } else {
                text += candidate
            }
            index = output.index(after: close)
        }
        return ToolParse(text: text.trimmed, calls: calls)
    }

    /// The end of the object starting at `start`, respecting nesting and
    /// strings. Counting braces alone breaks on any argument containing one.
    private func balancedEnd(of string: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < string.endIndex {
            let c = string[i]
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i = string.index(after: i)
        }
        return nil
    }

    private func callsFromArray(_ json: String) -> [ToolCall]? {
        guard let data = json.data(using: .utf8),
              case let .array(items)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return items.compactMap(call(fromValue:))
    }

    private func call(fromJSON json: String) -> ToolCall? {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return call(fromValue: value)
    }

    private func call(fromValue value: JSONValue) -> ToolCall? {
        guard let name = value[parse.nameField]?.stringValue, !name.isEmpty else { return nil }
        // Arguments are optional: a tool with no parameters is legitimate, and
        // refusing it would silently drop a valid call.
        let arguments = value[parse.argsField] ?? .object([:])
        return ToolCall(name: name, arguments: arguments)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
