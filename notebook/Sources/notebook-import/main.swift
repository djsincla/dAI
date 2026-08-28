import Foundation
import NotebookKit

// Turn an index that already exists into a notebook.
//
//     notebook-import <index.sqlite> <name> [originals...]
//
// The corpora in examples/python took minutes to embed and are already in the
// notebook schema, because that schema is the contract. Importing is a copy and
// a manifest, not a rebuild, and re-embedding them to get a notebook would be
// paying twice for the same vectors.
//
// **The manifest records what the index actually holds, not what this app would
// have chosen.** An index built with all-MiniLM is a 384 dimension notebook and
// says so; one built with bm25 says bm25. Writing the default model over an
// imported index would produce a notebook that names one model and contains
// another, which is the failure this whole area keeps producing and the only
// one that cannot be seen by looking at the vectors.

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("""
    usage: notebook-import <index.sqlite> <name> [originals...]

      Creates ~/Documents/notebookMLX/<name>.dainotebook from an existing index.
    """)
    exit(2)
}

let indexPath = URL(fileURLWithPath: args[1])
let name = args[2]
let originals = args.dropFirst(3).map { URL(fileURLWithPath: $0) }

guard FileManager.default.fileExists(atPath: indexPath.path) else {
    print("no index at \(indexPath.path)"); exit(1)
}

// Read what it is before deciding what to call it.
let source = try VectorStore(path: indexPath, create: false)
let chunks = try await source.count()
let dimensions = try await source.dimensions()
let backend = (try await source.meta("backend"))
    .flatMap { try? JSONDecoder().decode(String.self, from: Data($0.utf8)) } ?? "unknown"

/// The model named inside backend_state, when there is one.
///
/// bm25 has no model: its state is a vocabulary and an idf table. Calling that
/// "unknown model" would be wrong, so the backend name stands in.
struct NamedState: Decodable { let model: String }
let stateJSON = (try await source.meta("backend_state")) ?? "{}"
let model = (try? JSONDecoder().decode(NamedState.self, from: Data(stateJSON.utf8)))?.model
    ?? backend

let library = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/notebookMLX", isDirectory: true)
try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

let root = library.appendingPathComponent(name)
    .appendingPathExtension(NotebookPackage.fileExtension)
try? FileManager.default.removeItem(at: root)

let package = try NotebookPackage.create(at: root, manifest: .init(
    name: name, embeddingModel: model, dimensions: dimensions,
    embeddedBy: "imported from \(indexPath.lastPathComponent)"))

// The index is copied rather than rebuilt. Nothing is re-embedded.
try FileManager.default.copyItem(at: indexPath, to: package.indexURL)

for original in originals where FileManager.default.fileExists(atPath: original.path) {
    try? FileManager.default.copyItem(
        at: original,
        to: package.originalsURL.appendingPathComponent(original.lastPathComponent))
}

let copied = (try? FileManager.default.contentsOfDirectory(
    atPath: package.originalsURL.path))?.count ?? 0
print("\(name).dainotebook")
print("  chunks     \(chunks)")
print("  dimensions \(dimensions.map(String.init) ?? "n/a")")
print("  model      \(model)")
print("  originals  \(copied)")
