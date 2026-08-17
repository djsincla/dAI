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
///
/// **Several conversations, not one.** This held a single prefix, which made two
/// clients destroy each other: each turn found the other's prefix, shared nothing
/// with it, started fresh, and still paid for the memory. Two callers were
/// therefore worse off than one, and worst of all on a group pinned to a model,
/// where nothing unloads and the slot churns for as long as the group stands.
///
/// There is no conversation id to key on - the API is stateless and the client
/// resends everything - so entries are chosen by the longest prefix they share
/// with the incoming prompt, which is the comparison this type already made,
/// against several entries instead of one.
///
/// Bounded in **bytes and never in entries**: a 500-token conversation and a
/// 19,000-token one differ by a factor of forty, and a KV cache for the 32B costs
/// about 256 KiB per token. The size is measured rather than derived, because
/// `KVCacheSimple` allocates in steps of 256 and a token count times a guess
/// would under-report the allocation that actually has to fit.
///
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
    /// One conversation's prefix and the attention state that produced it.
    private struct Entry {
        var tokens: [Int]
        var cache: [KVCache]
        /// A counter, not a clock. Eviction order has to be testable, and a
        /// timestamp makes the order depend on how fast the test ran.
        var lastUsed: Int
    }

    private var entries: [Entry] = []
    private var clock = 0

    /// Bytes this cache may hold across every entry.
    ///
    /// Eight gigabytes by default, which is about three 19,000-token
    /// conversations of a 32B split across two machines. The caller normally
    /// replaces it with what the group asked for, clamped to what the machine
    /// can afford.
    private var budget: Int = defaultBudgetBytes

    static let defaultBudgetBytes = 8 * 1_000_000_000

    /// Below this there is nothing to save. Building and trimming a cache is
    /// not free, and a short prompt is read in well under a second anyway.
    static let minimumReuse = 256

    struct Plan {
        /// Tokens still to be read. Empty prefix means the whole prompt.
        let toProcess: [Int]
        /// The warm cache, or nil to start fresh.
        let cache: [KVCache]?
        let reused: Int
    }

    // MARK: - The decisions, as functions

    /// An entry, reduced to what choosing between them needs.
    struct Candidate {
        let tokens: [Int]
        let lastUsed: Int
        init(tokens: [Int], lastUsed: Int) {
            self.tokens = tokens
            self.lastUsed = lastUsed
        }
    }

    /// Which entry to reuse for this prompt, and how much of it.
    ///
    /// Static and pure, so it can be checked without a model - the shape
    /// `SplitRunner.accepts` and `Worker.directive` already have, and for the
    /// same reason: it is the decision rather than the doing that is worth being
    /// able to assert.
    ///
    /// **One token is always left to process**, even when the whole prompt is
    /// already cached. Generation continues from a token, so a prompt reused in
    /// its entirety leaves the generator nothing to start from. Bailing out to a
    /// cold read was the wrong answer to that: an identical request found a
    /// complete match and threw it away, taking 21 s where a near-match took
    /// 0.5 s.
    ///
    /// Ties go to the most recently used, because a tie means two entries share
    /// the same prefix and diverge later - the one in active use is the one whose
    /// next turn is coming.
    static func choose(_ candidates: [Candidate], for full: [Int],
                       minimumReuse: Int = PromptCache.minimumReuse)
    -> (index: Int, shared: Int)? {
        var best: (index: Int, shared: Int, lastUsed: Int)?
        for (index, candidate) in candidates.enumerated() {
            let shared = min(commonPrefix(candidate.tokens, full), full.count - 1)
            guard shared >= minimumReuse else { continue }
            if let current = best,
               (shared, candidate.lastUsed) <= (current.shared, current.lastUsed) {
                continue
            }
            best = (index, shared, candidate.lastUsed)
        }
        guard let best else { return nil }
        return (best.index, best.shared)
    }

    /// Which entries to drop so the total fits, least recently used first.
    ///
    /// Whole entries, never a truncation inside one. `maxKVSize` would have been
    /// the obvious cap and is the wrong one: it swaps in a `RotatingKVCache`
    /// whose `isTrimmable` is `offset < maxCacheSize`, so past the cap every
    /// plan falls back to a cold read - reuse would switch itself off for
    /// exactly the long conversations it exists for - and a rotating cache
    /// overwrites the middle of a conversation while its offset keeps counting,
    /// which is the silent wrong answer this file is written to avoid.
    ///
    /// `keeping` is never dropped: it is the entry the caller is about to use,
    /// and evicting it would free memory by throwing away the answer.
    static func evictions(sizes: [Int], lastUsed: [Int], budget: Int,
                          keeping: Int) -> [Int] {
        var total = sizes.reduce(0, +)
        guard total > budget else { return [] }

        let order = sizes.indices
            .filter { $0 != keeping }
            .sorted { lastUsed[$0] < lastUsed[$1] }

        var dropped: [Int] = []
        for index in order {
            guard total > budget else { break }
            dropped.append(index)
            total -= sizes[index]
        }
        return dropped
    }

    /// What a cache actually occupies.
    ///
    /// Measured through `Evaluatable`, not derived from a token count: the arrays
    /// grow in steps of 256, so the allocation is what has to fit rather than
    /// what is used. It is also automatically right per rank in a split, where
    /// each machine holds only its own layers.
    static func bytes(of cache: [KVCache]) -> Int {
        cache.reduce(0) { running, layer in
            running + layer.innerState().reduce(0) { $0 + $1.nbytes }
        }
    }

    // MARK: - Using it

    /// What this machine will allow, whatever it was asked for.
    ///
    /// The group states intent and the machine has the facts, so the stricter of
    /// the two wins - the same bargain the presence policy already strikes with
    /// the fleet policy. A control plane asking for 64 GB of cache on a 48 GB
    /// workstation is not malicious, it is simply describing a box it cannot see.
    ///
    /// Deliberately a fraction of physical memory rather than the presence
    /// policy's `memFrac`. That number moves every time somebody touches a
    /// trackpad, and a budget that moved with it would evict conversations
    /// because the owner walked past - throwing away exactly the work this cache
    /// exists to keep.
    ///
    /// A quarter of memory: 12 GB on a 48 GB machine, 16 on a 64 GB one, so the
    /// 8 GB default passes through untouched on both and the ceiling only bites
    /// when a figure is unreasonable.
    static func affordableBytes(askedGb: Double?, physicalMemoryGb: Double,
                                ceilingFraction: Double = 0.25) -> Int {
        let asked = askedGb ?? Double(defaultBudgetBytes) / 1_000_000_000
        let ceiling = max(0, physicalMemoryGb * ceilingFraction)
        let allowed = max(0, min(asked, ceiling))
        return Int(allowed * 1_000_000_000)
    }

    /// Bytes this cache may hold. Clamped by the caller to what the machine has.
    func setBudget(bytes: Int) {
        budget = max(0, bytes)
        enforceBudget(keeping: -1)
    }

    /// What is held right now, for whoever reports memory.
    var residentBytes: Int { entries.reduce(0) { $0 + Self.bytes(of: $1.cache) } }

    var conversations: Int { entries.count }

    private var candidates: [Candidate] {
        entries.map { Candidate(tokens: $0.tokens, lastUsed: $0.lastUsed) }
    }

    /// Work out what can be skipped for this prompt.
    func plan(for full: [Int], model: any LanguageModel,
              parameters: GenerateParameters) -> Plan {
        guard let pick = Self.choose(candidates, for: full) else {
            return fresh(full, model: model, parameters: parameters)
        }
        return reuseEntry(pick.index, upTo: pick.shared, for: full,
                          model: model, parameters: parameters)
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
        guard let pick = Self.choose(candidates, for: full) else { return nil }

        // A cache that cannot be trimmed cannot be reused for anything shorter
        // than it holds, so it has nothing to offer.
        let entry = entries[pick.index]
        let excess = (entry.cache.first?.offset ?? 0) - pick.shared
        if excess > 0, !entry.cache.allSatisfy(\.isTrimmable) { return nil }

        return (pick.shared, Self.digest(of: Array(full[..<pick.shared])))
    }

    /// Reuse exactly this many tokens, having agreed on it.
    ///
    /// Zero means every machine starts fresh, which is what any disagreement
    /// produces and what every split request did before this existed.
    ///
    /// The entry is found again rather than remembered from `offer`. Selection is
    /// a pure function of the same entries and the same prompt, so it lands on
    /// the same one - and keeping no state between the two preserves the property
    /// that asking the question does not change the answer. Remembering would
    /// also be wrong the moment anything else touched the cache in between.
    func commit(reuse: Int, for full: [Int], model: any LanguageModel,
                parameters: GenerateParameters) -> Plan {
        guard reuse > 0, let pick = Self.choose(candidates, for: full),
              pick.shared >= reuse
        else {
            return fresh(full, model: model, parameters: parameters)
        }
        return reuseEntry(pick.index, upTo: reuse, for: full,
                          model: model, parameters: parameters)
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

    // MARK: - Private

    /// Trim the chosen entry back to the agreed prefix and hand it over.
    private func reuseEntry(_ index: Int, upTo shared: Int, for full: [Int],
                            model: any LanguageModel,
                            parameters: GenerateParameters) -> Plan {
        var entry = entries[index]

        // The entry may hold more than the shared prefix - the previous turn's
        // answer, or a diverging tail - and that has to go before anything new
        // is appended, or the model attends to tokens this prompt never
        // contained.
        let excess = (entry.cache.first?.offset ?? 0) - shared
        if excess > 0 {
            guard entry.cache.allSatisfy(\.isTrimmable) else {
                return fresh(full, model: model, parameters: parameters)
            }
            for layer in entry.cache { _ = layer.trim(excess) }
        }

        clock += 1
        entry.tokens = Array(full)
        entry.lastUsed = clock
        entries[index] = entry
        enforceBudget(keeping: index)

        return Plan(toProcess: Array(full[shared...]), cache: entry.cache, reused: shared)
    }

    private func fresh(_ full: [Int], model: any LanguageModel,
                       parameters: GenerateParameters) -> Plan {
        let made = model.newCache(parameters: parameters)
        clock += 1
        entries.append(Entry(tokens: Array(full), cache: made, lastUsed: clock))
        enforceBudget(keeping: entries.count - 1)
        return Plan(toProcess: full, cache: made, reused: 0)
    }

    /// Drop least-recently-used entries until the total fits.
    private func enforceBudget(keeping: Int) {
        let sizes = entries.map { Self.bytes(of: $0.cache) }
        let dropped = Self.evictions(sizes: sizes, lastUsed: entries.map(\.lastUsed),
                                     budget: budget, keeping: keeping)
        guard !dropped.isEmpty else { return }
        for index in dropped.sorted(by: >) { entries.remove(at: index) }
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
        entries = []
    }

    private static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        var i = 0
        let limit = min(a.count, b.count)
        while i < limit, a[i] == b[i] { i += 1 }
        return i
    }
}
