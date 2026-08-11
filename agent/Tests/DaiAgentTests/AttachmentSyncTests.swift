import CryptoKit
import DaiAgent
import Foundation
import Testing
@testable import DaiWorker

/// A job's content on a borrowed machine, and getting rid of it.
///
/// The fetching half is ordinary. The deleting half is the promise: this is
/// somebody else's workstation, the content is somebody else's work, and tens
/// of gigabytes left behind after a job finishes is the kind of thing nobody
/// notices until a disk is full and the agent gets the blame.
struct AttachmentSyncTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dai-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fake(_ files: [String: Data], entry: String) async -> FakeControlPlane {
        let cp = FakeControlPlane()
        await cp.serveAttachments(
            ControlPlane.SceneManifest(
                id: "job-1", entry: entry,
                files: files.map { .init(path: $0.key, sizeBytes: $0.value.count,
                                         sha256: hash($0.value)) }),
            blobs: Dictionary(uniqueKeysWithValues: files.map { (hash($0.value), $0.value) }))
        return cp
    }

    @Test("fetches what the job needs and says what to open")
    func fetches() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp = await fake(["shot.blend": Data(repeating: 7, count: 2048),
                             "tex/wood.png": Data(repeating: 3, count: 512)],
                            entry: "shot.blend")

        let ready = try await AttachmentSync(controlPlane: cp, base: dir).ensure(jobId: "job-1")
        #expect(ready.entry.lastPathComponent == "shot.blend")
        #expect(FileManager.default.fileExists(atPath: ready.entry.path))
        #expect(FileManager.default.fileExists(
            atPath: ready.root.appendingPathComponent("tex/wood.png").path))
        #expect(ready.fetched == 2)
    }

    @Test("the second frame of a job fetches nothing")
    func secondFrameIsFree() async throws {
        // What makes fetching on the critical path affordable. Content is tens
        // of gigabytes; a fleet that re-fetched per frame would spend its
        // evening copying rather than rendering.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp = await fake(["shot.blend": Data(repeating: 7, count: 2048)], entry: "shot.blend")
        let sync = AttachmentSync(controlPlane: cp, base: dir)

        _ = try await sync.ensure(jobId: "job-1")
        #expect(try await sync.ensure(jobId: "job-1").fetched == 0)
        #expect(await cp.blobRequests.count == 1)
    }

    @Test("content that arrived wrong is refused, not rendered")
    func refusesCorruption() async throws {
        // A truncated texture has a plausible size and renders. The frame comes
        // out wrong rather than missing, which is the failure that survives all
        // the way to a finished sequence.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp = FakeControlPlane()
        let bytes = Data(repeating: 7, count: 2048)
        await cp.serveAttachments(
            ControlPlane.SceneManifest(
                id: "job-1", entry: "shot.blend",
                files: [.init(path: "shot.blend", sizeBytes: 2048,
                              sha256: String(repeating: "a", count: 64))]),
            blobs: [String(repeating: "a", count: 64): bytes])

        await #expect(throws: AttachmentSync.Failure.self) {
            try await AttachmentSync(controlPlane: cp, base: dir).ensure(jobId: "job-1")
        }
        // Nothing left under the real name for a renderer to open.
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("job-1/shot.blend").path))
    }

    @Test("a job cannot write outside its own directory")
    func refusesTraversal() {
        // The side where being wrong means writing to an arbitrary path on
        // somebody's workstation, as whatever user the agent runs as.
        let root = URL(fileURLWithPath: "/var/dai/jobs")
        #expect(AttachmentSync.safeJoin(root, "job-1", "../../etc/passwd") == nil)
        #expect(AttachmentSync.safeJoin(root, "..", "x") == nil)
        #expect(AttachmentSync.safeJoin(root, "job-1", "/etc/passwd") == nil)
        #expect(AttachmentSync.safeJoin(root, "job-1", "tex/../../out") == nil)
        #expect(AttachmentSync.safeJoin(root, "job-1", "tex/wood.png")?.path
            == "/var/dai/jobs/job-1/tex/wood.png")
    }

    @Test("the same file resolves the same way before and after it exists")
    func stableUnderSymlinkedRoots() throws {
        // standardizedFileURL resolves /private/tmp to /tmp for a path that
        // exists and leaves it alone for one that does not, so two paths
        // standardised independently came back as different spellings of one
        // directory. It cost a live render before it cost a test, and /tmp and
        // /var/folders are both symlinked on macOS.
        let root = URL(fileURLWithPath: "/private/tmp/dai-attach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = AttachmentSync.safeJoin(root, "job-1", "shot.blend")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("job-1"), withIntermediateDirectories: true)
        let after = AttachmentSync.safeJoin(root, "job-1", "shot.blend")
        #expect(before != nil)
        #expect(before?.path == after?.path)
    }

    @Test("a finished job leaves nothing behind")
    func releaseDeletesEverything() async throws {
        // The promise. Not "eventually", not "when the cache fills": the moment
        // the job is over.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp = await fake(["shot.blend": Data(repeating: 7, count: 4096),
                             "tex/wood.png": Data(repeating: 1, count: 4096)],
                            entry: "shot.blend")
        let sync = AttachmentSync(controlPlane: cp, base: dir)
        let ready = try await sync.ensure(jobId: "job-1")
        #expect(FileManager.default.fileExists(atPath: ready.root.path))

        #expect(await sync.release(jobId: "job-1"))
        #expect(!FileManager.default.fileExists(atPath: ready.root.path))
        // And releasing something already gone is not an error, because two
        // nodes can each see the last unit of a job they shared.
        #expect(await sync.release(jobId: "job-1") == false)
    }

    @Test("a job this machine never saw the end of is swept")
    func sweepsAbandoned() async throws {
        // The half that would otherwise accumulate: a job finished by another
        // node, one cancelled, or an agent restarted mid-render. "The fleet
        // does not keep your assets" has to be true of the untidy cases too.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp = await fake(["shot.blend": Data(repeating: 7, count: 1024)], entry: "shot.blend")
        let sync = AttachmentSync(controlPlane: cp, base: dir)
        _ = try await sync.ensure(jobId: "job-1")

        // Nothing has touched it for two days.
        let root = dir.appendingPathComponent("job-1")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 86_400)],
            ofItemAtPath: root.path)

        #expect(await sync.sweep(olderThan: 86_400) == ["job-1"])
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("a job still being worked on is left alone")
    func sweepSparesLiveJobs() async throws {
        // A render can take hours. Sweeping one out from under the machine
        // doing it would waste the work and look like a corrupt scene.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp = await fake(["shot.blend": Data(repeating: 7, count: 1024)], entry: "shot.blend")
        let sync = AttachmentSync(controlPlane: cp, base: dir)
        _ = try await sync.ensure(jobId: "job-1")

        #expect(await sync.sweep(olderThan: 86_400) == [])
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("job-1/shot.blend").path))
    }
}

