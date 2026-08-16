import Testing
@testable import DaiWorker
import Foundation

/// Agreeing with another machine about what has already been read.
///
/// The single-machine path has had a prompt cache since 6125f8f9 - 47.2 s down
/// to 0.57 s on a repeated prefix - and it never crossed the split boundary.
/// Nothing was removed: SplitRunner has started from a fresh cache since its
/// first commit, so the same model silently lost its cache the moment its group
/// became a split.
///
/// Adding one is not "put a PromptCache in SplitRunner". Each rank holds
/// attention state for its own layers only, so reuse has to be agreed: if one
/// skips 1,600 tokens and another starts fresh, the hidden states do not
/// correspond and the answer is confidently wrong with no error anywhere - the
/// same shape as a layer owned by nobody.
@Suite("agreeing what has already been read")
struct ReuseAgreementTests {
    let prompt = Array(0 ..< 2000)

    /// The gang's answer, using the decision the ranks actually run.
    ///
    /// `SplitRunner.accepts` is what a verifying rank calls over the wire; this
    /// only applies it to each verifier and combines the answers the way the
    /// exchange does - a single no makes it zero. Reimplementing the rule here
    /// would test a copy of it and prove nothing about what ships.
    func agreed(proposal: (reusable: Int, digest: [Int32])?,
                verifiers: [(reusable: Int, digest: [Int32])?],
                prompts: [[Int]]? = nil) -> Int {
        guard let proposal, proposal.reusable > 0 else { return 0 }
        let all = verifiers.enumerated().allSatisfy { i, theirs in
            SplitRunner.accepts(proposal: proposal, mine: theirs,
                                prompt: prompts?[i] ?? prompt)
        }
        return all ? proposal.reusable : 0
    }

    func offerOf(_ tokens: [Int], upTo n: Int) -> (reusable: Int, digest: [Int32]) {
        (n, PromptCache.digest(of: Array(tokens[..<n])))
    }

    @Test("every machine holding the same prefix reuses it")
    func unanimous() {
        let p = offerOf(prompt, upTo: 1600)
        #expect(agreed(proposal: p, verifiers: [p]) == 1600)
        #expect(agreed(proposal: p, verifiers: [p, p]) == 1600)
    }

    @Test("a machine with no cache makes it zero for everybody")
    func oneHasNothing() {
        // A restarted rank. The whole gang re-prefills, which costs exactly what
        // every split request cost before this existed - so the worst case of
        // this mechanism is the behaviour it replaces.
        let p = offerOf(prompt, upTo: 1600)
        #expect(agreed(proposal: p, verifiers: [nil]) == 0)
        #expect(agreed(proposal: p, verifiers: [p, nil]) == 0)
    }

    @Test("a machine holding less than proposed refuses")
    func oneHasLess() {
        let p = offerOf(prompt, upTo: 1600)
        #expect(agreed(proposal: p, verifiers: [offerOf(prompt, upTo: 900)]) == 0)
    }

    @Test("a machine holding more than proposed agrees to the proposal")
    func oneHasMore() {
        // Trimming down is what commit does. Holding more is not a disagreement.
        let p = offerOf(prompt, upTo: 1600)
        let longer = (reusable: 1900, digest: p.digest)
        #expect(agreed(proposal: p, verifiers: [longer]) == 1600)
    }

    @Test("a machine that tokenised the prompt differently is refused")
    func differentTokenisation() {
        // The case a length comparison cannot see, and the only way two ranks
        // can hold the same count of different tokens: every rank tokenises the
        // same text from the same dispatch, so their prompts differ only if
        // their tokenisers do - a stale one from an interrupted model sync.
        //
        // Lengths would match and the caches would not, and the model would
        // answer from attention state belonging to tokens nobody sent.
        let theirPrompt = Array(5000 ..< 7000)
        let mine = offerOf(prompt, upTo: 1600)
        let theirs = offerOf(theirPrompt, upTo: 1600)
        #expect(mine.reusable == theirs.reusable)
        #expect(mine.digest != theirs.digest)
        #expect(agreed(proposal: mine, verifiers: [theirs],
                       prompts: [theirPrompt]) == 0)
    }

    @Test("a proposal longer than the prompt is refused")
    func beyondThePrompt() {
        // Nonsense rather than disagreement, and it must not be indexed. A
        // proposal of 3,000 against a 2,000-token prompt would crash a verifier
        // that trusted it enough to slice.
        let mine = offerOf(prompt, upTo: 1600)
        #expect(!SplitRunner.accepts(proposal: (prompt.count + 1, mine.digest),
                                     mine: mine, prompt: prompt))
    }

    @Test("rank 0 offering nothing means nobody reuses anything")
    func headHasNothing() {
        #expect(agreed(proposal: nil, verifiers: [offerOf(prompt, upTo: 1600)]) == 0)
        #expect(agreed(proposal: (0, []), verifiers: [offerOf(prompt, upTo: 1600)]) == 0)
    }

    @Test("no rank acts on its own opinion")
    func nobodyActsAlone() {
        // The property that makes this safe rather than likely. Whatever each
        // machine believes it could reuse, the answer is zero unless every one
        // of them verified the same prefix.
        let p = offerOf(prompt, upTo: 1600)
        for verifiers in [[nil], [p, nil], [nil, p], [offerOf(prompt, upTo: 300)]] {
            #expect(agreed(proposal: p, verifiers: verifiers) == 0)
        }
    }
}

/// The digest the ranks compare.
@Suite("the digest that decides it")
struct ReuseDigestTests {
    @Test("the same tokens always hash the same")
    func deterministic() {
        // Two machines computing different digests for the same prompt would be
        // safe - they would simply never agree - but the cache would never once
        // work, which is a failure that looks like an absence.
        #expect(PromptCache.digest(of: [1, 2, 3]) == PromptCache.digest(of: [1, 2, 3]))
    }

    @Test("different tokens hash differently, including a reordering")
    func sensitive() {
        #expect(PromptCache.digest(of: [1, 2, 3]) != PromptCache.digest(of: [1, 2, 4]))
        #expect(PromptCache.digest(of: [1, 2, 3]) != PromptCache.digest(of: [3, 2, 1]))
        #expect(PromptCache.digest(of: [1, 2, 3]) != PromptCache.digest(of: [1, 2, 3, 4]))
    }

    @Test("it is eight words, because that is what the wire carries")
    func shape() {
        // The only path between machines carries Int32 arrays - the sampled
        // token already travels that way - so the digest needs no new format.
        #expect(PromptCache.digest(of: [1, 2, 3]).count == 8)
        #expect(PromptCache.digest(of: []).count == 8)
    }

    @Test("a prefix does not hash like the whole")
    func prefixDiffers() {
        // What the verifier actually compares: its own first K tokens against
        // the proposal's. A digest insensitive to length would let a longer
        // prompt match a shorter agreement.
        let tokens = Array(0 ..< 100)
        #expect(PromptCache.digest(of: Array(tokens[..<50]))
             != PromptCache.digest(of: tokens))
    }
}
