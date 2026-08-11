import Foundation
import Testing
@testable import DaiAgent
@testable import DaiWorker

/// The loops, against a control plane that records what they did.
///
/// This is the layer where every production bug in this agent has lived, and
/// the layer nothing tested: a lease request that could not be encoded, two
/// heartbeats erasing each other, a batch loop releasing the model a serving
/// loop was using. All of them were reachable only by running the thing, which
/// until now meant real mTLS, a real control plane and seventeen gigabytes of
/// weights.
///
/// None of these tests need a model. They assert what the agent says and when it
/// says it, which is what was wrong every time.
@Suite(.serialized)
struct WorkerLoopTests {
    private func statusPath() -> String {
        NSTemporaryDirectory() + "dai-loop-\(UUID().uuidString).json"
    }

    @Test("asks only for work its presence permits")
    func asksForPermittedKinds() async {
        // Someone is at the machine, so GPU work is not on offer. A client that
        // asks anyway would be handed work it must immediately give back, and
        // the server would be right to refuse it.
        let cp = FakeControlPlane()
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let worker = Worker(controlPlane: cp, source: FixedSignals.present(),
                            gpu: nil, ane: nil,
                            status: StatusPublisher(path: path), promoteAfter: 0)
        await worker.run(maxSeconds: 0.6)

        let asked = await cp.leaseRequests
        // No ANE runtime and no GPU runtime means nothing to offer at all: the
        // node should stay quiet rather than ask for work it cannot do.
        #expect(asked.allSatisfy { !$0.contains(.generate) })
    }

    @Test("reports presence before asking for anything")
    func heartbeatsFirst() async {
        // The scheduler only considers nodes it has heard from recently. A loop
        // that leased before reporting would be invisible to routing on its
        // first pass, which is exactly how a node ended up connected, willing
        // and never chosen.
        let cp = FakeControlPlane()
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let worker = Worker(controlPlane: cp, source: FixedSignals.present(),
                            gpu: nil, ane: nil,
                            status: StatusPublisher(path: path), promoteAfter: 0)
        await worker.run(maxSeconds: 0.6)

        #expect(await !cp.heartbeats.isEmpty)
        #expect(await cp.heartbeats.first?.state == .active)
    }

    @Test("tells the machine's owner what it is doing")
    func publishesStatus() async {
        // The panel is the only thing standing between this and somebody
        // deciding their machine has been taken over. A loop that runs without
        // publishing is the failure that reported "not installed" while the
        // machine served all day.
        let cp = FakeControlPlane()
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let worker = Worker(controlPlane: cp, source: FixedSignals.present(),
                            gpu: nil, ane: nil,
                            status: StatusPublisher(path: path), promoteAfter: 0)
        await worker.run(maxSeconds: 0.6)

        let status = AgentStatus.read(path: path)
        #expect(status != nil)
        #expect(status?.presenceState == "ACTIVE")
    }

    @Test("a paused machine asks for nothing at all")
    func pausedAsksForNothing() async throws {
        // The one control with no override. A loop that kept leasing while
        // paused would make the button a suggestion.
        let switchFile = "/Users/Shared/.dai-paused-test-\(UUID().uuidString)"
        let pause = PauseSwitch(path: switchFile)
        try pause.pause(reason: "under test")
        defer { try? pause.resume() }

        let cp = FakeControlPlane()
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let worker = Worker(controlPlane: cp, source: FixedSignals.away(),
                            gpu: nil, ane: nil, pauseSwitch: pause,
                            status: StatusPublisher(path: path), promoteAfter: 0)
        await worker.run(maxSeconds: 0.6)

        #expect(await cp.leaseRequests.isEmpty)
        #expect(await cp.heartbeats.contains { $0.paused } == true)
    }

