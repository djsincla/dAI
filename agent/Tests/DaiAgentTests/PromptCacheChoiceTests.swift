import Testing
@testable import DaiWorker

/// Which conversation's prefix to reuse, and which to let go.
///
/// The cache held exactly one prefix, so two clients destroyed each other: each
/// turn found the other's prefix, shared nothing with it, started fresh, and
/// still paid for the memory. Two callers were worse off than one.
///
/// These are the decisions, extracted so they can be checked without a model -
/// the shape `SplitRunner.accepts` and `Worker.directive` already have. The
/// reason is not tidiness: a reused prefix that is merely similar rather than
/// identical produces a model answering a question nobody asked, with no error
/// anywhere, and that is not a thing to leave to an integration test.
@Suite("choosing a conversation to reuse")
struct PromptCacheChoiceTests {
    typealias Candidate = PromptCache.Candidate

    /// A prompt of `n` distinct tokens beginning with `prefix`.
    static func prompt(prefix: [Int], length: Int, seed: Int) -> [Int] {
        var out = prefix
        var next = seed
        while out.count < length { out.append(next); next += 1 }
        return out
    }

    static let shared = Array(0 ..< 1_000)

    @Test("nothing to reuse when there are no entries")
    func empty() {
        #expect(PromptCache.choose([], for: Self.shared) == nil)
    }

    @Test("two conversations both stay reusable")
    func twoConversations() {
        // The whole point. One slot meant the second of these evicted the first
        // on every turn and neither was ever warm.
        let a = Self.prompt(prefix: Self.shared, length: 1_400, seed: 10_000)
        let b = Self.prompt(prefix: Self.shared, length: 1_400, seed: 90_000)
        let entries = [Candidate(tokens: a, lastUsed: 1), Candidate(tokens: b, lastUsed: 2)]

        #expect(PromptCache.choose(entries, for: a)?.index == 0)
        #expect(PromptCache.choose(entries, for: b)?.index == 1)
    }

    @Test("the longest shared prefix wins, not the most recent")
    func longestWins() {
        // Recency is the tie-breaker, never the criterion. Preferring the recent
        // entry would reuse 1,000 tokens where 1,399 were available and quietly
        // give up most of the saving.
        let deep = Self.prompt(prefix: Array(0 ..< 1_399), length: 1_500, seed: 10_000)
        let shallow = Self.prompt(prefix: Array(0 ..< 1_000), length: 1_500, seed: 90_000)
        let asking = Self.prompt(prefix: Array(0 ..< 1_399), length: 1_600, seed: 70_000)

        let entries = [Candidate(tokens: deep, lastUsed: 1),
                       Candidate(tokens: shallow, lastUsed: 99)]
        let pick = PromptCache.choose(entries, for: asking)
        #expect(pick?.index == 0)
        #expect(pick?.shared == 1_399)
    }

    @Test("a tie goes to the most recently used")
    func tieToRecent() {
        // Two entries sharing a prefix and diverging later. The one in active use
        // is the one whose next turn is coming.
        let a = Self.prompt(prefix: Self.shared, length: 1_400, seed: 10_000)
        let b = Self.prompt(prefix: Self.shared, length: 1_400, seed: 90_000)
        let asking = Self.prompt(prefix: Self.shared, length: 1_400, seed: 50_000)

        #expect(PromptCache.choose([Candidate(tokens: a, lastUsed: 1),
                                    Candidate(tokens: b, lastUsed: 2)],
                                   for: asking)?.index == 1)
        // And the other way round, so the result follows recency rather than
        // position in the array.
        #expect(PromptCache.choose([Candidate(tokens: a, lastUsed: 2),
                                    Candidate(tokens: b, lastUsed: 1)],
                                   for: asking)?.index == 0)
    }

    @Test("refuses a prefix too short to be worth keeping")
    func belowMinimum() {
        // Building and trimming a cache is not free and a short prompt is read in
        // well under a second, so a near-miss is a cold read rather than a
        // saving.
        let entry = Candidate(tokens: Self.prompt(prefix: [1, 2, 3], length: 900, seed: 500),
                              lastUsed: 1)
        let asking = Self.prompt(prefix: [1, 2, 3], length: 900, seed: 900)
        #expect(PromptCache.choose([entry], for: asking) == nil)
        #expect(PromptCache.minimumReuse == 256)
    }

    @Test("always leaves one token to generate from")
    func leavesOneToken() {
        // An identical request must not be thrown away. Reusing the prompt
        // entirely leaves the generator nothing to start from, and bailing out to
        // a cold read cost 21s where a near-match cost 0.5s.
        let same = Self.prompt(prefix: Self.shared, length: 1_400, seed: 10_000)
        let pick = PromptCache.choose([Candidate(tokens: same, lastUsed: 1)], for: same)
        #expect(pick?.shared == same.count - 1)
    }

    @Test("a longer cached conversation still matches a shorter prompt")
    func cacheLongerThanPrompt() {
        // The entry holds the previous turn's answer as well as its prompt, so it
        // is routinely longer than what is being asked for now. The excess is
        // trimmed by the caller; the choice must not refuse it.
        let held = Self.prompt(prefix: Self.shared, length: 2_000, seed: 10_000)
        let asking = Array(held[..<1_500])
        #expect(PromptCache.choose([Candidate(tokens: held, lastUsed: 1)],
                                   for: asking)?.shared == 1_499)
    }
}

