import Foundation
import MLXLLM
import Testing
@testable import DaiWorker

/// The layer count each machine is built with.
///
/// This is the number that decides how much of the model exists on a machine,
/// and it has to be right before anything is constructed. An earlier version
/// built the whole model and then kept a slice of the layer array, which was
/// wrong in a way that produced no error: a Module records its children during
/// init and every later reader consults that record, so the shortened array
/// reached the forward pass and nothing else. The model ran twelve layers while
/// being quantised and weight-checked as twenty-four.
struct SplitConfigTests {
    private func layers(of fields: [String: Any]) -> Int {
        fields["num_hidden_layers"] as? Int ?? -1
    }

    @Test("each machine is built with exactly the layers it owns")
    func matchesTheSplit() {
        let whole: [String: Any] = ["num_hidden_layers": 24, "hidden_size": 896]
        for rank in 0 ..< 2 {
            let split = PipelineSplit(rank: rank, size: 2, layerCount: 24)
            #expect(layers(of: SplitRunner.reduced(whole, owning: split)) == 12)
        }
    }

    @Test("an uneven division still adds up")
    func unevenDivision() {
        // 80 layers over 3 machines is 27, 27 and 26. The counts have to sum to
        // 80 and the ranges have to meet exactly: a layer owned by nobody does
        // not fail, it is simply not computed, and the model answers fluently
        // from the wrong network.
        let whole: [String: Any] = ["num_hidden_layers": 80]
        var total = 0
        var expectedStart = 0
        for rank in stride(from: 2, through: 0, by: -1) {
            let split = PipelineSplit(rank: rank, size: 3, layerCount: 80)
            #expect(split.startIndex == expectedStart)
            let count = layers(of: SplitRunner.reduced(whole, owning: split))
            #expect(count == split.endIndex - split.startIndex)
            total += count
            expectedStart = split.endIndex
        }
        #expect(total == 80)
        #expect(expectedStart == 80)
    }

    @Test("nothing else about the model is changed")
    func leavesTheRestAlone() {
        // A machine that disagreed about the hidden size or the head count
        // would produce a hidden state the next machine could not use, and
        // would do it without complaining.
        let whole: [String: Any] = [
            "num_hidden_layers": 24, "hidden_size": 896,
            "num_attention_heads": 14, "vocab_size": 151_936,
        ]
        let reduced = SplitRunner.reduced(
            whole, owning: PipelineSplit(rank: 1, size: 2, layerCount: 24))
        #expect(reduced["hidden_size"] as? Int == 896)
        #expect(reduced["num_attention_heads"] as? Int == 14)
        #expect(reduced["vocab_size"] as? Int == 151_936)
        #expect(reduced.count == whole.count)
    }
}
