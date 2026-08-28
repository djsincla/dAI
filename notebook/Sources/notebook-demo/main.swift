import Foundation
import NotebookKit

// Writes a notebook, so the format can be checked against the reference client.
//
//     swift run notebook-demo /tmp/Demo.dainotebook
//     python3.11 rag_ask.py --index /tmp/Demo.dainotebook/index.sqlite --retrieve-only "..."
//
// The vectors here are not embeddings. This proves the file is readable by
// rag_ask.py, not that retrieval is any good; that needs the embedder and comes
// with it. Saying so matters, because a compatibility test that quietly checks
// nothing is worse than none.

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "Demo.dainotebook"
let root = URL(fileURLWithPath: path)
try? FileManager.default.removeItem(at: root)

let dimensions = 1024
let package = try NotebookPackage.create(
    at: root,
    manifest: .init(name: "Demo", dimensions: dimensions))

let store = try VectorStore(path: package.indexURL)

// The meta rag_ask.py reads to decide how to embed a question. Written in the
// shape rag_embed.restore expects: a backend name and its state.
try await store.setMeta("backend", "mlx")
// Typed, not a dictionary of strings. Written as [String: String] first, which
// put max_length in the file as "32768" and made the reference client call the
// model with a string where it wanted an int. The file was valid JSON and valid
// SQLite and still wrong, which is the shape of every bug in this area.
struct BackendState: Encodable {
    let model: String
    let max_length: Int
}
try await store.setMeta("backend_state", BackendState(
    model: NotebookPackage.Manifest.defaultModel, max_length: 32768))

let texts = [
    ("Delete a Workload Domain", "Deleting a workload domain is irreversible and removes its vCenter."),
    ("Requirements for Enabling vSAN", "vSAN requires a minimum of three hosts and a dedicated VMkernel adapter."),
    ("Expand a VCF Domain", "Adding a host to an existing domain requires the host to be commissioned first."),
]
let chunks = texts.map { title, body in
    VectorStore.Chunk(citation: title, section: title,
                      chapterName: "Demo notebook",
                      url: "originals/demo.txt", text: "\(title)\n\n\(body)")
}
// Deterministic stand-ins, unit length so the dot product is still a cosine.
let vectors: [[Float]] = (0 ..< chunks.count).map { i in
    var v = [Float](repeating: 0, count: dimensions)
    v[i] = 1
    return v
}
try await store.add(chunks, vectors: vectors)
try await store.setMeta("chunks", chunks.count)
try await store.setMeta("source", "notebook-demo")

try package.append(.init(
    question: "what does deleting a workload domain do?",
    answer: "It is irreversible and removes the domain's vCenter.",
    citations: [.init(citation: "Delete a Workload Domain",
                      section: "Delete a Workload Domain",
                      url: "originals/demo.txt", score: 0.87)],
    k: 6, hybrid: false,
    embeddingModel: NotebookPackage.Manifest.defaultModel,
    answeredBy: "rotorua", presenceState: "LOCKED", seconds: 2.7))

print("wrote \(root.path)")
print("  chunks     \(try await store.count())")
print("  dimensions \(dimensions)")
print("  turns      \(try package.turns().count)")
