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
    public struct Plan: Sendable {
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
    private let channel: PipelineChannel
    /// Where the model records a link failure it had no way to throw. Checked
    /// after every step, before anything is sampled.
    private let fault = PipelineFault()

    public init(plan: Plan, channel: PipelineChannel) {
        self.plan = plan
        self.channel = channel
        self.transport = ChannelPipelineTransport(channel: channel)
    }

    /// Load only this machine's share of the model.
    ///
    /// The split is applied before the weights, so the layers this machine does
    /// not own are never referenced and therefore never read off disk. Loading
    /// the whole model and discarding afterwards would need the memory first,
    /// which is the thing there is not enough of.
    public struct Loaded {
        public let model: any LanguageModel
        public let tokenizer: Tokenizer
        public let split: PipelineSplit
        /// Layers in the whole model, before it was divided. `split` describes
        /// this machine's share and cannot answer "share of what".
        public let totalLayers: Int
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
                      totalLayers: layerCount)
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
    public func run(directory: URL, prompt: String, maxTokens: Int) async throws -> Completed {
        let loaded = try await load(directory: directory)
        let outcome = try generate(loaded, prompt: prompt, maxTokens: maxTokens)
        return Completed(outcome: outcome, isHead: loaded.split.isLast,
                         layers: loaded.split.startIndex ..< loaded.split.endIndex,
                         totalLayers: loaded.totalLayers, size: loaded.split.size)
    }

    public func generate(_ loaded: Loaded, prompt: String, maxTokens: Int) throws -> Outcome {
        let split = loaded.split
        let promptTokens = try loaded.tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": prompt]])

        let cache = loaded.model.newCache(parameters: nil)
        var produced: [Int] = []

        let started = Date()
        var token = try step(loaded, input: MLXArray(promptTokens.map { Int32($0) }),
                             cache: cache)
        let firstAt = Date()
        produced.append(token)

        while produced.count < maxTokens {
            if loaded.tokenizer.eosTokenId == token { break }
            token = try step(loaded, input: MLXArray([Int32(token)]), cache: cache)
            produced.append(token)
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
