import Darwin
import Foundation
import NotebookKit

// Ingest one document and report what it costs in memory.
//
//     notebook-ingest <file> [name]
//
// **A command, because the bug this exists for is only visible over an hour.**
// An 8,894 page PDF took the app's footprint from 1.6 GB to a 5.5 GB peak, and
// every diagnosis of that was made from outside the process: Activity Monitor
// says a number is large and never says which allocation made it large. This
// runs the same `Ingest` the app runs, on the same model, and prints MLX's own
// active and cache figures beside the process footprint every few batches, so a
// change can be shown to have worked rather than argued to have worked.
//
// It writes to a scratch notebook that it deletes, so measuring costs nothing
// but time.

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("""
    usage: notebook-ingest <file> [name]

      Ingests one document into a scratch notebook, reporting memory as it goes.
      The notebook is removed at the end unless a name is given.
    """)
    exit(2)
}

// Line buffered, because the interesting use of this is watching a log grow
// over an hour and the default 4 KB block buffering shows nothing until it is
// far too late to be useful.
setvbuf(stdout, nil, _IOLBF, 0)

let source = URL(fileURLWithPath: args[1])
guard FileManager.default.fileExists(atPath: source.path) else {
    print("no file at \(source.path)"); exit(1)
}
// Walk the pages and embed nothing.
//
// The page walk and the embedding grow memory for entirely different reasons -
// autoreleased PDFKit objects against MLX buffers - and measuring them together
// cannot say which fix did what. Reading alone takes forty seconds against an
// hour, so the cheap half is worth being able to measure on its own.
let readOnly = args.contains("--read-only")
let keep = args.count > 2 && !args[2].hasPrefix("--") ? args[2] : nil

/// The number Activity Monitor shows, read from inside the process.
///
/// `phys_footprint` rather than resident size: it is what the memory limit is
/// enforced against and what the machine actually feels, and it counts the
/// compressed and IOKit pages that resident size misses. MLX's buffers are
/// IOAccelerator pages, so resident size would understate exactly the thing
/// being measured.
@Sendable func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                       / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

@Sendable func mb(_ bytes: Int) -> Int { bytes / 1_048_576 }

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("notebook-ingest-\(UUID().uuidString).dainotebook")
let package = try NotebookPackage.create(
    at: root, manifest: .init(name: keep ?? "scratch"))

if readOnly {
    let before = footprint()
    var pagesRead = 0
    var characters = 0
    var lastLine = Date.distantPast
    try DocumentReader.eachPage(of: source) { number, pages, text in
        pagesRead = number
        characters += text.count
        if Date().timeIntervalSince(lastLine) > 2 {
            lastLine = Date()
            print("  page \(number)/\(pages)  footprint \(mb(footprint())) MB "
                + "(+\(mb(footprint() - before)) MB)")
        }
    }
    let after = footprint()
    print("\nread \(pagesRead) pages, \(characters) characters")
    print("footprint \(mb(before)) MB -> \(mb(after)) MB, grew \(mb(after - before)) MB")
    try? FileManager.default.removeItem(at: root)
    exit(0)
}

let embedder = Embedder()
print("loading \(NotebookPackage.Manifest.defaultModel)…")
let loadSeconds = try await embedder.load()
print(String(format: "loaded in %.1fs · %@ · footprint %d MB",
             loadSeconds, Embedder.memory().summary, mb(footprint())))

// A baseline taken after the weights are in, so the growth reported below is
// the growth of the run rather than the size of the model.
let baseline = footprint()
let started = Date()
nonisolated(unsafe) var lastReport = Date.distantPast

let ingest = Ingest(package: package, embedder: embedder)
let written = try await ingest.add(source) { progress in
    guard case let .embeddingPage(page, pages, chunks) = progress.stage else { return }
    // Every four seconds rather than every batch: a line per batch is 1,600
    // lines for one PDF and hides the trend it exists to show.
    guard Date().timeIntervalSince(lastReport) > 4 else { return }
    lastReport = Date()
    let now = footprint()
    print(String(format: "  page %5d/%d  %6d chunks  active %4d MB  cache %4d MB"
                       + "  footprint %4d MB  (+%d MB)",
                 page, pages, chunks,
                 mb(progress.memory.active), mb(progress.memory.cache),
                 mb(now), mb(now - baseline)))
}

let elapsed = Date().timeIntervalSince(started)
let end = footprint()
print(String(format: "\n%d chunks in %.0fs · %@", written, elapsed,
             Embedder.memory().summary))
print("footprint \(mb(end)) MB, grew \(mb(end - baseline)) MB from the baseline")
print("MLX peak \(mb(Embedder.memory().peak)) MB")

if let keep {
    let destination = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/notebookMLX/\(keep).dainotebook")
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.moveItem(at: root, to: destination)
    print("kept at \(destination.path)")
} else {
    try? FileManager.default.removeItem(at: root)
}
