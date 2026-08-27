import Foundation
import Testing
@testable import DaiAgent
@testable import DaiWorker

/// What a node makes of an embed dispatch before any weights are involved.
///
/// Written against `EmbedRequest.parse` rather than by driving the serve loop,
/// which was the first attempt and the wrong one. The loop declines to take any
/// dispatch until presence, the pause switch and a settling period all agree,
/// so a test that fed it a request got back nothing and looked exactly like a
/// handler refusing to answer. Parsing is the part with the decisions in it,
/// and it needs none of that.
struct EmbedRequestTests {

    static func body(_ inputs: [String], intent: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "operation": .string("embed"),
            "input": .array(inputs.map { .string($0) }),
        ]
        if let intent { fields["inputType"] = .string(intent) }
        return .object(fields)
    }

    @Test("a dispatch naming no model is refused, not served from whatever is held")
    func refusesAnUnnamedModel() {
        // Embedding with whatever weights happened to be resident returns
        // vectors from a different space. They are the right length and the
        // right range, the caller indexes them, and nothing anywhere records
        // that the corpus was embedded by two different models.
        let out = EmbedRequest.parse(modelHash: nil, body: Self.body(["x"]))
        #expect(out == .failure(.noModel))
        #expect(EmbedRequest.Refusal.noModel.reason.contains("named no model"))
    }

    @Test("an empty model name is the same refusal as none at all")
    func refusesAnEmptyModelName() {
        #expect(EmbedRequest.parse(modelHash: "", body: Self.body(["x"])) == .failure(.noModel))
    }

    @Test("a dispatch with nothing to embed is refused, not answered emptily")
    func refusesEmptyInput() {
        // Zero vectors for zero inputs passes every count check between here
        // and the caller, so the refusal has to happen at the only place that
        // knows the request asked for something.
        #expect(EmbedRequest.parse(modelHash: "org/embed", body: Self.body([]))
                == .failure(.noInput))
    }

    @Test("non-string inputs are dropped, and dropping all of them is a refusal")
    func refusesWhenNothingUsableSurvives() {
        let body = JSONValue.object([
            "input": .array([.number(1), .bool(true)]),
        ])
        #expect(EmbedRequest.parse(modelHash: "org/embed", body: body) == .failure(.noInput))
    }

    @Test("a well formed dispatch keeps its inputs in order")
    func parsesInputs() throws {
        let request = try EmbedRequest.parse(
            modelHash: "org/embed",
            body: Self.body(["first", "second", "third"])).get()
        #expect(request.model == "org/embed")
        #expect(request.inputs == ["first", "second", "third"])
    }

    @Test("intent is read from the dispatch")
    func readsIntent() throws {
        let asQuery = try EmbedRequest.parse(modelHash: "m",
                                             body: Self.body(["x"], intent: "query")).get()
        #expect(asQuery.intent == .query)
    }

    @Test("a dispatch that does not say defaults to document")
    func defaultsToDocument() throws {
        // The default matters for models trained with role prefixes: a corpus
        // is embedded far more often than a question is, and a query embedded
        // as a document is the less damaging way round when a plain OpenAI
        // client sends nothing.
        let unsaid = try EmbedRequest.parse(modelHash: "m", body: Self.body(["x"])).get()
        #expect(unsaid.intent == .document)
    }

    @Test("anything that is not query is a document, rather than an error here")
    func unknownIntentIsADocument() throws {
        // The control plane has already refused a third value with a 400. This
        // is the second of the two checks, and at this point failing the whole
        // dispatch would turn a rejected request into a node-side error.
        let odd = try EmbedRequest.parse(modelHash: "m",
                                         body: Self.body(["x"], intent: "passage")).get()
        #expect(odd.intent == .document)
    }
}
