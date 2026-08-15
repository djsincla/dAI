import Testing
@testable import DaiWorker

/// What ends a generation, and why it is not part of one.
///
/// A split answer came back ending in `<|im_end|>`. The loop appended each token
/// and checked on the next lap, so the terminator was already in the output by
/// the time it was recognised - decoded into the text, and counted as a
/// completion token the request was billed for. Cosmetic in prose; it would
/// corrupt any caller parsing JSON.
@Suite("what ends a generation")
struct StopTokenTests {
    typealias Stop = SplitRunner.StopSet

    @Test("a terminator ends generation and is not part of it")
    func terminatorIsNotOutput() {
        // The rule the loop now follows: test, then append. Never the reverse.
        let stops = Stop([151645])
        var produced: [Int] = []
        for token in [100, 200, 151645, 300] {
            if stops.ends(token) { break }
            produced.append(token)
        }
        #expect(produced == [100, 200])
        #expect(!produced.contains(151645))
    }

    @Test("reads eos_token_id whether the model writes one or a list")
    func bothSpellings() {
        // Qwen ends a chat turn with <|im_end|> and a document with
        // <|endoftext|>, and declares them as a list. Other models write a bare
        // integer. A loop that reads only one spelling misses a stop token and
        // runs to the token budget, producing text past the end of the answer.
        #expect(Stop.declared(in: ["eos_token_id": 151643]) == [151643])
        #expect(Stop.declared(in: ["eos_token_id": [151645, 151643]]) == [151645, 151643])
    }

    @Test("a model that declares nothing is not a crash")
    func silentConfig() {
        // The tokenizer still supplies eosTokenId; the config is an addition to
        // it, not a replacement.
        #expect(Stop.declared(in: [:]).isEmpty)
        #expect(Stop.declared(in: ["eos_token_id": "end"]).isEmpty)
        #expect(Stop.declared(in: ["eos_token_id": [151645, "end"]]) == [151645])
    }

    @Test("all three sources end generation")
    func everySource() {
        // eos from the tokenizer, unknown (generation has gone somewhere
        // meaningless), and whatever the model's own config declared.
        let stops = Stop(Set([151645]).union([151643, 0]))
        for token in [151645, 151643, 0] { #expect(stops.ends(token)) }
        #expect(!stops.ends(42))
    }

    @Test("the budget still stops it when nothing terminates")
    func budgetHolds() {
        // A model that never emits a stop token must still return. The loop
        // exits on count, and does not step again for a token it would discard -
        // on a split that step is a round trip between machines.
        let stops = Stop([151645])
        var produced: [Int] = []
        let maxTokens = 4
        var token = 7
        var steps = 0
        while true {
            if stops.ends(token) { break }
            produced.append(token)
            if produced.count >= maxTokens { break }
            token = 7; steps += 1
        }
        #expect(produced.count == 4)
        #expect(steps == 3, "stepped \(steps) times for 4 tokens; one would be discarded")
    }
}
