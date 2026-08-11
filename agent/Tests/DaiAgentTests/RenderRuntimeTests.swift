import DaiAgent
import Foundation
import Testing
@testable import DaiWorker

/// The renderer's command line, which is where the security property lives.
///
/// A render job is naturally described as "run this file", and a fleet that
/// accepted that description would be one where submitting a job means running
/// code on fifty machines. The work model already forbids it - a unit carries
/// data and can never name an interpreter, a path or a command - and rendering
/// is the easiest place to break it by accident.
struct RenderArgumentTests {
    private let scene = URL(fileURLWithPath: "/var/dai/scenes/abc123/shot.blend")
    private let out = URL(fileURLWithPath: "/var/dai/out/frame_")

    @Test("the output path is set before the frame is rendered")
    func outputBeforeFrame() {
        // Blender applies arguments in order, so --render-frame ahead of
        // --render-output renders to wherever the scene last pointed, which is
        // a path on the machine of whoever saved it. It is silent when it
        // happens and Blender's own help text warns about it.
        let argv = RenderRuntime.arguments(scene: scene, frame: 7, outputPrefix: out)
        let o = try! #require(argv.firstIndex(of: "--render-output"))
        let f = try! #require(argv.firstIndex(of: "--render-frame"))
        #expect(o < f)
    }

    @Test("the frame is the only thing a payload contributes")
    func frameIsANumber() {
        // The frame comes from the unit. It goes on a command line, so it must
        // be a number and nothing else: this is the one payload-derived value
        // in the whole argument list.
        let argv = RenderRuntime.arguments(scene: scene, frame: 42, outputPrefix: out)
        let f = try! #require(argv.firstIndex(of: "--render-frame"))
        #expect(argv[f + 1] == "42")
        #expect(Int(argv[f + 1]) != nil)
    }

    @Test("the machine's own preferences are not read")
    func factoryStartup() {
        // Twice load-bearing. It keeps renders reproducible, since a machine
        // whose owner changed a preference would otherwise produce a frame
        // differing from its neighbours' for no recorded reason. And the agent
        // does not read the artist's configuration on a machine it is a guest
        // on.
        #expect(RenderRuntime.arguments(scene: scene, frame: 1, outputPrefix: out)
            .contains("--factory-startup"))
    }

    @Test("cycles options come after the separator")
    func cyclesOptionsLast() {
        let argv = RenderRuntime.arguments(scene: scene, frame: 1, outputPrefix: out,
                                           device: "METAL", samples: 32)
        let sep = try! #require(argv.firstIndex(of: "--"))
        #expect(argv.firstIndex(of: "--cycles-device")! > sep)
        #expect(argv.firstIndex(of: "--cycles-samples")! > sep)
    }

    @Test("samples are omitted rather than guessed")
    func samplesOptional() {
        // A scene states its own sample count. Substituting a default would
        // silently render somebody's final frame at preview quality.
        #expect(!RenderRuntime.arguments(scene: scene, frame: 1, outputPrefix: out)
            .contains("--cycles-samples"))
    }
}

/// Finding a renderer, and doing without one.
struct RenderLocationTests {
    @Test("a machine with no renderer is an ordinary machine")
    func absentIsFine() {
        // Not a broken install. It still does AI work; it simply never offers
        // the render kind.
        #expect(RenderRuntime.locate(environment: [:], exists: { _ in false }) == nil)
        #expect(RenderRuntime(renderer: nil) == nil)
    }

    @Test("a fleet can pin the exact build")
    func environmentWins() {
        // Two versions of Blender do not necessarily produce the same pixels,
        // and a frame rendered by the wrong one is worse than one not rendered:
        // nothing about it looks wrong until it is beside the others.
        let found = RenderRuntime.locate(environment: ["DAI_BLENDER": "/opt/pinned/blender"],
                                         exists: { _ in true })
        #expect(found?.path == "/opt/pinned/blender")
    }

