import Foundation
import Testing
@testable import DaiAgent
@testable import DaiWorker

/// The status file has two writers and one reader, and the reader is the person
/// whose machine it is.
///
/// It went wrong in the way shared state usually does: each loop wrote the whole
/// file from its own partial view, the batch loop wrote far more often, and a
/// machine answering requests all day reported "waiting for work" throughout.
/// Nothing failed and nothing logged. The only symptom was a panel quietly
/// describing a machine that was not this one.
@Suite(.serialized)
struct StatusPublisherTests {
    /// A file per test, so nothing here depends on what ran before it.
    private func publisher() -> (StatusPublisher, String) {
        let path = NSTemporaryDirectory() + "dai-status-\(UUID().uuidString).json"
        return (StatusPublisher(path: path), path)
    }

    private func read(_ path: String) -> AgentStatus? { AgentStatus.read(path: path) }

    @Test("neither writer erases the other")
    func writersCombine() {
        // The bug exactly: batch reports its state, serving reports its own, and
        // whichever wrote last used to be the whole truth.
        let (status, path) = publisher()
        defer { try? FileManager.default.removeItem(atPath: path) }

        status.updateServing(ready: true, activity: nil, requestsAnswered: 3, residentGb: 17)
        status.updateBatch(presence: "ACTIVE", permitted: ["embed"], activity: "waiting",
                           paused: false, pauseReason: nil, pausedByFleet: false,
                           items: 40, units: 2, yields: 0, residentGb: 0)

        let out = read(path)
        #expect(out?.permitted.contains("embed") == true)
        #expect(out?.permitted.contains("serve") == true)
        #expect(out?.itemsCompleted == 40)
        #expect(out?.requestsAnswered == 3)
    }

    @Test("a batch update does not overwrite an active serving state")
    func servingWins() {
        // Serving takes the activity line while it is doing something, because
        // it is the answer to "why is this machine busy": batch work yields and
        // a conversation does not.
        let (status, path) = publisher()
        defer { try? FileManager.default.removeItem(atPath: path) }

        status.updateServing(ready: true, activity: "answering a request",
                             requestsAnswered: 1, residentGb: 17)
        status.updateBatch(presence: "ACTIVE", permitted: ["embed"], activity: "waiting",
                           paused: false, pauseReason: nil, pausedByFleet: false,
                           items: 0, units: 0, yields: 0, residentGb: 0)

        #expect(read(path)?.activity == "answering a request")
    }

    @Test("an idle serving loop leaves the activity line alone")
    func idleServingIsQuiet() {
        // nil means "nothing to say". A serving loop that claimed the panel
        // while idle would hide what the batch loop is doing, which is the same
        // bug pointing the other way.
        let (status, path) = publisher()
        defer { try? FileManager.default.removeItem(atPath: path) }

        status.updateBatch(presence: "LOCKED", permitted: ["embed", "generate"],
                           activity: "running generate", paused: false, pauseReason: nil,
                           pausedByFleet: false, items: 10, units: 1, yields: 0,
                           residentGb: 4)
        status.updateServing(ready: true, activity: nil, requestsAnswered: 0, residentGb: 4)

        #expect(read(path)?.activity == "running generate")
    }

    @Test("the owner's pause reaches the file from the batch loop")
    func pauseIsCarried() {
        // The one control with no override. It is read from the same file, so a
        // pause that failed to appear would look to its owner like a button
        // that did nothing.
        let (status, path) = publisher()
        defer { try? FileManager.default.removeItem(atPath: path) }

        status.updateServing(ready: true, activity: nil, requestsAnswered: 0, residentGb: 0)
        status.updateBatch(presence: "ACTIVE", permitted: [], activity: "paused by you",
                           paused: true, pauseReason: "testing", pausedByFleet: false,
                           items: 0, units: 0, yields: 0, residentGb: 0)

        let out = read(path)
        #expect(out?.paused == true)
        #expect(out?.pauseReason == "testing")
    }

    @Test("what was contributed survives an update that does not mention it")
    func countsPersist() {
        // Each writer knows half the figures. A writer that reset the other's
        // would make a machine appear to have contributed nothing, which is
        // the opposite of what the counter is for.
        let (status, path) = publisher()
        defer { try? FileManager.default.removeItem(atPath: path) }

        status.updateBatch(presence: "LOCKED", permitted: ["embed"], activity: "waiting",
                           paused: false, pauseReason: nil, pausedByFleet: false,
                           items: 1200, units: 48, yields: 3, residentGb: 0)
        status.updateServing(ready: true, activity: nil, requestsAnswered: 7, residentGb: 17)

        let out = read(path)
        #expect(out?.itemsCompleted == 1200)
        #expect(out?.unitsCompleted == 48)
        #expect(out?.requestsAnswered == 7)
    }

    @Test("the file is fresh enough for a reader to trust it")
    func freshness() {
        // isFresh is how the panel tells "idle" from "the daemon died", which
        // look identical and mean opposite things.
        let (status, path) = publisher()
        defer { try? FileManager.default.removeItem(atPath: path) }

        status.updateBatch(presence: "ACTIVE", permitted: ["embed"], activity: "waiting",
                           paused: false, pauseReason: nil, pausedByFleet: false,
                           items: 0, units: 0, yields: 0, residentGb: 0)
        #expect(read(path)?.isFresh == true)
    }
}
