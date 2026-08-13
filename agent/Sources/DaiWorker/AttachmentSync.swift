import DaiAgent
import Foundation

/// A job's content, on this machine, for exactly as long as the job needs it.
///
/// This replaces fetching from a scene catalogue, which had the wrong lifetime.
/// A catalogue is right for models: a few gigabytes, fetched once, shared by
/// every job, worth keeping. The content of a render job is tens of gigabytes,
/// belongs to whoever submitted it, and is rubbish the moment the job ends.
/// Kept in a catalogue it would sit on this machine forever, and the person who
/// owns the machine would have no reason to know.
///
/// So content is job-scoped on disk as well as in the control plane. It arrives
/// when the first unit of a job is leased here, it is shared by every later
/// unit of the same job, and it is deleted when the job finishes - or, if this
/// machine never sees the last unit, when the sweep notices nothing has touched
/// it in a day.
///
/// Content-addressed, which is what makes the fetch cheap on the second pass:
/// two jobs sharing a texture library share the bytes, and a resubmitted shot
/// fetches only the file that changed.
public actor AttachmentSync {
    public struct Ready: Sendable {
        /// The file the adapter opens, resolved on this machine.
        public let entry: URL
        public let root: URL
        public let fetched: Int
        public let bytes: Int
    }

    public enum Failure: Error, CustomStringConvertible {
        case unsafePath(String)
        case corrupt(String, expected: String, got: String)
        case noEntry(String)

        public var description: String {
            switch self {
            case let .unsafePath(p):
                return "the job names a file that cannot be written safely: \(p)"
            case let .corrupt(path, expected, got):
                return "\(path) arrived wrong: expected \(expected), got \(got)"
            case let .noEntry(job):
                return "job \(job) says nothing about which file to open"
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

    /// Where job content lives on this machine.
    ///
    /// A cache directory, deliberately. macOS may reclaim it under disk
    /// pressure, and every file in it is refetchable, so losing it costs a
    /// download rather than a job. That is the correct place for something the
    /// machine's owner never asked to store.
    public static func defaultBase() -> URL {
        if let override = ProcessInfo.processInfo.environment["DAI_JOB_CACHE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/dai/jobs")
    }

    /// A path that can be written under our own root and nowhere else.
    ///
    /// The same allow-list the control plane applies on the way in, applied
    /// again here, because this is the side where being wrong means writing to
    /// an arbitrary path on somebody's workstation as whatever user the agent
    /// runs as.
    ///
    /// Compared without standardising. `standardizedFileURL` resolves
    /// /private/tmp to /tmp for a path that exists and leaves it alone for one
    /// that does not, so two paths standardised independently come back as
    /// different spellings of one directory - which cost a live render before
    /// it cost a test.
    static func safeJoin(_ root: URL, _ first: String, _ rest: String = "") -> URL? {
        let segments = first.split(separator: "/", omittingEmptySubsequences: false)
            + (rest.isEmpty ? [] : rest.split(separator: "/", omittingEmptySubsequences: false))
        guard !segments.isEmpty else { return nil }
        for s in segments where !isSafeSegment(String(s)) { return nil }

        var url = root
        for s in segments { url.appendPathComponent(String(s)) }
        let bounded = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(bounded) ? url : nil
    }

    static func isSafeSegment(_ s: String) -> Bool {
        guard let first = s.first, first.isASCII, first.isLetter || first.isNumber else {
            return false
        }
        return s.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")
        }
    }

    /// Make sure this machine holds what the job needs, fetching only the gaps.
    public func ensure(jobId: String) async throws -> Ready {
        let manifest = try await controlPlane.jobAttachments(jobId: jobId)
        guard !manifest.entry.isEmpty else { throw Failure.noEntry(jobId) }
        guard let root = Self.safeJoin(base, jobId) else { throw Failure.unsafePath(jobId) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var fetched = 0
        var bytes = 0
        for file in manifest.files {
            guard let destination = Self.safeJoin(base, jobId, file.path) else {
                throw Failure.unsafePath(file.path)
            }
            // Size rather than hash for the "already here" check. Hashing tens
            // of gigabytes before every frame would cost more than the render,
            // and the hash is still verified for anything actually fetched,
            // which is where a bad file comes from.
            if let have = try? FileManager.default
                .attributesOfItem(atPath: destination.path)[.size] as? Int,
               have == file.sizeBytes {
                continue
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            let got = try await controlPlane.downloadBlob(sha256: file.sha256, to: destination)
            let temp = destination.appendingPathExtension("partial")
            guard got == file.sha256 else {
                try? FileManager.default.removeItem(at: temp)
                throw Failure.corrupt(file.path, expected: file.sha256, got: got)
            }
            // Renamed only once the hash matches, so an interrupted transfer
            // leaves nothing rather than a file of the right size and the wrong
            // contents, which a renderer would happily open.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            fetched += 1
            bytes += file.sizeBytes
        }
        if fetched > 0 {
            log("job \(jobId): fetched \(fetched) file(s), "
                + String(format: "%.1fMB", Double(bytes) / 1_048_576))
        }
        // Touched so the sweep can tell a job in progress from one abandoned.
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: root.path)

        guard let entry = Self.safeJoin(base, jobId, manifest.entry) else {
            throw Failure.unsafePath(manifest.entry)
        }
        return Ready(entry: entry, root: root, fetched: fetched, bytes: bytes)
    }

    /// Delete this machine's copy of a finished job.
    ///
    /// Called the moment the control plane says the job is over, which is the
    /// moment the content stops being useful to anybody. Not waiting for a
    /// sweep matters: the difference is a day of somebody else's disk.
    @discardableResult
    public func release(jobId: String) -> Bool {
        guard let root = Self.safeJoin(base, jobId),
              FileManager.default.fileExists(atPath: root.path) else { return false }
        let freed = (try? size(of: root)) ?? 0
        try? FileManager.default.removeItem(at: root)
        log("job \(jobId): released " + String(format: "%.1fMB", Double(freed) / 1_048_576))
        return true
    }

    /// Delete anything left behind.
    ///
    /// The other half of not keeping content. `release` covers every job this
    /// machine sees the end of; this covers the ones it does not - a job
    /// finished by another node, a job cancelled, an agent restarted mid-render.
    /// Without it, "the fleet does not hold your assets" would be true only of
    /// the tidy cases.
    @discardableResult
    public func sweep(olderThan seconds: TimeInterval = 24 * 3600,
                      now: Date = Date()) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

        var removed: [String] = []
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > seconds else { continue }
            try? fm.removeItem(at: entry)
            removed.append(entry.lastPathComponent)
        }
        if !removed.isEmpty {
            log("swept \(removed.count) abandoned job cache(s)")
        }
        return removed
    }

    private func size(of directory: URL) throws -> Int {
        let fm = FileManager.default
        var total = 0
        for case let url as URL in fm.enumerator(at: directory,
                                                 includingPropertiesForKeys: [.fileSizeKey])! {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return total
    }
}
