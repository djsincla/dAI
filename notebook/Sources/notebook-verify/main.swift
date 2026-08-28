import Foundation
import NotebookKit

// Does this app's embedder agree with the agent and the Python client?
//
//     notebook-verify <fixture.json>
//
// A command rather than a test, for the reason the agent's verify-embed is one:
// MLX needs its Metal shader library and SwiftPM cannot compile it, so anything
// touching MLX cannot run under `swift test` on any machine.
//
// The fixture is the agent's, unchanged. Three implementations now produce
// vectors that have to land in the same space, and the only thing that catches
// a disagreement is comparing them: every way of being wrong here yields a
// vector of the right width, in the right range, that ranks a corpus as noise.

struct Fixture: Decodable {
    struct Item: Decodable { let text: String; let intent: String; let vector: [Float] }
    let model: String
    let items: [Item]
}

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "../agent/Tests/DaiAgentTests/Fixtures/embedding-vectors.json"

let fixture = try JSONDecoder().decode(
    Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))

let embedder = Embedder(modelId: fixture.model)
let seconds = try await embedder.load()
print(String(format: "loaded %@ in %.2fs", fixture.model, seconds))

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}

var worst = Float(1)
for item in fixture.items {
    let intent: Embedder.Intent = item.intent == "query" ? .query : .document
    let mine = try await embedder.embed([item.text], intent: intent)[0]
    guard mine.count == item.vector.count else {
        print("REFUSED: \(mine.count) dimensions against the fixture's \(item.vector.count)")
        exit(1)
    }
    let agreement = cosine(mine, item.vector)
    worst = min(worst, agreement)
    print(String(format: "  %-9@ %.4f  %@", item.intent as NSString,
                 agreement, String(item.text.prefix(44))))
}

// Ranking separately: two implementations can agree on vectors and still order
// a corpus differently if they share a mistake.
let q = try await embedder.embed(["how do I decommission a workload domain?"],
                                 intent: .query)[0]
let docs = try await embedder.embed(["Delete a Workload Domain",
                                     "Requirements for Enabling vSAN",
                                     "search and rescue of a lost hiker"],
                                    intent: .document)
let scores = docs.map { cosine(q, $0) }
print(String(format: "ranking: %.3f > %.3f > %.3f", scores[0], scores[1], scores[2]))
let ordered = scores[0] > scores[1] && scores[1] > scores[2]

if worst > 0.99 && ordered {
    print(String(format: "VERDICT: agrees (worst %.4f). A notebook embedded here "
                 + "can be queried by the fleet and by rag_ask.py.", worst))
} else {
    print(String(format: "VERDICT: DISAGREES (worst %.4f, ordered %@). The "
                 + "vectors are plausible and wrong.", worst, ordered ? "yes" : "no"))
    exit(1)
}