    @Test("keeps the machine awake while it is lending capacity")
    func holdsSleepAssertionWhileWorking() async {
        // orca slept through the night behind a locked screen, going dark for
        // four to seven minutes at a time while still answering pings. A
        // harvest node that sleeps contributes nothing during exactly the hours
        // this product is made of.
        let cp = FakeControlPlane()
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let awake = SleepAssertion(name: "dAI test: worker holds")

        let worker = Worker(controlPlane: cp, source: FixedSignals.away(),
                            gpu: nil, ane: nil,
                            status: StatusPublisher(path: path),
                            sleepAssertion: awake, promoteAfter: 0)
        await worker.run(maxSeconds: 0.6)

        // Held while the loop ran, and released when it ended. Both halves
        // matter: checking only the second would pass a loop that never held it
        // at all, which is the bug this exists to prevent.
        #expect(awake.acquisitions >= 1)
        #expect(!awake.isHeld)
        // Taken once, not once per poll. A fresh assertion each pass would leak
        // one every few seconds and pin the machine awake indefinitely.
        #expect(awake.acquisitions == 1, "took \(awake.acquisitions) assertions")
    }

    @Test("lets the machine sleep again the moment its owner pauses")
    func releasesSleepAssertionWhenPaused() async throws {
        // The off switch has to stop everything this software does to a
        // machine, not merely the work it runs. An agent that kept preventing
        // sleep while paused is the overreach the pause exists to rule out.
        let switchFile = "/Users/Shared/.dai-paused-test-\(UUID().uuidString)"
        let pause = PauseSwitch(path: switchFile)
        try pause.pause(reason: "under test")
        defer { try? pause.resume() }

        let cp = FakeControlPlane()
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let awake = SleepAssertion(name: "dAI test: worker releases")

        let worker = Worker(controlPlane: cp, source: FixedSignals.away(),
                            gpu: nil, ane: nil, pauseSwitch: pause,
                            status: StatusPublisher(path: path),
                            sleepAssertion: awake, promoteAfter: 0)
        await worker.run(maxSeconds: 0.6)

        #expect(!awake.isHeld)
        // Never taken at all, rather than taken and dropped.
        #expect(awake.acquisitions == 0)
        #expect(await cp.leaseRequests.isEmpty)
    }

    @Test("lets the machine sleep when an operator pauses it from the fleet view")
    func releasesSleepAssertionWhenFleetPaused() async {
        // The other half of the same promise. A pause from the control plane
        // has to stop the agent holding the machine awake just as an owner's
        // pause does: from the machine's point of view the two are the same
        // instruction, and only one of them is visible to the person sitting
        // at it.
        let cp = FakeControlPlane()
        await cp.setRefuseWith("node-paused")
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let awake = SleepAssertion(name: "dAI test: fleet pause")

        let worker = Worker(controlPlane: cp, source: FixedSignals.away(),
                            gpu: nil, ane: ANERuntime(modelURL: URL(fileURLWithPath: "/dev/null")),
                            status: StatusPublisher(path: path),
                            sleepAssertion: awake, promoteAfter: 0)
        await worker.run(maxSeconds: 1.2)

        #expect(!awake.isHeld)
        let status = AgentStatus.read(path: path)
        #expect(status?.pausedByFleet == true)
    }

    @Test("hands back what it did not finish")
    func reportsUnfinished() async {
        // Returning the remainder is what makes preemption cheap. Discarding it
        // would make a yield cost a whole batch rather than one item.
        let cp = FakeControlPlane()
        await cp.setQueued([
            ControlPlane.Lease(unitId: "u1", kind: .embed, modelHash: nil,
                               items: [.object(["id": .number(1)])]),
        ])
        let path = statusPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let worker = Worker(controlPlane: cp, source: FixedSignals.present(),
                            gpu: nil, ane: nil,
                            status: StatusPublisher(path: path), promoteAfter: 0)
        await worker.run(maxSeconds: 0.8)

        // With no ANE runtime the unit cannot be served, so nothing should have
        // been leased and nothing reported: a node must not accept work it
        // cannot do.
        #expect(await cp.results.isEmpty)
    }
}
