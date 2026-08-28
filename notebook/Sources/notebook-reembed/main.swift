import Foundation
import NotebookKit

// Re-embed a notebook with a model this app can run.
//
//     notebook-reembed <Notebook.dainotebook> [model]
//
// The chunks are already there: an index carries the text beside every vector,
// so changing the embedding model means embedding the same passages again
// rather than re-reading and re-chunking the originals. That keeps the
// chunking, the citations and the page numbers exactly as they were, which
// makes the new notebook comparable with the old one.
//
// The old index is kept beside the new one until the new one is written, so an
// interrupted run leaves the notebook queryable by whatever could query it
// before rather than leaving it empty.

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: notebook-reembed <Notebook.dainotebook> [model]")
    exit(2)
}
let root = URL(fileURLWithPath: args[1])
let model = args.count > 2 ? args[2] : NotebookPackage.Manifest.defaultModel

let package = NotebookPackage(root: root)
guard package.isValid else { print("not a notebook: \(root.path)"); exit(1) }

let old = try VectorStore(path: package.indexURL, create: false)
let chunks = try await old.allChunks()
guard !chunks.isEmpty else { print("nothing to re-embed"); exit(1) }
let manifest = try package.manifest()
print("\(manifest.name): \(chunks.count) chunks")
print("  from \(manifest.embeddingModel)")
print("  to   \(model)")

let embedder = Embedder(modelId: model)
print("loading…")
let load = try await embedder.load()
print(String(format: "  loaded in %.1fs", load))

// Written beside the old index and moved into place at the end.
let staging = package.root.appendingPathComponent("index.rebuilding.sqlite")
try? FileManager.default.removeItem(at: staging)
let fresh = try VectorStore(path: staging)

let started = Date()
var done = 0
let batch = 16
while done < chunks.count {
    let window = Array(chunks[done ..< min(done + batch, chunks.count)])
    let vectors = try await embedder.embed(window.map(\.text), intent: .document)
    try await fresh.add(window, vectors: vectors)
    done += window.count
    let rate = Double(done) / Date().timeIntervalSince(started)
    let left = Double(chunks.count - done) / max(rate, 0.01)
    print(String(format: "  %d/%d  %.1f/s  about %.0fs left",
                 done, chunks.count, rate, left))
    fflush(stdout)
}

struct BackendState: Encodable { let model: String; let max_length: Int }
try await fresh.setMeta("backend", "mlx")
try await fresh.setMeta("backend_state",
                        BackendState(model: model, max_length: 32768))
try await fresh.setMeta("chunks", chunks.count)

// Swapped only once the new index is complete.
let retired = package.root.appendingPathComponent("index.previous.sqlite")
try? FileManager.default.removeItem(at: retired)
try FileManager.default.moveItem(at: package.indexURL, to: retired)
try FileManager.default.moveItem(at: staging, to: package.indexURL)

var updated = manifest
updated.embeddingModel = model
updated.dimensions = try await fresh.dimensions()
updated.embeddedBy = "local"
try package.write(updated)

print(String(format: "done in %.0fs. The previous index is kept as "
             + "index.previous.sqlite; delete it when satisfied.",
             Date().timeIntervalSince(started)))
