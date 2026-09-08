import Foundation
import DaiAgent
import MLX
import MLXLMCommon

/// How a completion is sampled, for both runtimes.
///
/// One type because there are two generation loops. `MLXRuntime` drives MLX's
/// own token iterator; `SplitRunner` steps the model by hand, because a split
/// has to move a hidden state between machines between every token. Before this
/// they each decided sampling separately and identically - `temperature: 0` in
/// one, a bare `argMax` in the other - which is the same fact written twice, and
/// this codebase has already paid for that pattern more than once. Written down
/// here, both loops read it from the same place.
///
/// The values arrive already validated: the control plane refuses what this
/// fleet cannot honour before dispatching anything, so a body that gets here has
/// nothing left to argue with. What is left is a decode that must not invent
/// values - a garbled field falls back to the default rather than throwing,
/// because the alternative is a node failing a request the gateway accepted.
public struct Sampling: Sendable, Equatable {
    /// 0 is greedy, and is the default for the reason the control plane's
    /// `GREEDY` records: a preempted request is requeued onto another machine,
    /// and a batch whose items answer differently depending on which machine was
    /// free is not reproducible.
    public var temperature: Float = 0
    public var topP: Float = 1
    public var repetitionPenalty: Float?
    public var repetitionContextSize: Int = 20
    /// Strings that end generation, and are not part of the answer.
    public var stop: [String] = []

    public init() {}

    /// Read from a dispatch body, in the names the control plane sends.
    public init(_ body: DaiAgent.JSONValue) {
        if let v = body["temperature"]?.doubleValue { temperature = Float(v) }
        if let v = body["top_p"]?.doubleValue { topP = Float(v) }
        if let v = body["repetition_penalty"]?.doubleValue { repetitionPenalty = Float(v) }
        // Only meaningful with a penalty to apply, and `RepetitionContext`
        // has a precondition on it being positive - a zero here would trap the
        // worker rather than refuse the request.
        if let v = body["repetition_context_size"]?.intValue, v > 0 {
            repetitionContextSize = v
        }
        stop = (body["stop"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
    }

    /// The runtime's own parameter object.
    ///
    /// `maxTokens` is the caller's, not part of sampling: it is capped twice on
    /// the way here, by the control plane against the answering node's presence
    /// and again by the node against its own, and neither cap belongs to this.
    public func parameters(maxTokens: Int?) -> GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            repetitionPenalty: repetitionPenalty,
            repetitionContextSize: repetitionContextSize)
    }

    /// Whether this asks for anything other than greedy.
    ///
    /// Used to keep the split path on `argMax` when nothing was requested. The
    /// sampler `GenerateParameters` builds for `temperature == 0` is an
    /// `ArgMaxSampler` and would behave the same, but going through it would put
    /// an allocation and a protocol dispatch inside a loop whose whole budget is
    /// a network round trip, for a request that asked for none of it.
    public var isGreedy: Bool {
        temperature == 0 && repetitionPenalty == nil
    }
}

/// Where a stop sequence cut an answer, if one did.
///
/// Matching happens on the decoded text rather than on token ids because that
/// is what the caller wrote. A sequence a client cares about - `"\n\nHuman:"`,
/// `"</task>"` - almost never falls on a token boundary, and a fleet that only
/// honoured the ones that did would honour them intermittently, which is worse
/// than not honouring them at all.
public struct StopScanner: Sendable {
    private let stops: [String]
    /// The longest stop, so a scan can bound how far back a match could begin.
    private let longest: Int

    public init(_ stops: [String]) {
        self.stops = stops
        self.longest = stops.map(\.count).max() ?? 0
    }

    public var isEmpty: Bool { stops.isEmpty }

    /// The first stop present in `text`, and the text with it and everything
    /// after it removed.
    ///
    /// "First" is by position and not by the order the caller listed them: two
    /// sequences can both be present once a token completes them, and the answer
    /// ends at the earlier one. Ordering by the list instead would make the
    /// result depend on the order the caller happened to write them in.
    public func cut(_ text: String) -> (text: String, matched: String)? {
        guard !stops.isEmpty else { return nil }
        var best: (Range<String.Index>, String)?
        for stop in stops {
            guard let r = text.range(of: stop) else { continue }
            if best == nil || r.lowerBound < best!.0.lowerBound { best = (r, stop) }
        }
        guard let (range, matched) = best else { return nil }
        return (String(text[text.startIndex..<range.lowerBound]), matched)
    }

    /// How much of the tail of an answer could still be the beginning of a stop.
    ///
    /// A generation loop tests as it goes and only has to keep the last few
    /// characters in play; this bounds that without the caller having to know
    /// what the longest sequence is.
    public var lookback: Int { longest }
}

/// The sampler and logit processor for one split completion.
///
/// Only the rank holding the output head builds one. The other ranks compute
/// real layers and hold logits that mean nothing on their own, and are told the
/// chosen token over the link - so sampling exists in exactly one place in a
/// pipeline, which is also the only way the ranks can stay in step.
///
/// Both halves come from `GenerateParameters` rather than being written here.
/// That is the point: `MLXRuntime` hands the same object to MLX's own token
/// iterator, so the two generation loops cannot drift apart in what
/// `temperature: 0.7` means. Re-implementing the sampling maths for the split
/// path would be a second definition of the same fact, which is the failure this
/// whole change set exists to remove.
struct SamplingHead {
    private let sampler: LogitSampler
    private var processor: LogitProcessor?

    /// - Parameter promptTokens: the whole prompt, including any part answered
    ///   from cache. A repetition window seeded only with the tokens this
    ///   request happened to re-read would penalise different words depending on
    ///   how warm the cache was, which is a sampler whose output depends on
    ///   scheduling.
    init(_ sampling: Sampling, promptTokens: [Int]) {
        let parameters = sampling.parameters(maxTokens: nil)
        self.sampler = parameters.sampler()
        self.processor = parameters.processor()
        if var processor, !promptTokens.isEmpty {
            processor.prompt(MLXArray(promptTokens.map { Int32($0) }))
            self.processor = processor
        }
    }

    /// One token from one step's logits.
    mutating func pick(_ logits: MLXArray) -> MLXArray {
        var shaped = logits
        if processor != nil { shaped = processor!.process(logits: shaped) }
        let token = sampler.sample(logits: shaped)
        if processor != nil { processor!.didSample(token: token) }
        return token
    }
}