/// What to drop when the total no longer fits.
///
/// Whole entries, never a truncation inside one. `maxKVSize` looks like the
/// obvious cap and is the wrong one: it swaps in a `RotatingKVCache` whose
/// `isTrimmable` is `offset < maxCacheSize`, so past the cap every plan falls
/// back to a cold read and reuse switches itself off for exactly the long
/// conversations it exists for.
@Suite("evicting to fit a budget")
struct PromptCacheEvictionTests {
    @Test("nothing is dropped while the total fits")
    func fits() {
        #expect(PromptCache.evictions(sizes: [10, 20], lastUsed: [1, 2],
                                      budget: 100, keeping: 1) == [])
    }

    @Test("least recently used goes first")
    func lruFirst() {
        let dropped = PromptCache.evictions(sizes: [50, 50, 50], lastUsed: [3, 1, 2],
                                            budget: 100, keeping: 0)
        #expect(dropped == [1])
    }

    @Test("stops as soon as the total fits")
    func stopsEarly() {
        // Not "evict until there is room to spare". Each entry dropped is a
        // conversation that pays a full prefill next turn.
        let dropped = PromptCache.evictions(sizes: [40, 40, 40, 40], lastUsed: [4, 1, 2, 3],
                                            budget: 120, keeping: 0)
        #expect(dropped == [1])
    }

    @Test("never drops the entry about to be used")
    func neverTheOneInUse() {
        // Evicting it would free memory by throwing away the answer.
        let dropped = PromptCache.evictions(sizes: [100, 10], lastUsed: [1, 2],
                                            budget: 50, keeping: 0)
        #expect(!dropped.contains(0))
        #expect(dropped == [1])
    }

    @Test("a single conversation larger than the whole budget is kept")
    func oversizedSurvives() {
        // There is nothing else to drop, and refusing to serve the request would
        // be a worse answer than exceeding a budget nobody can honour. It is
        // reported rather than enforced by discarding the only entry.
        #expect(PromptCache.evictions(sizes: [500], lastUsed: [1],
                                      budget: 100, keeping: 0) == [])
    }

    @Test("drops as many as it takes")
    func several() {
        let dropped = PromptCache.evictions(sizes: [30, 30, 30, 30], lastUsed: [4, 1, 2, 3],
                                            budget: 40, keeping: 0)
        #expect(dropped.sorted() == [1, 2, 3])
    }

    @Test("a budget of zero keeps only what is in use")
    func zeroBudget() {
        let dropped = PromptCache.evictions(sizes: [10, 10], lastUsed: [1, 2],
                                            budget: 0, keeping: 1)
        #expect(dropped == [0])
    }
}

/// `offer` and `commit` are two calls that must land on the same entry.
///
/// A pipeline agrees before anybody acts, so proposing and committing are
/// deliberately separate - `plan` cannot be used to propose, because it trims as
/// it goes and asking it a question changes the answer. With one entry there was
/// nothing to disagree about. With several there is, and this is the regression
/// worth writing carefully: picking a different entry at commit than at offer
/// would reuse attention state belonging to different tokens, which answers
/// wrongly rather than slowly.
///
/// The mechanism that prevents it is that both call the same pure function with
/// the same arguments and nothing mutates in between. So that is what is
/// asserted, rather than a hoped-for outcome.
@Suite("proposing and committing agree")
struct PromptCacheAgreementTests {
    typealias Candidate = PromptCache.Candidate

