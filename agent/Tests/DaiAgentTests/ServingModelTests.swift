import Foundation
import Testing
@testable import DaiAgent
@testable import DaiWorker

/// Which model a machine serves, and where that decision lives.
///
/// It belongs to the machine's group, not to the machine. Before this a node
/// served whatever its daemon was started with - one argument in one plist per
/// box, changed by hand - so a group could declare it served a 14B while its two
/// machines ran a 32B and a 30B between them. Nothing disagreed, because nothing
/// was comparing them. This fleet was in exactly that state when somebody looked
/// at the console.
struct ServingModelTests {
    @Test("a machine takes up the model its group serves", .enabled(if: metalAvailable))
    func adoptsTheGroupModel() async throws {
        let cp = FakeControlPlane()
        await cp.setDirectives(.init(servingModel: "mlx-community/Qwen2.5-14B-Instruct-4bit"))

        let handed = Handover()
        let worker = Worker(controlPlane: cp, source: FixedSignals.present(),
                            gpu: MLXRuntime(modelId: "mlx-community/Qwen3-30B-A3B"),
                            onServingModelChanged: { _, named in await handed.set(named) },
                            promoteAfter: 0)
        await worker.run(maxSeconds: 1.5)

        // The serving loop is handed the same runtime, not told to build its
        // own: two runtimes for one model load the weights twice on a machine
        // that can hold them once.
        #expect(await handed.name() == "mlx-community/Qwen2.5-14B-Instruct-4bit")
    }

    @Test("a machine already serving it is left alone", .enabled(if: metalAvailable))
    func noChurnWhenItAlreadyMatches() async throws {
        // Swapping on every beat would unload and reload the weights twice a
        // minute, which is a machine that never finishes answering anything.
        let cp = FakeControlPlane()
        await cp.setDirectives(.init(servingModel: "already-serving-this"))

        let handed = Handover()
        let worker = Worker(controlPlane: cp, source: FixedSignals.present(),
                            gpu: MLXRuntime(modelId: "already-serving-this"),
                            onServingModelChanged: { _, named in await handed.set(named) },
                            promoteAfter: 0)
        await worker.run(maxSeconds: 1.5)

        #expect(await handed.name() == nil)
    }

    @Test("silence is not an instruction to stop serving", .enabled(if: metalAvailable))
    func nilLeavesItAlone() async throws {
        // Null means nobody has said. A group that has not been given a model is
        // not a group asking its machines to unload one.
        let cp = FakeControlPlane()   // directives default to nothing said
        let handed = Handover()
        let worker = Worker(controlPlane: cp, source: FixedSignals.present(),
                            gpu: MLXRuntime(modelId: "keep-serving-this"),
                            onServingModelChanged: { _, named in await handed.set(named) },
                            promoteAfter: 0)
        await worker.run(maxSeconds: 1.5)

        #expect(await handed.name() == nil)
    }

    /// Records what the worker handed on, since a closure cannot hold state.
    actor Handover {
        private var named: String?
        func set(_ n: String) { named = n }
        func name() -> String? { named }
    }
}
