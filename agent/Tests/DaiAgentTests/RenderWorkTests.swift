import CryptoKit
import DaiAgent
import Foundation
import Testing
@testable import DaiWorker

/// Getting a scene onto a machine, which happens before a frame can start.
///
/// On the critical path on purpose, unlike model sync. A node that leased frame
/// 12 and went off to fetch the scene in the background would hold a lease it
/// could not serve; the unit would expire and be handed to another machine that
/// would do the same thing.
struct SceneSyncTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dai-scene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fake(files: [String: Data], entry: String) async -> FakeControlPlane {
        let cp = FakeControlPlane()
        await cp.serveScene(
            ControlPlane.SceneManifest(
                id: "shot-01", entry: entry,
                files: files.map { .init(path: $0.key, sizeBytes: $0.value.count,
                                         sha256: hash($0.value)) }),
            bytes: files)
        return cp
    }

    @Test("fetches the scene and says where the renderer should look")
    func fetchesAndResolves() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp = await fake(files: ["shot.blend": Data(repeating: 7, count: 4096),
                              "tex.png": Data(repeating: 3, count: 512)],
                      entry: "shot.blend")

        let ready = try await SceneSync(controlPlane: cp, base: dir).ensure(sceneId: "shot-01")
        #expect(ready.entry.lastPathComponent == "shot.blend")
        #expect(FileManager.default.fileExists(atPath: ready.entry.path))
        #expect(ready.fetched == 2)
    }

    @Test("the second unit of a job fetches nothing")
    func secondTimeIsFree() async throws {
        // What makes fetching on the critical path affordable. A scene is tens
        // of gigabytes; a fleet that re-fetched it per frame would spend its
        // evening copying rather than rendering.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp = await fake(files: ["shot.blend": Data(repeating: 7, count: 4096)],
                      entry: "shot.blend")
        let sync = SceneSync(controlPlane: cp, base: dir)

        _ = try await sync.ensure(sceneId: "shot-01")
        let again = try await sync.ensure(sceneId: "shot-01")
        #expect(again.fetched == 0)
        #expect(await cp.sceneRequests.count == 1)
    }

    @Test("a file that arrived wrong is refused, not rendered")
    func rejectsCorruption() async throws {
        // A truncated texture has a plausible size and renders: the frame comes
        // out wrong rather than missing, which is the failure that survives all
        // the way to a finished sequence.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cp = await fake(files: ["shot.blend": Data(repeating: 7, count: 4096)],
                      entry: "shot.blend")
        // The manifest promises one thing and the bytes are another.
        await cp.serveScene(
            ControlPlane.SceneManifest(
                id: "shot-01", entry: "shot.blend",
                files: [.init(path: "shot.blend", sizeBytes: 4096,
                              sha256: String(repeating: "a", count: 64))]),
            bytes: ["shot.blend": Data(repeating: 7, count: 4096)])

        await #expect(throws: SceneSync.Failure.self) {
            try await SceneSync(controlPlane: cp, base: dir).ensure(sceneId: "shot-01")
        }
        // Nothing is left under the real name for a renderer to open.
        let landed = dir.appendingPathComponent("shot-01/shot.blend")
        #expect(!FileManager.default.fileExists(atPath: landed.path))
    }

    @Test("the same file resolves the same way before and after it exists")
    func stableUnderSymlinkedRoots() throws {
        // The bug this exists for. `standardizedFileURL` resolves /private/tmp
        // to /tmp for a path that exists and leaves it alone for one that does
        // not, so two paths standardised independently came back as different
        // spellings of the same directory and failed a containment check that
        // should have passed. It cost a live render: the first call created the
        // directory and the second was told the file it had just made a home
        // for could not be written safely.
        //
        // /tmp and /var/folders are both symlinked on macOS, so this is the
        // ordinary case rather than an exotic one.
        let root = URL(fileURLWithPath: "/private/tmp/dai-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let before = SceneSync.safeJoin(root, "shot-01", "shot.blend")
        #expect(before != nil)

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("shot-01"), withIntermediateDirectories: true)
        let after = SceneSync.safeJoin(root, "shot-01", "shot.blend")
        #expect(after != nil)
        #expect(before?.path == after?.path)
    }

    @Test("a scene cannot write outside its own directory")
    func refusesTraversal() {
        // The side where being wrong means writing to an arbitrary path on
        // somebody's workstation, as whatever user the agent runs as. The
        // control plane checks this on the way in; this is the second check,
        // because that is the one that fails safe if the first is loosened.
        let root = URL(fileURLWithPath: "/var/dai/scenes")
        #expect(SceneSync.safeJoin(root, "shot-01", "../../etc/passwd") == nil)
        #expect(SceneSync.safeJoin(root, "..", "x") == nil)
        #expect(SceneSync.safeJoin(root, "shot-01", "/etc/passwd") == nil)
        #expect(SceneSync.safeJoin(root, "shot-01", "tex/../../out") == nil)
        #expect(SceneSync.safeJoin(root, "shot-01", "sub/tex.png")?.path
            == "/var/dai/scenes/shot-01/sub/tex.png")
    }
}

