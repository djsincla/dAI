import Foundation
import MLX
import MLXLMCommon

/// Reuses the work already done on a conversation's earlier turns.
///
/// An agentic client resends the whole conversation every turn: system prompt,
/// tool schemas, and the history so far. Read from scratch each time, that
/// measured 19,243 tokens at 363 seconds on a 32B - six minutes before a single
/// token of the answer, on a turn that differed from the last one by a few
/// hundred tokens.
///
/// The attention state for a prefix does not depend on what follows it, so the
/// work is repeatable rather than necessary. Keeping the KV cache and feeding
/// only the tokens that are new turns the cost of a turn into the cost of its
/// delta.
///
/// **The correctness rule is that a reused prefix must be identical, not
/// similar.** Attention state carries the exact tokens that produced it, so
/// reusing a cache against a prompt that merely looks alike yields a model
/// answering a question nobody asked, confidently and with no error anywhere.
/// The comparison is therefore on token ids, and any divergence discards
/// everything from that point.
/// Not an actor, and `@unchecked Sendable` deliberately.
///
/// Every use is inside `ModelContainer.perform`, which already serialises
/// access to the model: two generations cannot run at once, so the cache has
/// exactly one caller at a time. Making it an actor instead puts an await
/// between reading the plan and using it, and the model it is planning against
/// is not Sendable, so the boundary cannot be crossed anyway.
///
/// The guarantee is therefore the container's rather than the type's, which is
/// worth stating plainly: use it anywhere else and the annotation becomes a
/// lie.
final class PromptCache: @unchecked Sendable {
    private var tokens: [Int] = []
    private var cache: [KVCache]?

    /// Below this there is nothing to save. Building and trimming a cache is
    /// not free, and a short prompt is read in well under a second anyway.
    private static let minimumReuse = 256

    struct Plan {
        /// Tokens still to be read. Empty prefix means the whole prompt.
        let toProcess: [Int]
        /// The warm cache, or nil to start fresh.
        let cache: [KVCache]?
        let reused: Int
    }

    /// Work out what can be skipped for this prompt.
    func plan(for full: [Int], model: any LanguageModel,
              parameters: GenerateParameters) -> Plan {
        guard let existing = cache, !tokens.isEmpty else {
            return fresh(full, model: model, parameters: parameters)
        }

        // One token is always left to process, even when the whole prompt is
        // already cached.
        //
        // Generation continues from a token, so a prompt reused in its entirety
        // leaves the generator nothing to start from. Bailing out to a cold
        // read was the wrong answer to that: an identical request - the same
        // prompt sent twice - found a complete match and threw it away, taking
        // 21s where a near-match took 0.5s. Holding one token back costs
        // nothing and keeps the other thousands.
        let shared = min(commonPrefix(tokens, full), full.count - 1)

        guard shared >= Self.minimumReuse else {
            return fresh(full, model: model, parameters: parameters)
        }

        // The cache may hold more than the shared prefix - the previous turn's
        // answer, or a diverging tail - and that has to go before anything new
        // is appended, or the model attends to tokens this prompt never
        // contained.
        let excess = (existing.first?.offset ?? 0) - shared
        if excess > 0 {
            guard existing.allSatisfy(\.isTrimmable) else {
                return fresh(full, model: model, parameters: parameters)
            }
            for layer in existing { _ = layer.trim(excess) }
        }

        tokens = Array(full)
        return Plan(toProcess: Array(full[shared...]), cache: existing, reused: shared)
    }

    private func fresh(_ full: [Int], model: any LanguageModel,
                       parameters: GenerateParameters) -> Plan {
        let made = model.newCache(parameters: parameters)
        cache = made
        tokens = Array(full)
        return Plan(toProcess: full, cache: made, reused: 0)
    }

    // Generated tokens are deliberately not recorded.
    //
    // The stream yields text, not token ids, and re-tokenising the answer to
    // guess them would be worse than useless: byte-pair boundaries differ when
    // text is tokenised alone rather than in context, so a wrong id would match
    // a prefix that was never really there and the model would answer against
    // attention state belonging to different tokens. The cache reports its own
    // offset, which is what the trim uses, so the generated tail is discarded
    // accurately rather than matched approximately. The saving is the prefix -
    // system prompt, tools, history - which is nearly all of it.

    /// Drop everything. Called when the model is released, since a cache
    /// outliving its weights is a large allocation nobody can use.
    func clear() {
        tokens = []
        cache = nil
    }

    private func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var i = 0
        let limit = min(a.count, b.count)
        while i < limit, a[i] == b[i] { i += 1 }
        return i
    }
}