/// The loop deleting a job's content when the control plane says it is over.
struct JobReleaseTests {
    private func statusPath() -> String {
        NSTemporaryDirectory() + "dai-release-\(UUID().uuidString).json"
    }

    @Test("the node lets go of a job the moment it is told the job is done")
    func releasesOnFinish() async throws {
        guard let renderer = RenderRuntime() else {
            print("skipping: no renderer on this machine")
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dai-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A unit that will fail to render - the content is not a real scene -
        // because what is under test is the releasing, not the rendering.
        let cp = FakeControlPlane()
        let bytes = Data("not really a blend file".utf8)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        await cp.serveAttachments(
            ControlPlane.SceneManifest(
                id: "job-1", entry: "shot.blend",
                files: [.init(path: "shot.blend", sizeBytes: bytes.count, sha256: sha)]),
            blobs: [sha: bytes])
        await cp.finishJobOnReport()
        await cp.queue(ControlPlane.Lease(
            unitId: "unit-1", kind: .render, modelHash: nil, sceneId: nil, jobId: "job-1",
            items: [.object(["id": .string("i1"), "frame": .number(1)])]))

        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let attachments = AttachmentSync(controlPlane: cp, base: dir)
        let worker = Worker(
            controlPlane: cp, source: FixedSignals.away(), gpu: nil, ane: nil,
            status: StatusPublisher(path: path), renderer: renderer,
            attachments: attachments, promoteAfter: 0)
        await worker.run(maxSeconds: 6)

        // Fetched, then let go, without waiting for a sweep.
        #expect(await cp.blobRequests.contains(sha))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("job-1").path))
    }
}