    @Test("the usual places are tried in order")
    func fallsBackToTheUsualPlaces() {
        let found = RenderRuntime.locate(
            environment: [:], exists: { $0 == "/opt/homebrew/bin/blender" })
        #expect(found?.path == "/opt/homebrew/bin/blender")
    }
}

/// A real render, when there is a renderer to do it with.
///
/// Skipped rather than failed on a machine without Blender, the same way the
/// MLX tests skip without a Metal toolchain. A skip that is reported as a pass
/// would be worse, so the reason is printed.
struct RenderExecutionTests {
    private static let renderer = RenderRuntime.locate()

    /// The factory startup scene - a cube, a camera and a light - saved once.
    /// Generated rather than committed: a 800KB binary in the repository to
    /// test an argument list is a poor trade, and this proves the version of
    /// Blender actually present can read what it writes.
    private func scene(in dir: URL) throws -> URL? {
        guard let renderer = Self.renderer else { return nil }
        let file = dir.appendingPathComponent("cube.blend")
        let save = Process()
        save.executableURL = renderer
        save.arguments = ["--background", "--factory-startup", "--python-expr",
                          "import bpy; bpy.ops.wm.save_as_mainfile(filepath=r'\(file.path)')"]
        save.standardOutput = FileHandle.nullDevice
        save.standardError = FileHandle.nullDevice
        try save.run()
        save.waitUntilExit()
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dai-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("renders a frame and says where it put it")
    func rendersAFrame() async throws {
        guard let runtime = RenderRuntime(renderer: Self.renderer) else {
            print("skipping: no renderer on this machine")
            return
        }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let scene = try scene(in: dir) else {
            print("skipping: could not write a scene")
            return
        }

        let outcome = try await runtime.render(scene: scene, frame: 1,
                                               into: dir.appendingPathComponent("out"),
                                               samples: 16)
        #expect(outcome.frame == 1)
        #expect(FileManager.default.fileExists(atPath: outcome.file.path))
        // A file that exists but is empty is the failure worth catching: it is
        // indistinguishable from success everywhere downstream.
        let size = try FileManager.default
            .attributesOfItem(atPath: outcome.file.path)[.size] as? Int ?? 0
        #expect(size > 1024)
        #expect(outcome.seconds > 0)
    }

    @Test("a missing scene is reported before anything is launched")
    func missingScene() async throws {
        guard let runtime = RenderRuntime(renderer: Self.renderer) else {
            print("skipping: no renderer on this machine")
            return
        }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: RenderRuntime.Failure.self) {
            try await runtime.render(scene: dir.appendingPathComponent("absent.blend"),
                                     frame: 1, into: dir)
        }
    }

    @Test("a render that was stopped does not report a frame")
    func stopping() async throws {
        guard let runtime = RenderRuntime(renderer: Self.renderer) else {
            print("skipping: no renderer on this machine")
            return
        }
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let scene = try scene(in: dir) else {
            print("skipping: could not write a scene")
            return
        }
        // Stopped before it starts, which is the same path a stop mid-render
        // takes: the machine was wanted back, so there is no frame and the unit
        // goes back on the queue rather than being reported done.
        await runtime.stop()
        await #expect(throws: RenderRuntime.Failure.self) {
            try await runtime.render(scene: scene, frame: 1, into: dir)
        }
    }
}

struct RenderLogTests {
    @Test("only the end of the log is kept")
    func tail() {
        // A render writes thousands of progress lines. The last few are where
        // it says what went wrong; the rest is worth nobody's disk.
        let log = (1 ... 500).map { "Fra:1 sample \($0)" }.joined(separator: "\n")
        let tail = RenderRuntime.tail(of: log, lines: 3)
        #expect(tail.contains("sample 500"))
        #expect(!tail.contains("sample 1\n"))
        #expect(tail.split(separator: "/").count == 3)
    }
}
