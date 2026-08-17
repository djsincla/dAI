import DaiAgent
import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Running one model across two machines.
///
/// Each machine holds half the layers and neither holds enough to answer alone.
/// The machine with the later layers also holds the output head, so it is the
/// one that produces a token and the one anything else talks to.
///
/// Every step is one round trip: the earlier machine computes its layers and
/// sends the hidden state, the later machine finishes and samples, then sends
/// the chosen token back. Both machines must then feed that same token into the
/// next step, which is the part that looks optional and is not. Left to sample
/// independently, the machine without the output head reads garbage logits,
/// picks a different token, and the two halves quietly diverge into a
/// conversation neither of them is having.
public actor SplitRunner {
    /// Equatable because the owner keeps a built share and has to answer "is
    /// what I hold the same division of the same model". A different rank or
    /// gang size means different layers, which is a different model in memory
    /// however alike the plans look.
    public struct Plan: Sendable, Equatable, CustomStringConvertible {
        public var description: String {
            "rank \(rank) of \(size) for \(modelId)"
        }

        public let modelId: String
        public let rank: Int
        public let size: Int

        public init(modelId: String, rank: Int, size: Int) {
            self.modelId = modelId
            self.rank = rank
            self.size = size
        }
    }

    public struct Outcome: Sendable {
        public let text: String
        public let tokens: Int
        /// What the prompt cost, which every rank knows because every rank
        /// tokenises it. Reported so a split request states its cost the same
        /// way a single-machine one does - without it a caller reads "0 in" and
        /// cannot compare the two, or bill for either.
        public let promptTokens: Int
        public let promptSeconds: Double
        /// Prompt tokens every machine agreed to skip, having already read them.
        ///
        /// Zero when nothing was agreed, which is what a restarted rank or a
        /// different prompt produces - and what every split request did before
        /// the cache crossed the split boundary.
        public let reusedTokens: Int
        public let decodeSeconds: Double
        public let residentGb: Double
    }

    public enum Failure: Error, CustomStringConvertible {
        case notPipelineable(String)
        case noTokenizer

        public var description: String {
            switch self {
            case let .notPipelineable(id):
                return "\(id) cannot be split; this build only pipelines qwen2 models"
            case .noTokenizer: return "the model directory has no tokenizer"
            }
        }
    }

    private let plan: Plan
    private let transport: ChannelPipelineTransport
    /// Where the model records a link failure it had no way to throw. Checked
    /// after every step, before anything is sampled.
    private let fault = PipelineFault()

    /// This machine's share, once built.
    ///
    /// Kept rather than rebuilt. Building it reads weights off disk and
    /// constructs a model, which is most of what a cold split request costs;
    /// the channel it was built against does not last, but the model does, and
    /// the transport is what stands between them.
    private var built: Loaded?

    public init(plan: Plan, channel: PipelineChannel? = nil) {
        self.plan = plan
        self.transport = ChannelPipelineTransport(channel: channel)
    }

    /// Point the built model at the link for the request about to run.
    ///
    /// Called before every generation, including the first. A model that keeps
    /// a channel from a previous request would send into a socket that has been
    /// closed - and `close()` on every exit path is deliberate, so that is the
    /// normal state between requests rather than an unusual one.
    public func rebind(_ channel: PipelineChannel?) {
        transport.adopt(channel)
    }

    /// What this machine's share is taking, in gigabytes.
    ///
    /// From the same global counter `MLXRuntime` reads, so it is the process
    /// rather than this model: approximate, and it always was. Reported so a
    /// readiness view can say something rather than nothing, not so anybody can
    /// attribute bytes.
    public var residentGb: Double {
        built == nil ? 0 : Double(GPU.snapshot().activeMemory) / 1_073_741_824
    }

    /// Whether this runner already holds a built share for the plan it was
    /// created with. Asked by the owner deciding whether to keep it.
    public var isBuilt: Bool { built != nil }

    /// Let go of the built share, so its memory returns.
    public func release() {
        built = nil
        transport.adopt(nil)
    }

    /// Load only this machine's share of the model.
    ///
    /// The split is applied before the weights, so the layers this machine does
    /// not own are never referenced and therefore never read off disk. Loading
    /// the whole model and discarding afterwards would need the memory first,
    /// which is the thing there is not enough of.
    /// Which tokens end generation, and the rule that they are not part of it.
    ///
    /// A terminator is a signal, not output. Appending it and then noticing on
    /// the next lap put `<|im_end|>` into an answer served across two machines -
    /// cosmetic in prose, and something that would break any caller parsing
    /// JSON. It also counted as a completion token, so the request billed for a
    /// token nobody asked for and nobody could read.
    ///
    /// Three sources, because one is not enough. `eosTokenId` is the tokenizer's
    /// idea of the end. `unknownTokenId` means generation has gone somewhere
    /// meaningless and upstream treats it as terminal. And a model's config may
    /// declare several - Qwen ends a chat turn with `<|im_end|>` while
    /// `<|endoftext|>` ends a document, and a loop that knows only one of them
    /// runs to the token budget producing text past the end of the answer.
    public struct StopSet: Sendable {
        public let ids: Set<Int>

        public init(_ ids: Set<Int>) { self.ids = ids }

        public func ends(_ token: Int) -> Bool { ids.contains(token) }

        /// `eos_token_id` from a model's config.json, which is an integer in
        /// some models and a list in others. Both spellings mean the same thing
        /// and reading only one of them is how a stop token gets missed.
        public static func declared(in fields: [String: Any]) -> Set<Int> {
            switch fields["eos_token_id"] {
            case let one as Int: return [one]
            case let many as [Any]: return Set(many.compactMap { $0 as? Int })
            default: return []
            }
        }
    }

    public struct Loaded {
        public let model: any LanguageModel
        public let tokenizer: Tokenizer
        public let split: PipelineSplit
        /// Layers in the whole model, before it was divided. `split` describes
        /// this machine's share and cannot answer "share of what".
        public let totalLayers: Int
        /// Stop tokens the model's own configuration declares.
        public let declaredStops: Set<Int>
    }

    public func load(directory: URL) async throws -> Loaded {
        let configURL = directory.appendingPathComponent("config.json")
        let raw = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(BaseConfiguration.self, from: raw)

        // Read the layer count from the configuration rather than from the
        // built model. It is needed to decide the split, and asking the model
        // would mean building the whole thing only to learn how much of it to
        // throw away.
        guard var fields = (try? JSONSerialization.jsonObject(with: raw))
            as? [String: Any],
            let layerCount = fields["num_hidden_layers"] as? Int else {
            throw Failure.notPipelineable("\(config.modelType): no num_hidden_layers")
        }

        let split = PipelineSplit(rank: plan.rank, size: plan.size, layerCount: layerCount)

        // Build the model with only the layers this machine owns, by handing
        // the constructor a reduced layer count.
        //
        // The obvious alternative - build all the layers, then keep a slice -
        // does not work, and fails quietly rather than loudly. A Module
        // snapshots its children during init and every later reader consults
        // that snapshot, so the shortened array reaches the forward pass and
        // nothing else: quantisation and weight verification still see the full
        // model. Constructing it small means there is only ever one truth.
        let configForThisMachine: URL
        if split.size > 1 {
            configForThisMachine = try writeConfig(
                Self.reduced(fields, owning: split), alongside: directory)
        } else {
            configForThisMachine = configURL
        }

        let model = try LLMModelFactory.shared.typeRegistry.createModel(
            configuration: configForThisMachine, modelType: config.modelType)
        guard let pipelineable = model as? any Pipelineable else {
            throw Failure.notPipelineable(config.modelType)
        }
        pipelineable.pipeline(split, transport: transport, fault: fault)

        try loadWeights(modelDirectory: directory, model: model,
                        quantization: config.quantization,
                        perLayerQuantization: config.perLayerQuantization,
                        keepingLayers: split.startIndex ..< split.endIndex)

        let tokenizer = try await loadTokenizer(
            configuration: ModelConfiguration(directory: directory), hub: HubApi())
        return Loaded(model: model, tokenizer: tokenizer, split: split,
                      totalLayers: layerCount,
                      declaredStops: StopSet.declared(in: fields))
    }

    /// The model configuration as this machine should see it.
    ///
    /// Only the layer count changes. Everything else - vocabulary, head counts,
    /// rope settings - describes the model, not the share of it, and a machine
    /// that disagreed about any of it would compute a hidden state the next
    /// machine could not use.
    static func reduced(_ fields: [String: Any],
                        owning split: PipelineSplit) -> [String: Any] {
        var fields = fields
        fields["num_hidden_layers"] = split.endIndex - split.startIndex
        return fields
    }

    /// The reduced configuration, written where the loader can read it.
    ///
    /// Written to a temporary directory rather than into the model directory:
    /// the model directory is shared, verified against published hashes, and
    /// may be read-only, and two ranks on one machine would otherwise write
    /// different layer counts to the same file.
    private func writeConfig(_ fields: [String: Any], alongside directory: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dai-split-\(plan.rank)-of-\(plan.size)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            .write(to: url, options: .atomic)
        return url
    }

    /// Generate, with both machines stepping in lockstep.
    /// What a caller outside this actor gets back: an answer, and whether this
    /// rank is the one that has it.
    public struct Completed: Sendable {
        public let outcome: Outcome
        /// True on the rank holding the output head, which is the only one with
        /// text worth reporting.
        public let isHead: Bool
        public let layers: Range<Int>
        /// Layers in the whole model, before it was divided.
        ///
        /// Kept so the head can describe the division rather than only its own
        /// share of it. A rank that reports `0..<24` says nothing about whether
        /// anything else exists; `0..<24` of 48 says the model was halved.
        public let totalLayers: Int
        /// How many machines the model was divided across.
        public let size: Int

        /// Every rank's layer range, derived rather than collected.
        ///
        /// Only the head sends this, and it sends the whole plan. Each rank
        /// knows its own range, but they report independently and the control
        /// plane answers the caller the moment the head replies - so gathering
        /// ranges from the others would race a response that has already gone
        /// out. The head knows the total and the gang size, so it can rebuild
        /// every range with the same accumulator each rank used to find its own.
        ///
        /// PipelineSplit, not arithmetic repeated here. Boundaries accumulate
        /// rather than multiply - 80 layers over 3 machines gives 27, 27 and 26,
        /// and the obvious formula leaves layer 26 owned by nobody - and a
        /// second implementation of that is a second chance to get it wrong.
        public var layerPlan: [[Int]] {
            guard isHead, size > 1 else { return [] }
            return (0 ..< size).map { rank in
                let s = PipelineSplit(rank: rank, size: size, layerCount: totalLayers)
                return [s.startIndex, s.endIndex]
            }
        }

        /// What this rank reports as the request's cost.
        ///
        /// From the head only, and both numbers together. Every rank tokenises
        /// the same prompt so every rank knows what it cost - but the control
        /// plane answers the request from rank 0, so a count sent by any other
        /// rank is a number nobody reads. Sending them anyway would not be
        /// harmless either: two ranks reporting the same prompt is the shape of
        /// a bill that says a request cost twice what it did.
        public var reported: (prompt: Int, completion: Int) {
            isHead ? (outcome.promptTokens, outcome.tokens) : (0, 0)
        }
    }

    /// Load and generate without handing `Loaded` across an actor boundary.
    ///
    /// `Loaded` carries the model and tokenizer, neither of which is Sendable
    /// and neither of which should be: they are large, mutable, and belong to
    /// the actor that built them. The by-hand path gets away with taking them
    /// out because it runs at top level with no isolation to cross. A loop that
    /// is an actor cannot, so the two steps stay inside and only the answer
    /// leaves.
    /// Build this machine's share if it is not already built.
    ///
    /// Separate from `run` so a machine can be made ready before anything is
    /// asked of it: a split cannot begin until every rank has built its share,
    /// so a cold gang pays the slowest machine's load before the first token.
    @discardableResult
    public func prepare(directory: URL) async throws -> Bool {
        if built != nil { return false }
        built = try await load(directory: directory)
        return true
    }

    public func run(directory: URL, prompt: String, maxTokens: Int) async throws -> Completed {
        try await prepare(directory: directory)
        guard let loaded = built else { throw Failure.notPipelineable(plan.modelId) }
        let outcome = try generate(loaded, prompt: prompt, maxTokens: maxTokens)
        return Completed(outcome: outcome, isHead: loaded.split.isLast,
                         layers: loaded.split.startIndex ..< loaded.split.endIndex,
                         totalLayers: loaded.totalLayers, size: loaded.split.size)
    }

    /// One conversation's prefix, kept between requests.
    ///
    /// The single-machine path has had this since 6125f8f9 - 47.2s down to 0.57s
    /// on a repeated prefix - and it never crossed the split boundary. Nothing
    /// was removed: SplitRunner has started from a fresh cache since its first
    /// commit, so the same model silently lost its cache the moment its group
    /// became a split.
    private let promptCache = PromptCache()

    /// The share's own cache gets the same budget as a whole model would. Each
    /// rank holds only its own layers, and `PromptCache` measures what it
    /// actually allocated, so this needs no adjusting for the split.
    public func setPromptCacheBudget(gb: Double?) {
        promptCache.setBudget(bytes: PromptCache.affordableBytes(
            askedGb: gb, physicalMemoryGb: MLXRuntime.physicalMemoryGb))
    }

    /// Whether this machine can honour what rank 0 proposed.
    ///
    /// The whole safety of the mechanism is here, so it is a function rather
    /// than a few lines inside a network exchange: a version that trusted the
    /// proposal, or compared only lengths, would pass every naive test and
    /// answer wrongly on real hardware.
    ///
    /// Three ways to say no, and each has to be a no. Nothing proposed. Nothing
    /// cached here - a restarted rank. And a prefix of the right length that is
    /// not the right tokens, which a length comparison cannot see: two machines
    /// can hold 1,600 tokens of different prompts, and that is a state a
    /// dedicated gang should never reach. "Should never" is what layer 26 taught
    /// this codebase.
    static func accepts(proposal: (reusable: Int, digest: [Int32]),
                        mine: (reusable: Int, digest: [Int32])?,
                        prompt: [Int]) -> Bool {
        guard proposal.reusable > 0, proposal.reusable <= prompt.count else { return false }
        guard let mine, mine.reusable >= proposal.reusable else { return false }
        // Hashed from this machine's own prompt, not from what arrived. Trusting
        // the sender's digest would verify the proposal against itself.
        return PromptCache.digest(of: Array(prompt[..<proposal.reusable]))
            == proposal.digest
    }

    /// How many tokens of this prompt every machine will skip.
    ///
    /// Rank 0 proposes, every other rank verifies, and a single objection makes
    /// the answer zero for everybody. No rank acts on its own opinion: the
    /// correctness rule is that a reused prefix must be identical, not similar,
    /// and here it has to be identical *across machines*.
    ///
    /// A machine with no cache offers nothing, so a restarted rank forces a full
    /// prefill rather than a disagreement. That costs exactly what every split
    /// request costs today, so the worst case of this whole mechanism is the
    /// behaviour it replaces.
    private func agreeOnReuse(_ loaded: Loaded,
                              promptTokens: [Int]) throws -> PromptCache.Plan {
        let split = loaded.split
        let mine = promptCache.offer(for: promptTokens)

        // Nothing is split: no one to agree with, and the ordinary rule applies.
        guard split.size > 1 else {
            return promptCache.commit(reuse: mine?.reusable ?? 0, for: promptTokens,
                                      model: loaded.model, parameters: .init())
        }

        let agreed: Int
        if split.isLast {
            // Rank 0 holds the output head and answers, so it proposes. A
            // proposal, not an instruction - it is refused by anybody who cannot
            // match it.
            let offered = mine?.reusable ?? 0
            let digest = mine?.digest ?? Array(repeating: Int32(0), count: 8)
            try transport.send(MLXArray([Int32(offered)] + digest), to: split.rank + 1)
            let verdict = try transport.receive(like: MLXArray([Int32(0)]),
                                                from: split.rank + 1)
            agreed = verdict.item(Int32.self) == 1 ? offered : 0
        } else {
            let proposal = try transport.receive(
                like: MLXArray(Array(repeating: Int32(0), count: 9)),
                from: split.rank - 1)
            let words = proposal.asArray(Int32.self)
            let asked = Int(words[0])
            let ok = Self.accepts(proposal: (asked, Array(words[1...])),
                                  mine: mine, prompt: promptTokens)
            try transport.send(MLXArray([Int32(ok ? 1 : 0)]), to: split.rank - 1)
            agreed = ok ? asked : 0
        }

        return promptCache.commit(reuse: agreed, for: promptTokens,
                                  model: loaded.model, parameters: .init())
    }

    public func generate(_ loaded: Loaded, prompt: String, maxTokens: Int) throws -> Outcome {
        let split = loaded.split
        let promptTokens = try loaded.tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": prompt]])

        // What every machine will reuse of the prompt it has already read.
        //
        // Agreed rather than decided, because each rank holds attention state
        // for its own layers only: if one skips 1,600 tokens and another starts
        // fresh, the hidden states do not correspond and the answer is
        // confidently wrong with no error anywhere - the same shape as a layer
        // owned by nobody.
        let plan = try agreeOnReuse(loaded, promptTokens: promptTokens)
        let cache = plan.cache ?? loaded.model.newCache(parameters: nil)
        var produced: [Int] = []

        // Everything that ends generation, from all three places one can be
        // declared. Built once rather than compared three times a token.
        let stops = StopSet(loaded.declaredStops
            .union([loaded.tokenizer.eosTokenId, loaded.tokenizer.unknownTokenId]
                .compactMap { $0 }))

        let started = Date()
        // Only the tokens nobody has read yet. `toProcess` is the whole prompt
        // when nothing was agreed, which is what every split request did before
        // this and what any disagreement still produces.
        var token = try step(loaded, input: MLXArray(plan.toProcess.map { Int32($0) }),
                             cache: cache)
        let firstAt = Date()

        // Tested before appending, never after. The previous order put the token
        // in and noticed on the next lap, so the terminator was decoded into the
        // answer and counted as a completion token: `<|im_end|>` on the end of
        // every split reply.
        //
        // Structured to step only when another token will actually be kept. A
        // wasted forward pass is a full round trip between machines here, which
        // is the one cost this whole arrangement exists to ration.
        while true {
            if stops.ends(token) { break }
            produced.append(token)
            if produced.count >= maxTokens { break }
            token = try step(loaded, input: MLXArray([Int32(token)]), cache: cache)
        }
        let ended = Date()

        return Outcome(
            // Only the machine with the output head has anything to say. The
            // other one has been computing real work and holds no logits worth
            // decoding, so it returns nothing rather than nonsense.
            text: split.isLast ? loaded.tokenizer.decode(tokens: produced) : "",
            tokens: produced.count,
            promptTokens: promptTokens.count,
            promptSeconds: firstAt.timeIntervalSince(started),
            reusedTokens: plan.reused,
            decodeSeconds: ended.timeIntervalSince(firstAt),
            residentGb: Double(GPU.peakMemory) / 1_073_741_824)
    }

    /// Give up if the model recorded a link failure it could not throw.
    ///
    /// This is the whole point of the fault latch. A pipeline failure used to
    /// be a `fatalError`, which killed the daemon on every machine in the gang
    /// - including the harvest work that had nothing to do with the split - and
    /// told the control plane nothing at all. Failing the request instead is
    /// what `runSplit` already knows how to report.
    private func failIfTheLinkBroke() throws {
        if let error = fault.take() { throw error }
    }

    /// One token, on both machines.
    private func step(_ loaded: Loaded, input: MLXArray, cache: [KVCache]) throws -> Int {
        let split = loaded.split
        let logits = loaded.model(input.reshaped([1, -1]), cache: cache)
        let last = logits[0..., -1, 0...]

        if split.isLast {
            // Before anything is sampled. The forward pass cannot throw, so a
            // hidden state that never arrived leaves `last` holding this
            // machine's own embeddings - the right shape and the wrong numbers,
            // which would sample cleanly and answer confident nonsense.
            try failIfTheLinkBroke()
            let chosen = argMax(last, axis: -1)
            eval(chosen)
            let token = chosen.item(Int.self)
            // Told to the other machines rather than assumed. Carried as a
            // tensor because that is what the link moves, and because it keeps
            // the wire format to one thing.
            //
            // Skipped entirely when nothing is split. A single rank is both the
            // first and the last, so there is no peer: broadcasting anyway sent
            // a token to a machine that does not exist and hung waiting for a
            // connection that was never coming.
            if split.size > 1 {
                try transport.send(MLXArray([Int32(token)]), to: split.rank + 1)
            }
            return token
        } else {
            // The logits here are computed from an incomplete model and mean
            // nothing. Evaluated anyway so the send inside the forward pass
            // actually runs: MLX is lazy, and a graph nobody evaluates is a
            // hidden state that never leaves.
            eval(last)
            // After the eval rather than before it, because that is when the
            // send has actually happened and therefore when a failure in it is
            // known. Reported here rather than waiting to time out on the token
            // that is never coming back.
            try failIfTheLinkBroke()
            let told = try transport.receive(like: MLXArray([Int32(0)]),
                                             from: split.rank - 1)
            eval(told)
            return told.item(Int.self)
        }
    }
}
