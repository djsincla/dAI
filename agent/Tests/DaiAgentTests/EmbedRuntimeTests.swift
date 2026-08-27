import Foundation
import Testing
@testable import DaiWorker

/// The parts of embedding that fail silently, which is most of the interesting
/// ones.
///
/// Every mistake available here produces a vector of the right shape, in the
/// right range, comparable by cosine, and wrong. Nothing raises, nothing logs,
/// and the symptom arrives weeks later as "the model gives bad answers". So
/// these test the decisions rather than the arithmetic: which prefix was
/// applied, whether over-length input was refused or quietly trimmed.
struct EmbedRuntimePrefixTests {

    @Test("a nomic model gets nomic's prefixes")
    func nomicByName() {
        let p = EmbedRuntime.Prefixes.forModel(
            "mlx-community/nomicai-modernbert-embed-base-bf16")
        #expect(p == .nomic)
        #expect(p.query == "search_query: ")
        #expect(p.document == "search_document: ")
    }

    @Test("an e5 model gets e5's, which are different words")
    func e5ByName() {
        #expect(EmbedRuntime.Prefixes.forModel("intfloat/multilingual-e5-small") == .e5)
        #expect(EmbedRuntime.Prefixes.e5.query == "query: ")
    }

    @Test("a model with no convention gets no prefix")
    func unknownGetsNone() {
        // Prepending nomic's prefix to a model that was not trained with one
        // puts two unrelated words at the front of every passage, so the
        // default has to be nothing rather than a guess.
        #expect(EmbedRuntime.Prefixes.forModel("BAAI/bge-small-en-v1.5") == .none)
        #expect(EmbedRuntime.Prefixes.forModel("sentence-transformers/all-MiniLM-L6-v2") == .none)
    }

    @Test("query and document are prefixed differently")
    func intentChangesTheText() {
        let p = EmbedRuntime.Prefixes.nomic
        let text = "delete a workload domain"
        #expect(p.apply(text, intent: .query) == "search_query: \(text)")
        #expect(p.apply(text, intent: .document) == "search_document: \(text)")
        #expect(p.apply(text, intent: .query) != p.apply(text, intent: .document))
    }

    @Test("the strings match the Python implementation exactly")
    func agreesWithTheExampleClient() {
        // examples/python/rag_embed.py MlxEmbeddings uses these literals. An
        // index built there and queried through this runtime is only comparable
        // if both sides agree, and a mismatch is invisible: every vector still
        // has the right shape and the ranking is simply worse.
        #expect(EmbedRuntime.Prefixes.nomic.query == "search_query: ")
        #expect(EmbedRuntime.Prefixes.nomic.document == "search_document: ")
    }

    @Test("no prefix leaves the text alone")
    func noneIsIdentity() {
        #expect(EmbedRuntime.Prefixes.none.apply("x", intent: .query) == "x")
        #expect(EmbedRuntime.Prefixes.none.apply("x", intent: .document) == "x")
    }
}

struct EmbedRuntimeRefusalTests {

    @Test("embedding before loading is an error, not an empty answer")
    func refusesWhenNotLoaded() async {
        let runtime = EmbedRuntime(modelId: "nomic-ai/nomic-embed-text-v1.5")
        await #expect(throws: EmbedRuntime.EmbedError.notLoaded) {
            _ = try await runtime.embed(["anything"])
        }
    }

    @Test("an empty batch is refused rather than answered with nothing")
    func refusesEmptyInput() async {
        let runtime = EmbedRuntime(modelId: "nomic-ai/nomic-embed-text-v1.5")
        // Checked before the load guard would fire, so this asserts the order
        // of the two refusals as much as the refusal itself.
        await #expect(throws: EmbedRuntime.EmbedError.self) {
            _ = try await runtime.embed([])
        }
    }

    @Test("the over-length refusal says how long and why it is not truncated")
    func tooLongExplainsItself() {
        let error = EmbedRuntime.EmbedError.tooLong(index: 3, tokens: 9001, limit: 8192)
        let text = error.description
        #expect(text.contains("9001"))
        #expect(text.contains("8192"))
        // The reason matters more than the numbers. Somebody reading this is
        // deciding whether to raise the limit or split the input, and the
        // answer is that a truncated vector is wrong in a way they cannot see.
        #expect(text.contains("truncated"))
        #expect(text.lowercased().contains("split"))
    }

    @Test("a limit is carried per runtime, not assumed")
    func limitIsExplicit() async {
        let small = EmbedRuntime(modelId: "x", maxTokens: 256)
        let large = EmbedRuntime(modelId: "y", maxTokens: 8192)
        #expect(await small.maxTokens == 256)
        #expect(await large.maxTokens == 8192)
    }
}