    static func entries() -> [Candidate] {
        let base = Array(0 ..< 1_200)
        return [
            Candidate(tokens: base + Array(10_000 ..< 10_200), lastUsed: 3),
            Candidate(tokens: base + Array(20_000 ..< 20_400), lastUsed: 7),
            Candidate(tokens: Array(0 ..< 400) + Array(30_000 ..< 30_600), lastUsed: 9),
        ]
    }

    @Test("the same question gets the same answer, every time")
    func deterministic() {
        let asking = Array(0 ..< 1_200) + Array(20_000 ..< 20_500)
        let first = PromptCache.choose(Self.entries(), for: asking)
        for _ in 0 ..< 20 {
            let again = PromptCache.choose(Self.entries(), for: asking)
            #expect(again?.index == first?.index)
            #expect(again?.shared == first?.shared)
        }
        // And it is the entry that actually shares the most, not merely a stable
        // wrong answer.
        #expect(first?.index == 1)
    }

    @Test("an agreed reuse shorter than this rank offered still lands on that entry")
    func agreedShorter() {
        // Rank 0 proposes what it can offer; every other rank verifies, and the
        // gang takes the smallest. So a rank routinely commits to fewer tokens
        // than it offered, and must trim the same entry rather than pick another.
        let asking = Array(0 ..< 1_200) + Array(20_000 ..< 20_500)
        let offered = PromptCache.choose(Self.entries(), for: asking)!
        for agreed in [PromptCache.minimumReuse, 700, offered.shared - 1, offered.shared] {
            let atCommit = PromptCache.choose(Self.entries(), for: asking)!
            #expect(atCommit.index == offered.index,
                    "agreeing on \(agreed) changed which entry was chosen")
            #expect(atCommit.shared >= agreed)
        }
    }

    @Test("a rank holding nothing offers nothing, which forces a full prefill")
    func restartedRank() {
        // The worst case of the whole mechanism is the behaviour it replaced: a
        // restarted rank offers nothing, so the gang agrees on zero and every
        // machine reads the prompt from scratch. That is a slow answer, not a
        // wrong one.
        #expect(PromptCache.choose([], for: Array(0 ..< 2_000)) == nil)
    }
}

/// What the machine will allow, whatever the group asked for.
///
/// The group states intent and the machine has the facts, so the stricter wins -
/// the same bargain the presence policy already strikes with the fleet policy.
@Suite("clamping the budget to the machine")
struct PromptCacheBudgetTests {
    @Test("what was asked for, when the machine can afford it")
    func passesThrough() {
        // The 8 GB default has to survive on both machines in this fleet
        // untouched, or the ceiling is the setting and the setting is decoration.
        #expect(PromptCache.affordableBytes(askedGb: 8, physicalMemoryGb: 48)
                == 8_000_000_000)
        #expect(PromptCache.affordableBytes(askedGb: 8, physicalMemoryGb: 64)
                == 8_000_000_000)
    }

    @Test("a figure the machine cannot afford is cut to what it can")
    func clamped() {
        // A control plane asking for 64 GB on a 48 GB workstation is not
        // malicious, it is describing a box it cannot see.
        #expect(PromptCache.affordableBytes(askedGb: 64, physicalMemoryGb: 48)
                == 12_000_000_000)
    }

    @Test("silence means the default, not nothing")
    func silenceIsTheDefault() {
        // A control plane too old to say must not be read as "keep nothing warm":
        // that machine would pay a full prefill every turn, which is the
        // behaviour this whole type exists to prevent.
        #expect(PromptCache.affordableBytes(askedGb: nil, physicalMemoryGb: 48)
                == PromptCache.defaultBudgetBytes)
    }

    @Test("zero is a choice and is honoured")
    func zeroHonoured() {
        // Distinct from silence. Somebody with no memory to spare can say so.
        #expect(PromptCache.affordableBytes(askedGb: 0, physicalMemoryGb: 48) == 0)
    }

    @Test("nonsense cannot produce a negative budget")
    func neverNegative() {
        #expect(PromptCache.affordableBytes(askedGb: -5, physicalMemoryGb: 48) == 0)
        #expect(PromptCache.affordableBytes(askedGb: 8, physicalMemoryGb: 0) == 0)
    }

    @Test("fractional gigabytes survive, because memory is not round")
    func fractional() {
        // Read through an integer this would have become 7, silently.
        #expect(PromptCache.affordableBytes(askedGb: 7.2, physicalMemoryGb: 48)
                == 7_200_000_000)
    }
}
