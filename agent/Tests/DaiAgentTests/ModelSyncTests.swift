import CryptoKit
import Foundation
import Testing
@testable import DaiAgent
@testable import DaiWorker

/// Fetching the weights a machine has been told to hold.
///
/// This is the half that makes assignment mean anything, and it is also the
/// half that can quietly ruin a fleet: a node that accepts a truncated shard
/// will load it, fail strangely, and look like a hardware fault. Every test
/// here is about refusing bytes rather than fetching them.
@Suite(.serialized)
struct ModelSyncTests {
    private func tempBase() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dai-sync-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func model(_ id: String, files: [(String, Data)]) -> ControlPlane.AssignedModel {
        ControlPlane.AssignedModel(
            id: id, runtime: "mlx", kind: "generate",
            files: files.map { name, data in
                ControlPlane.ModelFile(path: name, sizeBytes: data.count, sha256: sha(data))
            })
    }

    @Test("fetches a model it has been assigned and does not have")
    func fetchesAssigned() async throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let weights = Data("weights".utf8)

        let cp = FakeControlPlane()
        await cp.setAssigned([model("org/model", files: [("a.safetensors", weights)])])
        await cp.setContents(["org/model/a.safetensors": weights])

        let sync = ModelSync(controlPlane: cp, base: base,
                             status: StatusPublisher(path: base.appendingPathComponent("s").path))
        let outcome = await sync.sync(mayTransfer: true)

