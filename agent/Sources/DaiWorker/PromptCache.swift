import CryptoKit
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

    // MARK: - Agreeing with another machine

    /// What this cache could offer for this prompt, without committing to it.
    ///
    /// `plan(for:)` cannot be used to propose something that might be refused:
    /// it trims the cache and records the new tokens as it goes, so asking it a
    /// question changes the answer. A pipeline has to agree before anybody acts,
    /// so the question and the commitment are separate.
    ///
    /// The digest is over the token ids of the prefix being offered. Comparing
    /// lengths would let two machines agree on 1,600 while holding 1,600 tokens
    /// of *different* prompts - a state a dedicated gang should never reach, and
    /// "should never" is what layer 26 taught this codebase.
    func offer(for full: [Int]) -> (reusable: Int, digest: [Int32])? {
        guard let existing = cache, !tokens.isEmpty else { return nil }
        let shared = min(commonPrefix(tokens, full), full.count - 1)
        guard shared >= Self.minimumReuse else { return nil }

        // A cache that cannot be trimmed cannot be reused for anything shorter
        // than it holds, so it has nothing to offer.
        let excess = (existing.first?.offset ?? 0) - shared
        if excess > 0, !existing.allSatisfy(\.isTrimmable) { return nil }

        return (shared, Self.digest(of: Array(full[..<shared])))
    }

    /// Reuse exactly this many tokens, having agreed on it.
    ///
    /// Zero means every machine starts fresh, which is what any disagreement
    /// produces and what every split request did before this existed.
    func commit(reuse: Int, for full: [Int], model: any LanguageModel,
                parameters: GenerateParameters) -> Plan {
        guard reuse > 0, let existing = cache else {
            return fresh(full, model: model, parameters: parameters)
        }
        let excess = (existing.first?.offset ?? 0) - reuse
        if excess > 0 {
            guard existing.allSatisfy(\.isTrimmable) else {
                return fresh(full, model: model, parameters: parameters)
            }
            for layer in existing { _ = layer.trim(excess) }
        }
        tokens = Array(full)
        return Plan(toProcess: Array(full[reuse...]), cache: existing, reused: reuse)
    }

    /// SHA256 of a token sequence, as eight words.
    ///
    /// Words rather than bytes because the only path between machines carries
    /// Int32 arrays - the sampled token already travels that way - so a digest
    /// needs no new wire format. Little-endian explicitly: two machines that
    /// disagreed about byte order would disagree about every prompt, which is
    /// safe but would mean the cache never once worked.
    static func digest(of tokens: [Int]) -> [Int32] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(tokens.count * 4)
        for token in tokens {
            let v = UInt32(bitPattern: Int32(truncatingIfNeeded: token))
            bytes.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                                      UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
        }
        let hash = SHA256.hash(data: Data(bytes))
        return stride(from: 0, to: 32, by: 4).map { i in
            let slice = Array(hash)[i ..< i + 4]
            return Int32(bitPattern: UInt32(slice[i]) | UInt32(slice[i + 1]) << 8
                | UInt32(slice[i + 2]) << 16 | UInt32(slice[i + 3]) << 24)
        }
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
