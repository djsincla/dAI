import Foundation
import Testing
@testable import DaiAgent

/// The parser is the part with no safety net. A missed call turns an agent into
/// a chat box; an invented one makes the client execute something the model
/// never asked for, which is the only failure here with consequences outside
/// the conversation.
@Suite struct ToolDialectTests {
    private func dialect(_ id: String) -> ToolDialect {
        ToolDialects.load().first { $0.id == id }!
    }

    @Test("selects by chat template rather than model name")
    func selectionByTemplate() {
        // The point of matching on the template: this is a name nobody has
        // published, and it still resolves correctly because the template is
        // what actually determines the format.
        let picked = ToolDialects.select(
            template: "{% if tools %}<tool_call>{{ }}</tool_call>{% endif %}",
            modelId: "someone/private-finetune-v3-4bit")
        #expect(picked?.id == "hermes-qwen")
    }

    @Test("falls back to the name when the template gives nothing away")
    func selectionByName() {
        #expect(ToolDialects.select(template: "no hints here",
                                    modelId: "mlx-community/Llama-3.2-3B-Instruct-4bit")?.id
                == "llama-3")
    }

    @Test("always resolves to something rather than refusing")
    func selectionFallsBack() {
        // A model nobody has a dialect for should still be tried, because the
        // generic shape is common enough to be worth attempting.
        #expect(ToolDialects.select(template: "unknown", modelId: "unknown/model") != nil)
    }

    @Test("reads a tagged call and keeps the prose around it")
    func taggedCall() {
        let out = dialect("hermes-qwen").parseCalls(from: """
            I will check that file.
            <tool_call>{"name": "Read", "arguments": {"file_path": "/a/b.swift"}}</tool_call>
            """)
        #expect(out.calls.count == 1)
        #expect(out.calls[0].name == "Read")
        #expect(out.calls[0].arguments["file_path"]?.stringValue == "/a/b.swift")
        // The explanation is kept: a model often says why before asking, and
        // dropping it loses the only account of its reasoning.
        #expect(out.text == "I will check that file.")
    }

    @Test("reads several calls in one response")
    func multipleCalls() {
        let out = dialect("hermes-qwen").parseCalls(from: """
            <tool_call>{"name": "Read", "arguments": {"file_path": "a"}}</tool_call>
            <tool_call>{"name": "Grep", "arguments": {"pattern": "x"}}</tool_call>
            """)
        #expect(out.calls.map(\.name) == ["Read", "Grep"])
    }

    @Test("treats an unterminated call as text, not a guess")
    func unterminatedCall() {
        // Generation stopping mid-call is common at a token limit. Completing
        // it by guessing would execute something the model did not finish
        // asking for.
        let out = dialect("hermes-qwen").parseCalls(
            from: #"<tool_call>{"name": "Bash", "arguments": {"command": "rm -"#)
        #expect(out.calls.isEmpty)
    }

    @Test("does not invent a call from prose that merely mentions one")
    func prosePassesThrough() {
        let out = dialect("generic-json").parseCalls(
            from: "You could use the Read tool with a file_path argument.")
        #expect(out.calls.isEmpty)
        #expect(out.text.contains("Read tool"))
    }

    @Test("handles braces inside argument strings")
    func bracesInArguments() {
        // Counting braces alone breaks here, and the failure is silent: the
        // call is truncated to something that still parses.
        let out = dialect("generic-json").parseCalls(
            from: #"{"name": "Bash", "arguments": {"command": "echo \"{}\" | jq ."}}"#)
        #expect(out.calls.count == 1)
        #expect(out.calls[0].arguments["command"]?.stringValue == #"echo "{}" | jq ."#)
    }

    @Test("reads Mistral's prefixed array")
    func prefixedArray() {
        let out = dialect("mistral").parseCalls(
            from: #"[TOOL_CALLS] [{"name": "Read", "arguments": {"file_path": "x"}}]"#)
        #expect(out.calls.count == 1)
        #expect(out.calls[0].name == "Read")
    }

    @Test("reads Llama's parameters field rather than arguments")
    func llamaParameterField() {
        // Llama names the field differently, which is exactly the sort of
        // detail that makes this per-family rather than universal.
        let out = dialect("llama-3").parseCalls(
            from: #"{"name": "Read", "parameters": {"file_path": "/x"}}"#)
        #expect(out.calls.count == 1)
        #expect(out.calls[0].arguments["file_path"]?.stringValue == "/x")
    }

    @Test("accepts a call with no arguments")
    func argumentlessCall() {
        // A tool that takes nothing is legitimate, and rejecting it would drop
        // a valid call.
        let out = dialect("generic-json").parseCalls(from: #"{"name": "ListFiles"}"#)
        #expect(out.calls.count == 1)
        #expect(out.calls[0].name == "ListFiles")
    }

    @Test("ignores JSON that is not a call")
    func unrelatedJSON() {
        let out = dialect("generic-json").parseCalls(
            from: #"Here is some config: {"timeout": 30, "retries": 2}"#)
        #expect(out.calls.isEmpty)
        #expect(out.text.contains("timeout"))
    }

    @Test("discards the model's second thoughts after a finished call")
    func truncatesAfterCall() {
        // Llama ends a call with <|eom_id|> and then carries on: a fresh
        // assistant turn, the same call again, and a narration of what the
        // result would be. A client would have executed it twice.
        let output = #"{"name": "get_weather", "parameters": {"city": "Paris"}}"#
            + "<|eom_id|><|start_header_id|>assistant<|end_header_id|>\n"
            + #"{"name": "get_weather", "parameters": {"city": "Paris"}}"#
        let out = dialect("llama-3").parseCalls(from: output)
        #expect(out.calls.count == 1)
        #expect(out.calls[0].arguments["city"]?.stringValue == "Paris")
    }

    @Test("keeps a closing delimiter that is part of the call")
    func stopIsNotTruncate() {
        // Hermes stops at </tool_call>, which closes the call rather than
        // following it. Truncating there deleted the very thing being parsed.
        let out = dialect("hermes-qwen").parseCalls(
            from: #"<tool_call>{"name": "Read", "arguments": {"p": "x"}}</tool_call>"#)
        #expect(out.calls.count == 1)
    }

    @Test("strips the model's control tokens from prose")
    func stripsControlTokens() {
        // Scaffolding the tokeniser would normally consume. Shipping it to a
        // client shows the user the model's plumbing.
        let out = dialect("generic-json").parseCalls(
            from: "<|start_header_id|>assistant<|end_header_id|> Hello there.")
        #expect(!out.text.contains("<|"))
        #expect(out.text.contains("Hello there."))
    }

    @Test("reads a bare call from a model that ignores its own tags")
    func bareFallback() {
        // Qwen2.5-Coder ships a template built around <tool_call> and then
        // emits the object without it. Before the fallback the call arrived as
        // prose, so the client saw an assistant describing a call rather than
        // making one.
        let out = dialect("hermes-qwen").parseCalls(
            from: #"{"name": "Read", "arguments": {"file_path": "x", "limit": 24}}"#)
        #expect(out.calls.count == 1)
        #expect(out.calls[0].name == "Read")
    }

    @Test("the fallback still refuses to invent a call")
    func fallbackDoesNotInvent() {
        // The fallback must not become a licence to guess: prose describing a
        // tool is still prose.
        let out = dialect("hermes-qwen").parseCalls(
            from: "You should call the Read tool with a file_path of x.")
        #expect(out.calls.isEmpty)
    }

    @Test("finds a complete call nested inside an unterminated one")
    func nestedInsideUnterminated() {
        // Observed from a 32B under a forced tool choice: it restated the whole
        // call inside its own arguments and stopped before closing the outer
        // object. The inner call is exactly what was asked for.
        let out = dialect("generic-json").parseCalls(
            from: #"{"name": "get_weather", "arguments": {"name": "get_weather", "arguments": {"city": "Paris"}}"#)
        #expect(out.calls.count == 1)
        #expect(out.calls[0].name == "get_weather")
    }

    @Test("strips the scaffolding a model echoes back")
    func stripsScaffolding() {
        // Observed alongside a correct call: the model echoed an empty tools
        // block and the opening marker, which made a clean reply look like a
        // leak of the plumbing.
        let out = dialect("hermes-qwen").parseCalls(from:
            "<tool_call><tools>\n\n</tools>"
            + #"<tool_call>{"name": "Read", "arguments": {"p": "x"}}</tool_call>"#)
        #expect(out.calls.count == 1)
        #expect(out.text.isEmpty)
    }

    @Test("dialects can be replaced without rebuilding")
    func dialectsAreData() throws {
        // The point of the file: a fleet adopting a new model family should not
        // wait for an agent release.
        let path = NSTemporaryDirectory() + "dialects-\(UUID().uuidString).json"
        try #"""
        [{"id": "custom", "match": {"templateContains": ["@@CALL@@"]},
          "parse": {"style": "tagged-json", "open": "@@CALL@@", "close": "@@END@@",
                    "nameField": "tool", "argsField": "args"}}]
        """#.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        setenv("DAI_TOOL_DIALECTS", path, 1)
        defer { unsetenv("DAI_TOOL_DIALECTS") }

        let loaded = ToolDialects.load()
        #expect(loaded.count == 1)
        let picked = ToolDialects.select(template: "uses @@CALL@@ here", modelId: "x",
                                         from: loaded)
        #expect(picked?.id == "custom")
        let out = picked!.parseCalls(from: #"@@CALL@@{"tool": "Read", "args": {"p": 1}}@@END@@"#)
        #expect(out.calls.first?.name == "Read")
    }
}
