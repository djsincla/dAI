import Testing
@testable import DaiWorker
import MLXLLM

/// What the head tells the control plane about how the model was divided.
///
/// Until this existed, the only record that a split had run was a line in
/// `/var/log/dai/agent.log` on each machine. A caller got back an answer
/// indistinguishable from a single-machine one, and confirming the split meant
/// ssh and two log files.
///
/// The head derives the whole plan rather than each rank reporting its own
/// share. Every rank knows its own range, but they report independently and the
/// control plane answers the caller the moment the head replies, so gathering
/// ranges from the others would race a response that has already gone out.
@Suite("the layer plan the head reports")
struct LayerPlanTests {
    static func done(isHead: Bool, totalLayers: Int, size: Int) -> SplitRunner.Completed {
        SplitRunner.Completed(
            outcome: SplitRunner.Outcome(text: "hello", tokens: 205, promptTokens: 935,
                                         promptSeconds: 0.1, decodeSeconds: 0.2,
                                         residentGb: 4.5),
            isHead: isHead, layers: 0..<24, totalLayers: totalLayers, size: size)
    }

    @Test("the head describes every rank, not only its own share")
    func wholePlan() {
        // 0..<24 says nothing about whether anything else exists. 0..<24 of 48,
        // beside another machine's 24..<48, says the model was halved.
        let plan = Self.done(isHead: true, totalLayers: 48, size: 2).layerPlan
        #expect(plan == [[24, 48], [0, 24]])
    }

    @Test("it agrees with what each rank actually built")
    func agreesWithTheRanks() {
        // The point of deriving rather than hardcoding: the plan is computed
        // with PipelineSplit, which is the same type each rank used to decide
        // which layers to load. If they ever disagreed, the report would be a
        // confident description of something that did not happen.
        let total = 80, size = 3
        let plan = Self.done(isHead: true, totalLayers: total, size: size).layerPlan
        for rank in 0 ..< size {
            let actual = PipelineSplit(rank: rank, size: size, layerCount: total)
            #expect(plan[rank] == [actual.startIndex, actual.endIndex])
        }
    }

    @Test("80 layers over 3 machines leaves no layer to nobody")
    func noOrphanedLayer() {
        // The bug this shape exists to prevent. Boundaries accumulate rather
        // than multiply: the ranks hold 27, 27 and 26, and multiplying this
        // rank's count by its index leaves layer 26 owned by no machine. It does
        // not fail - the model computes without that layer and answers fluently
        // from the wrong network.
        let plan = Self.done(isHead: true, totalLayers: 80, size: 3).layerPlan
        let sorted = plan.sorted { $0[0] < $1[0] }
        #expect(sorted.first?[0] == 0)
        #expect(sorted.last?[1] == 80)
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            #expect(earlier[1] == later[0], "layer \(earlier[1]) is owned by nobody")
        }
        #expect(sorted.map { $0[1] - $0[0] }.reduce(0, +) == 80)
    }

    @Test("every rank is covered exactly once, at several shapes")
    func coversEverything() {
        for (total, size) in [(48, 2), (80, 3), (28, 4), (64, 2), (7, 3)] {
            let plan = Self.done(isHead: true, totalLayers: total, size: size).layerPlan
            #expect(plan.count == size)
            let owned = plan.flatMap { Array($0[0] ..< $0[1]) }.sorted()
            #expect(owned == Array(0 ..< total),
                    "\(total) layers over \(size) machines did not cover the model")
        }
    }

    @Test("a rank that is not the head sends nothing")
    func onlyTheHead() {
        // The others report a completion with no text, which is what tells the
        // control plane they did not fail. A layer plan from them would be a
        // second description of one split, arriving after the answer went out.
        #expect(Self.done(isHead: false, totalLayers: 48, size: 2).layerPlan.isEmpty)
    }

    @Test("an unsplit model reports no plan")
    func notSplit() {
        // Nothing was divided, so there is nothing to evidence. The control
        // plane omits the block entirely rather than reporting one machine.
        #expect(Self.done(isHead: true, totalLayers: 48, size: 1).layerPlan.isEmpty)
    }
}
