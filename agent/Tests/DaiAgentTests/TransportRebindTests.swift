import Testing
@testable import DaiAgent
@testable import DaiWorker
import MLX

/// A built model outliving the channel it was built against.
///
/// `pipeline(_:transport:fault:)` hands the transport to every layer when the
/// model is constructed, so the link is baked in. Channels are not: one is
/// opened per request and closed on every exit path, deliberately, because a
/// leaked listener does not merely waste a port - it answers, and a dialer will
/// complete a handshake with the corpse of the last request.
///
/// Without rebinding, a built share can serve only the request it was built
/// for, which is why every split request rebuilt its half from disk.
@Suite("pointing a built model at this request's link")
struct TransportRebindTests {
    // Gated on Metal, like every test here that builds an MLXArray: SwiftPM
    // cannot compile MLX's shaders, so these run under xcodebuild.
    @Test("an unbound transport fails at once rather than waiting out the deadline",
          .enabled(if: metalAvailable))
    func unboundThrows() {
        // The important half is *at once*. Blocking until the 120s timeout would
        // report that the peer was slow, when the truth is that nothing was ever
        // connected - two minutes spent to learn the wrong thing.
        let transport = ChannelPipelineTransport()
        #expect(throws: ChannelPipelineTransport.Unbound.self) {
            try transport.send(MLXArray([Int32(1)]), to: 1)
        }
        #expect(throws: ChannelPipelineTransport.Unbound.self) {
            _ = try transport.receive(like: MLXArray([Int32(0)]), from: 0)
        }
    }

    @Test("releasing points it at nothing again", .enabled(if: metalAvailable))
    func releasedIsUnbound() {
        // What happens between requests, and after a share is let go. A
        // transport still holding a closed channel would send into it.
        let transport = ChannelPipelineTransport()
        transport.adopt(PipelineChannel(log: { _ in }))
        transport.adopt(nil)
        #expect(throws: ChannelPipelineTransport.Unbound.self) {
            try transport.send(MLXArray([Int32(1)]), to: 1)
        }
    }

    @Test("says what is wrong in words an operator can act on")
    func explains() {
        // "not connected to a peer for this request" points at the link. A bare
        // timeout points at nothing.
        #expect(ChannelPipelineTransport.Unbound.noChannel.description
            .contains("not connected"))
    }
}

/// What a held share is for.
@Suite("the plan a built share belongs to")
struct SplitPlanTests {
    @Test("the same division of the same model is the same plan")
    func same() {
        #expect(SplitRunner.Plan(modelId: "m", rank: 0, size: 2)
             == SplitRunner.Plan(modelId: "m", rank: 0, size: 2))
    }

    @Test("a different rank or size is a different set of layers")
    func differentLayers() {
        // Which is a different model in memory however alike the plans look, so
        // a share built for one cannot answer for the other.
        let mine = SplitRunner.Plan(modelId: "m", rank: 0, size: 2)
        #expect(mine != SplitRunner.Plan(modelId: "m", rank: 1, size: 2))
        #expect(mine != SplitRunner.Plan(modelId: "m", rank: 0, size: 3))
        #expect(mine != SplitRunner.Plan(modelId: "other", rank: 0, size: 2))
    }

    @Test("says which division it is, for the log that explains a rebuild")
    func describes() {
        #expect("\(SplitRunner.Plan(modelId: "m", rank: 1, size: 3))"
            == "rank 1 of 3 for m")
    }
}
