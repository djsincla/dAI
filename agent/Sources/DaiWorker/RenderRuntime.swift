import DaiAgent
import Foundation

/// Rendering, as a work kind the fleet can actually run.
///
/// The infrastructure around this is the same one that harvests AI work: same
/// presence detection, same policy engine, same enrollment, same leasing. What
/// was missing was the runtime, and that is all this is - Blender, run headless
/// against a scene the node already holds.
///
/// Two properties are load-bearing.
///
/// **It runs out of process.** Not for isolation from crashes alone, though a
/// renderer that segfaults on a malformed scene must not take the agent with it
/// and stop the ANE work that has nothing to do with it. Also because rendering
/// is the one workload here that can be stopped instantly and thrown away: a
/// separate process can be killed the moment somebody touches the keyboard,
/// which is the whole basis on which these machines are borrowed.
///
/// **A unit can never name a command or a path.** The payload supplies a frame
/// number and nothing else that reaches the command line; the scene comes from
/// a directory the caller resolved from the local repository. That is the same
/// rule the work model already states for models, and rendering is where it
/// would be easiest to break: a render job is naturally described as "run this
/// file", and a fleet that accepted that description would be a fleet where
/// submitting a job means executing code on fifty machines.
public actor RenderRuntime {
    public struct Outcome: Sendable {
        public let frame: Int
        public let file: URL
        public let seconds: Double
    }

    public enum Failure: Error, CustomStringConvertible {
        case noRenderer
        case sceneMissing(String)
        case exited(Int32, String)
        case producedNothing(Int)
        case cancelled

        public var description: String {
            switch self {
            case .noRenderer:
                return "no renderer on this machine; render work should not have been leased to it"
            case let .sceneMissing(name):
                return "the scene \(name) is not on this machine"
            case let .exited(code, tail):
                return "the renderer exited \(code): \(tail)"
            case let .producedNothing(frame):
                return "the renderer reported success but wrote no file for frame \(frame)"
            case .cancelled:
                return "stopped because the machine was wanted back"
            }
        }
    }

    /// Where a renderer might be, in the order worth trying.
    ///
    /// The environment variable first so a fleet can point at a specific build:
    /// two versions of Blender do not necessarily produce the same pixels, and
    /// a frame rendered by the wrong one is worse than a frame not rendered,
    /// because nothing about it looks wrong until it is next to the others.
    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var paths: [String] = []
        if let override = environment["DAI_BLENDER"], !override.isEmpty { paths.append(override) }
        paths.append("/Applications/Blender.app/Contents/MacOS/Blender")
        paths.append("/opt/homebrew/bin/blender")
        paths.append("/usr/local/bin/blender")
        return paths
    }

    /// The renderer this machine has, or nil.
    ///
    /// Nil is an ordinary answer, not a broken install. A machine with no
    /// renderer is still a useful fleet member - it does AI work - and simply
    /// never offers the render kind.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        candidates(environment: environment).first(where: exists).map(URL.init(fileURLWithPath:))
    }

    /// The command line, built here rather than anywhere a payload can reach.
    ///
    /// `--factory-startup` matters twice over. It keeps the render reproducible,
    /// since a machine whose owner has changed a preference would otherwise
    /// produce a frame that differs from its neighbours' for no recorded
    /// reason. And it means the agent never reads the artist's configuration at
    /// all, on a machine the agent is a guest on.
    ///
    /// The output path precedes the frame, because Blender applies arguments in
    /// order and `--render-frame` before `--render-output` renders to wherever
    /// the scene last pointed - which is a path on the machine of whoever saved
    /// it. It says so in its own help text, and it is silent when it happens.
    public static func arguments(scene: URL, frame: Int, outputPrefix: URL,
                                 device: String = "METAL",
                                 samples: Int? = nil) -> [String] {
        var argv = [
            "--background", scene.path,
            "--factory-startup",
            "--render-output", outputPrefix.path,
            "--render-format", "PNG",
            "--render-frame", String(frame),
        ]
        // Everything after `--` is for Cycles rather than Blender, and has to
        // come last.
        argv += ["--", "--cycles-device", device]
        if let samples { argv += ["--cycles-samples", String(samples)] }
        return argv
    }

    private let renderer: URL
    private var running: Process?
    private var stopped = false

    public init?(renderer: URL? = RenderRuntime.locate()) {
        guard let renderer else { return nil }
        self.renderer = renderer
    }

    public var rendererPath: String { renderer.path }

    /// Render one frame.
    ///
    /// A frame, rather than a tile or a range of samples, because a frame is
    /// already idempotent and already lands as its own file. Splitting a single
    /// frame by samples divides the work more finely, but the parts then have to
    /// be merged with the right weights, and a merge that is quietly wrong
    /// produces a picture rather than an error.
    public func render(scene: URL, frame: Int, into directory: URL,
                       samples: Int? = nil) async throws -> Outcome {
        guard FileManager.default.fileExists(atPath: scene.path) else {
            throw Failure.sceneMissing(scene.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Blender appends the frame number and the extension to this prefix.
        let prefix = directory.appendingPathComponent("frame_")
        let started = Date()

        let child = Process()
        child.executableURL = renderer
        child.arguments = Self.arguments(scene: scene, frame: frame, outputPrefix: prefix,
                                         samples: samples)
        let out = Pipe()
        child.standardOutput = out
        child.standardError = out

        guard !stopped else { throw Failure.cancelled }
        try child.run()
        running = child

        // Read while it runs. A render writes steadily to stdout and the pipe
        // buffer is finite: waiting for exit before reading deadlocks a long
        // render at whatever the buffer holds, which looks exactly like a hung
        // renderer and is the agent's fault.
        let handle = out.fileHandleForReading
        let log = await Task.detached { () -> String in
            String(data: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value
        child.waitUntilExit()
        running = nil

        if stopped { throw Failure.cancelled }
        guard child.terminationStatus == 0 else {
            throw Failure.exited(child.terminationStatus, Self.tail(of: log))
        }

        let produced = directory.appendingPathComponent(
            String(format: "frame_%04d.png", frame))
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw Failure.producedNothing(frame)
        }
        return Outcome(frame: frame, file: produced, seconds: Date().timeIntervalSince(started))
    }

    /// Allow rendering again.
    ///
    /// Separate from `stop` and called by the loop at the start of a unit,
    /// rather than reset inside `render`. A reset inside `render` would race a
    /// stop issued microseconds earlier and swallow it, which is the one
    /// direction this must never fail in: the cost of a lost stop is a machine
    /// that keeps rendering while its owner watches.
    public func resume() { stopped = false }

    /// Stop, because somebody wants their machine back.
    ///
    /// Terminated rather than asked politely and then waited for. A part-written
    /// frame is thrown away and re-rendered by whoever gets the unit next, which
    /// costs one unit of work; a machine that stays busy for another thirty
    /// seconds while its owner watches costs the program.
    public func stop() {
        stopped = true
        running?.terminate()
        running = nil
    }

    /// The last few lines, which is where a renderer says what went wrong.
    /// The rest is thousands of lines of progress and is worth nobody's disk.
    static func tail(of log: String, lines: Int = 8) -> String {
        log.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(lines).joined(separator: " / ")
    }
}