/// A render unit going through the loop that runs on every machine.
struct RenderUnitTests {
    private func statusPath() -> String {
        NSTemporaryDirectory() + "dai-render-unit-\(UUID().uuidString).json"
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dai-render-unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real scene, so the loop is exercised against a real renderer. Skipped
    /// where there is none, and the reason is printed rather than passed over.
    private func realScene(in dir: URL, renderer: URL) throws -> Data? {
        let file = dir.appendingPathComponent("cube.blend")
        let save = Process()
        save.executableURL = renderer
        save.arguments = ["--background", "--factory-startup", "--python-expr",
                          "import bpy; bpy.ops.wm.save_as_mainfile(filepath=r'\(file.path)')"]
        save.standardOutput = FileHandle.nullDevice
        save.standardError = FileHandle.nullDevice
        try save.run()
        save.waitUntilExit()
        return try? Data(contentsOf: file)
    }

    @Test("a leased frame is rendered and handed back")
    func rendersAndUploads() async throws {
        guard let rendererPath = RenderRuntime.locate(),
              let renderer = RenderRuntime(renderer: rendererPath) else {
            print("skipping: no renderer on this machine")
            return
        }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let blend = try realScene(in: dir, renderer: rendererPath) else {
            print("skipping: could not write a scene")
            return
        }

        let cp = FakeControlPlane()
        await cp.serveScene(
            ControlPlane.SceneManifest(
                id: "shot-01", entry: "cube.blend",
                files: [.init(path: "cube.blend", sizeBytes: blend.count,
                              sha256: SHA256.hash(data: blend)
                                  .map { String(format: "%02x", $0) }.joined())]),
            bytes: ["cube.blend": blend])
        await cp.queue(ControlPlane.Lease(
            unitId: "unit-1", kind: .render, modelHash: nil, sceneId: "shot-01",
            items: [.object(["id": .string("i1"), "frame": .number(1),
                             "samples": .number(8)])]))

        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let worker = Worker(
            controlPlane: cp, source: FixedSignals.away(), gpu: nil, ane: nil,
            status: StatusPublisher(path: path),
            renderer: renderer,
            scenes: SceneSync(controlPlane: cp, base: dir.appendingPathComponent("scenes")),
            promoteAfter: 0)
        await worker.run(maxSeconds: 40)

        // The frame came back. Without this the job reads complete and the
        // sequence has a hole, which nobody notices until it is played.
        let uploads = await cp.uploads
        #expect(uploads.contains { $0.name == "frame_0001.png" && $0.bytes > 1024 })
        #expect(uploads.first?.unit == "unit-1")

        // And the unit was reported done, once.
        let results = await cp.results
        #expect(results.contains { $0.unitId == "unit-1" && $0.completed == 1 })
    }

    @Test("a machine with no renderer asks for everything except render")
    func neverAsks() async throws {
        // A machine with nothing installed asks for nothing, which would pass
        // this test while proving nothing. So it is given an ANE runtime and no
        // renderer: it must still ask for work, and render must not be in it.
        // Offering a kind it cannot run wins leases it can only hand back, and
        // from the fleet view that looks like a node failing everything.
        let cp = FakeControlPlane()
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let worker = Worker(
            controlPlane: cp, source: FixedSignals.away(), gpu: nil,
            // Never run: the loop only counts whether a runtime exists when
            // deciding what to advertise, and nothing is queued for it.
            ane: ANERuntime(modelURL: URL(fileURLWithPath: "/nonexistent.mlpackage")),
            status: StatusPublisher(path: path), promoteAfter: 0)
        await worker.run(maxSeconds: 0.6)

        let asked = await cp.leaseRequests
        #expect(!asked.isEmpty)
        #expect(asked.allSatisfy { $0.contains(.embed) })
        #expect(!asked.contains { $0.contains(.render) })
    }

    @Test("a render unit with no scene fails rather than rendering something else")
    func refusesAScenelessUnit() async throws {
        guard let renderer = RenderRuntime() else {
            print("skipping: no renderer on this machine")
            return
        }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cp = FakeControlPlane()
        await cp.queue(ControlPlane.Lease(
            unitId: "unit-2", kind: .render, modelHash: nil, sceneId: nil,
            items: [.object(["id": .string("i1"), "frame": .number(1)])]))

        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let worker = Worker(
            controlPlane: cp, source: FixedSignals.away(), gpu: nil, ane: nil,
            status: StatusPublisher(path: path), renderer: renderer,
            scenes: SceneSync(controlPlane: cp, base: dir), promoteAfter: 0)
        await worker.run(maxSeconds: 3)

        // Nothing uploaded, and the item comes back rather than being counted.
        #expect(await cp.uploads.isEmpty)
        let results = await cp.results
        #expect(results.contains { $0.unitId == "unit-2" && $0.completed == 0 })
    }
}