        #expect(outcome.fetched == ["org/model"])
        // Written in the layout swift-transformers reads, which is org/repo and
        // not the models--org--repo form the Python client uses. The wrong one
        // produces a directory that looks right and is never found.
        let landed = base.appendingPathComponent("models/org/model/a.safetensors")
        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect(try Data(contentsOf: landed) == weights)
    }

    @Test("refuses bytes whose hash does not match")
    func refusesWrongHash() async throws {
        // The whole reason this is not an rsync. A truncated shard has a
        // plausible size and a wrong hash, and surfaces much later as a
        // corrupt-weights crash on whichever machine loads it first.
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let cp = FakeControlPlane()
        await cp.setAssigned([model("org/model", files: [("a.safetensors", Data("good".utf8))])])
        await cp.setContents(["org/model/a.safetensors": Data("corrupted".utf8)])

        let sync = ModelSync(controlPlane: cp, base: base,
                             status: StatusPublisher(path: base.appendingPathComponent("s").path))
        let outcome = await sync.sync(mayTransfer: true)

        #expect(outcome.fetched.isEmpty)
        #expect(outcome.failed["org/model"] != nil)
        // Nothing under the real name, so nothing can be loaded. A rejected
        // file that stayed on disk would be indistinguishable from a good one
        // to everything downstream.
        let landed = base.appendingPathComponent("models/org/model/a.safetensors")
        #expect(!FileManager.default.fileExists(atPath: landed.path))
    }

    @Test("does not transfer while somebody is at the machine")
    func waitsForAnIdleMachine() async {
        // Seventeen gigabytes of disk and network is exactly as noticeable as
        // inference to somebody editing video off the same disk, and the only
        // guarantee this product makes to the person at the keyboard is that it
        // gets out of the way.
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let cp = FakeControlPlane()
        await cp.setAssigned([model("org/model", files: [("a.bin", Data("x".utf8))])])

        let sync = ModelSync(controlPlane: cp, base: base,
                             status: StatusPublisher(path: base.appendingPathComponent("s").path))
        let outcome = await sync.sync(mayTransfer: false)

        #expect(outcome.fetched.isEmpty)
        #expect(await cp.downloads.isEmpty)
        // Said out loud, because a machine missing weights because somebody is
        // using it looks identical to one failing to fetch them.
        #expect(outcome.skipped != nil)
    }

    @Test("does not refetch what it already holds")
    func skipsCompleteModels() async throws {
        // A node asks on a timer, and a fleet that re-downloaded on every pass
        // would saturate the network it shares with the people it is borrowing
        // machines from.
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let weights = Data("weights".utf8)

        let dir = base.appendingPathComponent("models/org/model")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try weights.write(to: dir.appendingPathComponent("a.safetensors"))

        let cp = FakeControlPlane()
        await cp.setAssigned([model("org/model", files: [("a.safetensors", weights)])])

        let sync = ModelSync(controlPlane: cp, base: base,
                             status: StatusPublisher(path: base.appendingPathComponent("s").path))
        let outcome = await sync.sync(mayTransfer: true)

        #expect(outcome.alreadyHeld == ["org/model"])
        #expect(await cp.downloads.isEmpty)
    }

    @Test("fetches only the shard that is missing")
    func fetchesOnlyWhatIsMissing() async throws {
        // Per file rather than per model: refetching 18GB because one shard of
        // four failed is the difference between a transfer that finishes
        // overnight and one that never does.
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let one = Data("shard one".utf8), two = Data("shard two".utf8)

        let dir = base.appendingPathComponent("models/org/model")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try one.write(to: dir.appendingPathComponent("a.bin"))

        let cp = FakeControlPlane()
        await cp.setAssigned([model("org/model", files: [("a.bin", one), ("b.bin", two)])])
        await cp.setContents(["org/model/b.bin": two])

        let sync = ModelSync(controlPlane: cp, base: base,
                             status: StatusPublisher(path: base.appendingPathComponent("s").path))
        _ = await sync.sync(mayTransfer: true)

        #expect(await cp.downloads == ["org/model/b.bin"])
    }

    @Test("builds a file URL that survives a model id containing a slash")
    func modelFileURLIsNotDoubleEncoded() {
        // appendingPathComponent percent-encodes what it is given, so an
        // already-encoded %2F came back as %252F and every download 404'd
        // against a route that was working perfectly. The same method mangled a
        // query string earlier in this project, in the same silent way.
        let url = ControlPlane.modelFileURL(
            base: URL(string: "https://cp.example:8452")!,
            modelId: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            path: "model.safetensors")
        #expect(url == "https://cp.example:8452/agent/v1/models/"
            + "mlx-community%2FQwen2.5-1.5B-Instruct-4bit/files/model.safetensors")
        #expect(!url.contains("%25"), "double encoded: \(url)")
    }

    @Test("does not produce a double slash when the base has a trailing one")
    func trailingSlashBase() {
        let url = ControlPlane.modelFileURL(
            base: URL(string: "https://cp.example:8452/")!,
            modelId: "org/model", path: "a.bin")
        #expect(!url.contains("8452//"), "double slash: \(url)")
    }

    @Test("says so when it cannot ask what to hold")
    func reportsUnreachableControlPlane() async {
        // A `try?` here made a node that could not reach the endpoint
        // indistinguishable from one with nothing assigned. This project has
        // already lost a day to exactly that: a lease request 404'd, the error
        // was discarded, and a node polled a full queue forever finding no work.
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let cp = FailingControlPlane()
        let sync = ModelSync(controlPlane: cp, base: base,
                             status: StatusPublisher(path: base.appendingPathComponent("s").path))
        let outcome = await sync.sync(mayTransfer: true)

        #expect(outcome.failed["*"] != nil)
        #expect(outcome.fetched.isEmpty)
    }

    @Test("asks on a timer rather than on every pass")
    func respectsTheInterval() async {
        // Assignment is a human decision measured in days. A node asking every
        // few seconds turns an idle fleet into constant traffic for nothing.
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let cp = FakeControlPlane()
        await cp.setAssigned([])
        let sync = ModelSync(controlPlane: cp, base: base,
                             status: StatusPublisher(path: base.appendingPathComponent("s").path),
                             interval: 300)

        let now = Date()
        #expect(await sync.syncIfDue(mayTransfer: true, now: now) != nil)
        #expect(await sync.syncIfDue(mayTransfer: true, now: now.addingTimeInterval(60)) == nil)
        #expect(await sync.syncIfDue(mayTransfer: true, now: now.addingTimeInterval(301)) != nil)
    }
}
