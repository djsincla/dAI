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
    private let controlPlane: ControlPlaneClient
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

    /// What one pass decided, so a caller can report it without re-deriving it.
    public struct Outcome: Sendable, Equatable {
        public var fetched: [String] = []
        public var alreadyHeld: [String] = []
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
