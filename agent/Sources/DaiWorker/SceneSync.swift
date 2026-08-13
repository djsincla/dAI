import DaiAgent
import Foundation

/// Getting a scene onto this machine, and no more of it than necessary.
///
/// The same shape as model sync and deliberately not the same code, because the
/// two have opposite lifetimes and the difference is the whole design. A model
/// is a few gigabytes, fetched once and kept: sync is a background chore that
/// runs when the machine is free. A scene is tens of gigabytes, needed *before*
/// the unit holding it can start, and worthless the moment its job ends.
///
/// So this runs on the critical path, on purpose. A node that leased frame 12
/// and then went off to fetch the scene in the background would hold a lease it
/// could not serve, and the unit would expire and be handed to another machine
/// that would do the same thing. The fetch has to be part of the work.
///
/// What makes that affordable is that it happens once. The second unit of the
/// same job on the same machine finds everything already there and costs a
/// handful of `stat` calls, which is why the manifest is compared rather than
/// the scene re-fetched.
public actor SceneSync {
    public struct Ready: Sendable {
        /// The file the renderer opens, resolved on this machine.
        public let entry: URL
        public let root: URL
        public let fetched: Int
        public let bytes: Int
    }

    public enum Failure: Error, CustomStringConvertible {
        case unsafePath(String)
        case corrupt(String, expected: String, got: String)

        public var description: String {
            switch self {
            case let .unsafePath(p):
                return "the scene names a file that cannot be written safely: \(p)"
            case let .corrupt(path, expected, got):
                return "\(path) arrived wrong: expected \(expected), got \(got)"
            }
        }
    }

    private var controlPlane: any ControlPlaneClient
    private let base: URL
    private let log: @Sendable (String) -> Void

    public init(controlPlane: any ControlPlaneClient, base: URL,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.controlPlane = controlPlane
        self.base = base
        self.log = log
    }

    /// Start presenting a renewed certificate.
    ///
    /// Renewal retires the old certificate the moment the new one is issued, so
    /// anything still holding the old one is refused with "unknown certificate"
    /// - and this loop would go on being refused for the life of the process,
    /// because nothing here ever reloads. That is not hypothetical: it is what
    /// this loop did after the first renewal on real hardware, while the fleet
    /// view reported the machine as simply not holding what it was assigned.
    public func present(_ replacement: any ControlPlaneClient) {
        controlPlane = replacement
    }

    /// What this loop is presenting. Reachable only from a test, which is the
    /// point: the last two times a renewal was not handed on, nothing could
    /// see it until a machine had been locked out of the fleet for hours.
    func presenting() -> any ControlPlaneClient { controlPlane }

    /// Where scenes live on this machine. Beside the models rather than in a
    /// temporary directory: a scene that survives a reboot is a scene the next
    /// unit does not have to fetch, and these are the largest things the fleet
    /// moves.
    public static func defaultBase() -> URL {
        if let override = ProcessInfo.processInfo.environment["DAI_SCENE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/dai/scenes")
    }

    /// A path segment that can be written under our own root and nowhere else.
    ///
    /// The same allow-list the control plane applies on the way in, applied
    /// again here. Both sides check, because this one is the side where being
    /// wrong means writing to an arbitrary path on somebody's workstation as
    /// whatever user the agent runs as.
    static func safeJoin(_ root: URL, _ id: String, _ path: String = "") -> URL? {
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
            + (path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false))
        guard !segments.isEmpty else { return nil }
        for s in segments where !isSafeSegment(String(s)) { return nil }

        var url = root
        for s in segments { url.appendPathComponent(String(s)) }

        // Belt and braces, in case the check above is ever loosened - and
        // compared without standardising, which is the trap.
        //
        // `standardizedFileURL` resolves `/private/tmp` to `/tmp` for a path
        // that exists and leaves it alone for one that does not, so two paths
        // standardised independently can come back as different spellings of
        // the same directory and fail a prefix check that should pass. It cost
        // a live render: the first call created the directory, and the second
        // was told the file it had just made a home for could not be written
        // safely. `/tmp` and `/var/folders` are both symlinked on macOS, so
        // this is the common case rather than the exotic one.
        //
        // Comparing the raw paths is sound here because both are built from the
        // same root object, and every appended segment has already been checked
        // to contain no separator and to be neither "." nor "..".
        let bounded = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(bounded) ? url : nil
    }

    /// Allow-list rather than deny-list, matching the control plane exactly.
    /// Rejecting ".." catches the obvious attempt and misses percent-encoding,
    /// unicode lookalikes and absolute paths; naming what is permitted has no
    /// such gaps.
    static func isSafeSegment(_ s: String) -> Bool {
        guard let first = s.first, first.isASCII, first.isLetter || first.isNumber else {
            return false
        }
        return s.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")
        }
    }

    /// Make sure this machine holds the scene, fetching only what is missing.
    public func ensure(sceneId: String) async throws -> Ready {
        let manifest = try await controlPlane.sceneManifest(id: sceneId)
        guard let root = Self.safeJoin(base, sceneId) else {
            throw Failure.unsafePath(sceneId)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var fetched = 0
        var bytes = 0
        for file in manifest.files {
            guard let destination = Self.safeJoin(base, sceneId, file.path) else {
                throw Failure.unsafePath(file.path)
            }
            // Size rather than hash for the "already here" check. Hashing a
            // 30GB bundle before every unit would cost more than the render,
            // and the hash is still verified for anything actually fetched -
            // which is where a bad file comes from.
            if let have = try? FileManager.default
                .attributesOfItem(atPath: destination.path)[.size] as? Int,
               have == file.sizeBytes {
                continue
            }
            // The client writes to `<destination>.partial` and returns the
            // hash without renaming, so the decision to accept a file is the
            // caller's and is made after checking.
            let got = try await controlPlane.downloadSceneFile(
                sceneId: sceneId, path: file.path, to: destination)
            let temp = destination.appendingPathExtension("partial")
            guard got == file.sha256 else {
                try? FileManager.default.removeItem(at: temp)
                throw Failure.corrupt(file.path, expected: file.sha256, got: got)
            }
            // Renamed only once the hash matches, so an interrupted transfer
            // leaves nothing rather than a file of the right size and the wrong
            // contents - which a renderer would happily open.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            fetched += 1
            bytes += file.sizeBytes
        }
        if fetched > 0 {
            log("scene \(sceneId): fetched \(fetched) file(s), "
                + String(format: "%.1fMB", Double(bytes) / 1_048_576))
        }

        guard let entry = Self.safeJoin(base, sceneId, manifest.entry) else {
            throw Failure.unsafePath(manifest.entry)
        }
        return Ready(entry: entry, root: root, fetched: fetched, bytes: bytes)
    }
}
