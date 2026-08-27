import Foundation
import Testing
@testable import DaiWorker

/// Does this runtime put text where the Python client puts it?
///
/// This is the check the whole endpoint rests on, and it is the one that cannot
/// be replaced by inspection. Every way of getting embedding wrong - the wrong
/// pooling, an unnormalised vector, a missing prefix, padding averaged into the
/// mean - produces floats of the right shape in the right range that
/// compare cleanly by cosine and rank the corpus wrongly. Nothing raises. The
/// only way to know the vectors are right is to compare them against an
/// implementation already known to retrieve correctly.
///
/// `examples/python/rag_embed.py` is that implementation: it built the VCF
/// index this repository ships tests against. The fixture is its output for
/// four strings, and it carries the relationship as well as the numbers, since
/// two implementations could agree on nonsense.
///
/// **These will not run under `swift test`, on any machine.** MLX needs its
/// Metal shader library, and SwiftPM's command line cannot compile it: that is
/// why packaging/build-pkg.sh uses xcodebuild and ships
/// `mlx-swift_Cmlx.bundle`. Run either of those from a plain checkout and MLX
/// fails with "Failed to load the default metallib" before any of this code is
/// reached, which is a property of the project rather than of these tests.
///
/// So the real check is a command, as it is for the ANE:
///
///     dai-agent verify-embed mlx-community/Qwen3-Embedding-0.6B-8bit \
///         agent/Tests/DaiAgentTests/Fixtures/embedding-vectors.json
///
/// which ships in the package and runs on a node against staged weights. What
/// stays here is the fixture check, which needs no MLX, plus these guarded
/// cases for a test runner that does have the shaders. They skip rather than
/// fail so the suite stays green where MLX cannot run, and the skip is not
/// evidence of anything: read the command's verdict instead.
struct EmbedAgreementTests {

    static let modelId = "mlx-community/Qwen3-Embedding-0.6B-8bit"

    struct Fixture: Decodable {
        struct Item: Decodable {
            let text: String
            let intent: String
            let vector: [Float]
        }
        let model: String
        let items: [Item]
    }

    static var fixture: Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/embedding-vectors.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// Whether the weights are staged where `MLXRuntime.hubBase` points.
    static var staged: Bool {
        let dir = MLXRuntime.modelDirectory.appendingPathComponent(modelId)
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("config.json").path)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    @Test("the fixture itself is well formed")
    func fixtureLoads() {
        let f = Self.fixture
        #expect(f.model == Self.modelId)
        #expect(f.items.count == 4)
        #expect(f.items.allSatisfy { $0.vector.count == 1024 })
        // Unit length, so cosine is a dot product on both sides.
        for item in f.items {
            let norm = Self.cosine(item.vector, item.vector).squareRoot()
            #expect(abs(norm - 1) < 0.01, "\(item.text) has norm \(norm)")
        }
    }

    @Test("the agent agrees with the Python client, vector for vector",
          .enabled(if: EmbedAgreementTests.staged))
    func agreesWithPython() async throws {
        let runtime = EmbedRuntime(modelId: Self.modelId)
        try await runtime.load()

        for item in Self.fixture.items {
            let intent: EmbedRuntime.Intent = item.intent == "query" ? .query : .document
            let mine = try await runtime.embed([item.text], intent: intent)[0]
            let agreement = Self.cosine(mine, item.vector)
            // Not 1.0: bf16 weights and a different framework put the last
            // couple of digits somewhere else. Anything below this is a
            // different vector, not a rounding difference.
            #expect(agreement > 0.99,
                    "\(item.intent) \(item.text.prefix(40)): cosine \(agreement)")
        }
        _ = await runtime.unload()
    }

    @Test("and reproduces the ranking, which is what retrieval actually uses",
          .enabled(if: EmbedAgreementTests.staged))
    func reproducesTheRanking() async throws {
        // Two implementations can agree on vectors that rank the corpus wrongly
        // if both share a mistake, so the ordering is asserted separately. The
        // question is about decommissioning a workload domain; measured through
        // Python these score 0.855, 0.519 and 0.353.
        let runtime = EmbedRuntime(modelId: Self.modelId)
        try await runtime.load()

        let question = "how do I decommission a workload domain?"
        let q = try await runtime.embed([question], intent: .query)[0]
        let docs = try await runtime.embed(["Delete a Workload Domain",
                                            "Requirements for Enabling vSAN",
                                            "search and rescue of a lost hiker"],
                                           intent: .document)
        let scores = docs.map { Self.cosine(q, $0) }
        #expect(scores[0] > scores[1], "right section lost to vSAN: \(scores)")
        #expect(scores[1] > scores[2], "vSAN lost to an unrelated sentence: \(scores)")
        #expect(scores[0] > 0.5, "right section only scored \(scores[0])")
        _ = await runtime.unload()
    }

    @Test("a vector does not depend on what it was batched with",
          .enabled(if: EmbedAgreementTests.staged))
    func batchingDoesNotChangeTheAnswer() async throws {
        // The padding mask, asserted through its consequence. Without one, mean
        // pooling averages the padding in, so a short input batched with a long
        // one gets a different vector than it would alone. Nothing about that
        // failure is visible: the vector is still unit length and still
        // plausible, and results simply shift depending on batch composition.
        let runtime = EmbedRuntime(modelId: Self.modelId)
        try await runtime.load()

        let short = "Delete a Workload Domain"
        let long = String(repeating: "virtual infrastructure workload domain ", count: 60)

        let alone = try await runtime.embed([short])[0]
        let batched = try await runtime.embed([short, long])[0]
        let agreement = Self.cosine(alone, batched)
        #expect(agreement > 0.999, "batching moved the vector: cosine \(agreement)")
        _ = await runtime.unload()
    }

    @Test("intent moves the vector only for a model with prefixes",
          .enabled(if: EmbedAgreementTests.staged))
    func intentMatchesTheModelsConvention() async throws {
        let runtime = EmbedRuntime(modelId: Self.modelId)
        try await runtime.load()
        let text = "delete a workload domain"
        let asQuery = try await runtime.embed([text], intent: .query)[0]
        let asDocument = try await runtime.embed([text], intent: .document)[0]
        let agreement = Self.cosine(asQuery, asDocument)
        // Qwen3-Embedding takes no role prefix, so for this model the two are
        // expected to be identical and this asserts that rather than pretending
        // otherwise. Point it at a nomic or E5 model and the same call must
        // produce different vectors; that is what EmbedRuntimePrefixTests
        // covers without needing weights.
        #expect(agreement > 0.999,
                "this model declares no prefixes, so intent must not move the vector: cosine \(agreement)")
        _ = await runtime.unload()
    }
}
