import Foundation
import Testing
import DaiAgent
import MLXLMCommon
@testable import DaiWorker

/// Sampling, decoded once for two generation loops.
///
/// The reason this type exists is that there are two: `MLXRuntime` drives MLX's
/// own token iterator, and `SplitRunner` steps the model by hand because a split
/// moves a hidden state between machines between every token. They each decided
/// sampling separately before this - `temperature: 0` in one, a bare `argMax` in
/// the other - and neither read the request. One of those is easy to fix and
/// forget; the other is the fact written twice that this codebase keeps paying
/// for.
struct SamplingTests {
    @Test("greedy unless the request says otherwise")
    func defaultsAreGreedy() {
        let s = Sampling(.object([:]))
        #expect(s.temperature == 0)
        #expect(s.topP == 1)
        #expect(s.repetitionPenalty == nil)
        #expect(s.stop.isEmpty)
        // Load-bearing on a harvested fleet in a way it is not on a dedicated
        // one: a preempted request is requeued onto whichever machine is free,
        // and a batch whose items answer differently depending on which that was
        // is not a reproducible batch.
        #expect(s.isGreedy)
    }

    @Test("reads what the control plane sends")
    func decodes() {
        let s = Sampling(.object([
            "temperature": .number(0.7),
            "top_p": .number(0.9),
            "repetition_penalty": .number(1.1),
            "repetition_context_size": .number(64),
            "stop": .array([.string("</task>"), .string("\n\nHuman:")]),
        ]))
        #expect(s.temperature == 0.7)
        #expect(s.topP == 0.9)
        #expect(s.repetitionPenalty == 1.1)
        #expect(s.repetitionContextSize == 64)
        #expect(s.stop == ["</task>", "\n\nHuman:"])
        #expect(!s.isGreedy)
    }

    @Test("a repetition penalty alone is not greedy")
    func penaltyIsNotGreedy() {
        // `temperature: 0` with a penalty still needs the logit processor, so
        // the split path cannot take its argMax shortcut. Getting this wrong
        // would apply the penalty on one machine and not on a split, which is
        // the same answer differing by deployment shape.
        #expect(!Sampling(.object(["repetition_penalty": .number(1.1)])).isGreedy)
    }

    @Test("a garbled field falls back rather than failing")
    func tolerantDecode() {
        // The control plane refuses anything it cannot honour before dispatching,
        // so a body reaching here has already been checked. What is left is a
        // decode that must not invent a value or throw: a node failing a request
        // the gateway accepted reports as a dead node.
        let s = Sampling(.object([
            "temperature": .string("hot"),
            "stop": .array([.string(""), .number(3), .string("ok")]),
            "repetition_context_size": .number(0),
        ]))
        #expect(s.temperature == 0)
        #expect(s.stop == ["ok"])
        // Zero would trip `RepetitionContext`'s own precondition and trap the
        // worker, which turns a bad number into a crashed agent.
        #expect(s.repetitionContextSize == 20)
    }

    /// Gated on Metal, because building a sampler constructs an `MLXArray` for
    /// the temperature and that aborts in C++ under SwiftPM, which has no shader
    /// library to load. `metalAvailable` is the gate the pipeline tests already
    /// use; this runs under xcodebuild and in CI, which is where the fork is
    /// built properly anyway.
    @Test("the split path's shortcut agrees with the runtime's own sampler",
          .enabled(if: metalAvailable))
    func shortcutAgrees() {
        // The one assertion holding the two generation loops together.
        //
        // `SplitRunner` skips building a sampler when `isGreedy`, and takes a
        // bare `argMax` instead - an allocation and a protocol dispatch saved
        // inside a loop whose whole budget is a round trip between machines.
        // That is only sound while `GenerateParameters` would have produced an
        // `ArgMaxSampler` for the same values. If MLX ever changes when it
        // returns one, the shortcut becomes a split that samples differently
        // from a single machine given the same request - which would show up as
        // a model that behaves differently depending on how many machines it
        // happens to be spread across, and would be blamed on the split.
        let cases: [DaiAgent.JSONValue] = [
            .object([:]),
            .object(["temperature": .number(0)]),
            // top_p without temperature changes nothing: the runtime picks its
            // sampler on temperature first.
            .object(["temperature": .number(0), "top_p": .number(0.5)]),
            .object(["stop": .array([.string("x")])]),
            .object(["temperature": .number(0.7)]),
            .object(["repetition_penalty": .number(1.1)]),
            .object(["temperature": .number(0.7), "top_p": .number(0.9)]),
        ]
        for body in cases {
            let sampling = Sampling(body)
            let sampler = sampling.parameters(maxTokens: nil).sampler()
            #expect(sampling.isGreedy == (sampler is ArgMaxSampler),
                    "\(body.anyValue)")
        }
    }

    @Test("builds the runtime's parameters rather than restating them")
    func parameters() {
        let p = Sampling(.object([
            "temperature": .number(0.7), "top_p": .number(0.9),
            "repetition_penalty": .number(1.1),
        ])).parameters(maxTokens: 128)
        #expect(p.temperature == 0.7)
        #expect(p.topP == 0.9)
        #expect(p.repetitionPenalty == 1.1)
        #expect(p.maxTokens == 128)
    }
}

/// Where a caller's stop sequence cuts an answer.
struct StopScannerTests {
    @Test("cuts the sequence and everything after it")
    func cuts() {
        let s = StopScanner(["\n\nHuman:"])
        let cut = s.cut("The answer is 4.\n\nHuman: and then?")
        #expect(cut?.text == "The answer is 4.")
        #expect(cut?.matched == "\n\nHuman:")
    }

    @Test("nothing to cut leaves the answer alone")
    func passesThrough() {
        #expect(StopScanner(["</task>"]).cut("no terminator here") == nil)
        #expect(StopScanner([]).cut("anything") == nil)
        #expect(StopScanner([]).isEmpty)
    }

    @Test("ends at the earliest match, not the first one listed")
    func earliestWins() {
        // Two sequences can both be present by the time a token completes one of
        // them. Taking the caller's list order instead would make the answer
        // depend on which order they happened to write them in - a difference
        // with no cause anybody could find from the outside.
        let s = StopScanner(["END", "STOP"])
        #expect(s.cut("one STOP two END three")?.matched == "STOP")
        #expect(s.cut("one END two STOP three")?.matched == "END")
    }

    @Test("a sequence at the very start yields an empty answer")
    func atTheStart() {
        // Empty, not nil. The model produced nothing before the terminator it
        // was told to stop at, and reporting no match would return the
        // terminator itself as the answer.
        let cut = StopScanner(["</task>"]).cut("</task> trailing")
        #expect(cut?.text == "")
        #expect(cut?.matched == "</task>")
    }
}
