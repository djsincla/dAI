import CryptoKit
import DaiAgent
import Foundation

/// Fetching the weights this machine has been told to hold.
///
/// The half that makes assignment mean anything. Before this, an operator could
/// declare that a pool should hold a model and nothing would happen: weights
/// travelled between machines by scp, checked by reading file sizes off a
/// terminal, and the record of what was where lived in somebody's memory.
///
/// Three decisions, each from something that went wrong:
///
/// **Verified per file, always.** A truncated shard has a plausible size and a
/// wrong hash, and surfaces much later as a corrupt-weights crash on whichever
/// machine loads it first. Hashing every file after transfer is the only way to
/// tell a finished copy from an interrupted one.
///
/// **Never while somebody is at the machine.** Writing seventeen gigabytes is
/// not compute, but it is disk and network, and this product's only real
/// guarantee to the person at the keyboard is that it gets out of the way. A
/// download is exactly as noticeable as inference to somebody editing video off
/// the same disk.
///
/// **One file at a time, resumable in whole files.** A shard that fails is
/// refetched alone rather than restarting the model. Partial-file resume needs
/// range requests the server supports but the bookkeeping is not worth it
/// until a link is slow enough to lose a 5GB transfer repeatedly.
public actor ModelSync {
    private var controlPlane: ControlPlaneClient
    private let base: URL
    private let status: StatusPublisher
    private var lastCheck: Date = .distantPast

    /// How often to ask what this node should hold.
    ///
    /// Slow on purpose. Assignment is a human decision measured in days, and a
    /// node that asks constantly turns an idle fleet into steady traffic
    /// against the control plane for no benefit.
    private let interval: TimeInterval

    public init(controlPlane: ControlPlaneClient, base: URL, status: StatusPublisher,
                interval: TimeInterval = 300) {
        self.controlPlane = controlPlane
        self.base = base
        self.status = status
        self.interval = interval
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

    /// What one pass decided, so a caller can report it without re-deriving it.
    public struct Outcome: Sendable, Equatable {
        public var fetched: [String] = []
        public var alreadyHeld: [String] = []
        /// Held already, but missing the metadata the loader needs, and fixed
        /// without a transfer.
        public var repaired: [String] = []
        public var failed: [String: String] = [:]
        public var skipped: String?
    }

    /// Run one reconciliation pass if enough time has passed.
    ///
    /// `mayTransfer` is the caller's judgement about presence: this actor does
    /// not read the machine, because the loops that do already have a
    /// considered answer and two sources of truth about whether somebody is
    /// present is how a machine ends up being polite in one place and rude in
    /// another.
    @discardableResult
    public func syncIfDue(mayTransfer: Bool, now: Date = Date()) async -> Outcome? {
        guard now.timeIntervalSince(lastCheck) >= interval else { return nil }
        lastCheck = now
        return await sync(mayTransfer: mayTransfer)
    }

    @discardableResult
    public func sync(mayTransfer: Bool) async -> Outcome {
        var outcome = Outcome()
        let assigned: [ControlPlane.AssignedModel]
        do {
            assigned = try await controlPlane.assignedModels()
        } catch {
            // Reported rather than swallowed. A `try?` here would make a node
            // that cannot reach the endpoint indistinguishable from one with
            // nothing assigned, and this codebase has already lost a day to
            // exactly that: a lease request 404'd, the error was discarded, and
            // a node polled a full queue forever finding no work.
            outcome.failed["*"] = "could not ask what to hold: \(error)"
            return outcome
        }
        guard !assigned.isEmpty else { return outcome }

        for model in assigned {
            let dir = directory(for: model)
            if isComplete(model: model, in: dir) {
                // The bytes are here. The sidecars may not be, on any node that
                // fetched this model before they were written, and without them
                // the runtime cannot load what the node correctly holds. Writing
                // them costs nothing and needs no transfer, so it is repaired in
                // place rather than by re-fetching gigabytes that are already
                // right.
                if !metadataComplete(model: model, in: dir) {
                    do {
                        for file in model.files { try writeMetadata(for: file, in: dir) }
                        outcome.repaired.append(model.id)
                    } catch {
                        outcome.failed[model.id] = "could not write load metadata: \(error)"
                        continue
                    }
                }
                outcome.alreadyHeld.append(model.id)
                continue
            }
            guard mayTransfer else {
                // Reported rather than silent. A machine that is missing weights
                // because somebody is using it looks identical to one that is
                // failing to fetch them, and the difference decides whether
                // anybody needs to do anything.
                outcome.skipped = "somebody is at the machine"
                continue
            }
            do {
                try await fetch(model: model, into: dir)
                outcome.fetched.append(model.id)
            } catch {
                outcome.failed[model.id] = String(describing: error)
            }
        }
        return outcome
    }

    // MARK: - Internals

    /// Where a model's files belong, in the layout swift-transformers reads.
    ///
    /// `<base>/models/<org>/<repo>`, not the `models--org--repo` form the
    /// Python hub client writes. Putting them in the Python layout produces a
    /// directory that looks right and is never found, which has happened.
    private func directory(for model: ControlPlane.AssignedModel) -> URL {
        model.id.split(separator: "/").reduce(base.appendingPathComponent("models")) {
            $0.appendingPathComponent(String($1))
        }
    }

    /// Where swift-transformers looks for a file's download metadata.
    ///
    /// `<repo>/.cache/huggingface/download/<path>.metadata`, which is the layout
    /// its own downloader writes.
    private func metadataPath(for file: ControlPlane.ModelFile, in dir: URL) -> URL {
        var url = dir.appendingPathComponent(".cache")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("download")
        for part in file.path.split(separator: "/") {
            url = url.appendingPathComponent(String(part))
        }
        return url.appendingPathExtension("metadata")
    }

    /// Write the sidecar the loader reads when it is offline.
    ///
    /// Without this a model transferred by the fleet cannot be loaded by the
    /// fleet. The runtime loads with `useOfflineMode` on - deliberately, so a
    /// node never fetches weights from the internet - and in that mode
    /// swift-transformers resolves every file through a metadata file its own
    /// downloader writes. We do not use its downloader: the whole point is that
    /// weights come from the control plane, hashed and verified. So the files
    /// arrived correct, complete, and unloadable, and the error named a missing
    /// shard rather than missing metadata:
    ///
    ///     offlineModeError("Metadata not available for model-00004-of-00004.safetensors")
    ///
    /// Three lines: commit hash, etag, timestamp. The etag is the sha256 for
    /// LFS files, which is exactly what the catalogue already records and what
    /// this actor already verified the bytes against. Offline resolution
    /// re-hashes any file whose etag looks like a sha256 and refuses a
    /// mismatch, so writing the catalogue's hash keeps that check meaningful
    /// rather than defeating it.
    private func writeMetadata(for file: ControlPlane.ModelFile, in dir: URL) throws {
        let path = metadataPath(for: file, in: dir)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The commit hash is not something a node can know: the catalogue holds
        // weights, not git history. It is unused by offline resolution and is
        // named rather than faked, so anybody reading one of these files can see
        // where it came from.
        let contents = "dai-catalogue\n\(file.sha256)\n\(Date().timeIntervalSince1970)\n"
        try contents.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Whether every file's sidecar is present.
    ///
    /// Separate from `isComplete` on purpose. A node that already holds a model
    /// from before this existed has the bytes and not the metadata, and making
    /// completeness depend on both would make every such node re-fetch
    /// gigabytes it already has correctly.
    private func metadataComplete(model: ControlPlane.AssignedModel, in dir: URL) -> Bool {
        model.files.allSatisfy {
            FileManager.default.fileExists(atPath: metadataPath(for: $0, in: dir).path)
        }
    }

    /// Present at the right size, which is the cheap check before hashing.
    ///
    /// Size alone is not proof, and is not treated as proof: anything fetched
    /// here was hashed at the moment it was written. This only decides whether
    /// there is work to do.
    private func isComplete(model: ControlPlane.AssignedModel, in dir: URL) -> Bool {
        guard !model.files.isEmpty else { return false }
        return model.files.allSatisfy { file in
            let path = dir.appendingPathComponent(file.path)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size]
                as? Int else { return false }
            return size == file.sizeBytes
        }
    }

    private func fetch(model: ControlPlane.AssignedModel, into dir: URL) async throws {
        for file in model.files {
            let destination = dir.appendingPathComponent(file.path)
            if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size]
                as? Int, size == file.sizeBytes {
                continue  // already have this one
            }
            let got = try await controlPlane.downloadModelFile(
                modelId: model.id, path: file.path, to: destination)
            let temp = destination.appendingPathExtension("partial")
            guard got == file.sha256 else {
                try? FileManager.default.removeItem(at: temp)
                throw Failure.hashMismatch(file: file.path, expected: file.sha256, got: got)
            }
            // Renamed only now, so a file under its real name is always one
            // that hashed correctly. Anything interrupted is left as .partial
            // and refetched rather than loaded.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
        }

        // After the bytes, never before: a sidecar beside an absent or unverified
        // file would tell the loader a file is good when it is not there.
        for file in model.files { try writeMetadata(for: file, in: dir) }
    }

    public enum Failure: Error, CustomStringConvertible {
        case hashMismatch(file: String, expected: String, got: String)

        public var description: String {
            switch self {
            case let .hashMismatch(file, expected, got):
                return "\(file): expected \(expected.prefix(12)), got \(got.prefix(12))"
            }
        }
    }
}
