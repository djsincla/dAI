import Testing
@testable import DaiAgent
@testable import DaiWorker

/// What a machine does about the model it is holding.
///
/// `nil` from the control plane meant two different things and only one was
/// handled. A group that has not been given a model yet is not an instruction
/// to unload one - that guard is right, and a machine configured with a model
/// in its plist must keep it. But a machine handed back from a stood-down split
/// arrives as the same `nil`, and treating them alike left orca holding half a
/// 32B for a group that no longer existed: 9.45 GB on somebody's workstation
/// for a model no socket would route to, while every request went to the other
/// machine. Memory spent, capacity not gained.
///
/// The machine can tell them apart without being told: is what I am holding
/// mine, or something I adopted.
@Suite("what a machine does about the model it holds")
struct ServingDirectiveTests {
    typealias D = Worker.ServingDirective
    let mine = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit"
    let theirs = "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit"

    @Test("adopts what an enabled group asks for")
    func adopts() {
        #expect(Worker.directive(wanted: theirs, current: mine, configured: mine)
                == .adopt(theirs))
    }

    @Test("does nothing when it already runs what was asked")
    func alreadyRight() {
        #expect(Worker.directive(wanted: mine, current: mine, configured: mine) == .keep)
    }

    @Test("keeps its own model when nobody has said anything")
    func nobodyHasSaid() {
        // The case the original guard was written for, and it stays. A machine
        // configured with a model in its plist, in a group nobody has given a
        // model to, must not be stripped of it.
        #expect(Worker.directive(wanted: nil, current: mine, configured: mine) == .keep)
        #expect(Worker.directive(wanted: "", current: mine, configured: mine) == .keep)
    }

    @Test("releases an adopted model when no group claims it any more")
    func handedBack() {
        // The split tier stood down. The socket already told callers these
        // machines were handed back; that has to be true of the workstation as
        // well as the scheduler.
        #expect(Worker.directive(wanted: nil, current: theirs, configured: mine)
                == .release)
    }

    @Test("a machine with nothing of its own is left alone")
    func noConfiguredModel() {
        // Defensive: with nothing to fall back to, releasing would leave the
        // machine holding no runtime at all. Adopting is already refused on a
        // node with no GPU model, so this should not arise - and if it does,
        // doing nothing is the answer that cannot make things worse.
        #expect(Worker.directive(wanted: nil, current: theirs, configured: nil) == .keep)
    }

    @Test("the three cases are distinguished by one question")
    func theDistinction() {
        // Same input from the control plane, opposite answers, decided entirely
        // by whether the held model is this machine's own.
        #expect(Worker.directive(wanted: nil, current: mine, configured: mine) == .keep)
        #expect(Worker.directive(wanted: nil, current: theirs, configured: mine) == .release)
    }
}

/// Whether a machine holds its model in memory.
///
/// The control plane derives this from the tier and sends it as intent; the
/// node never learns which groups it is in. It reached the agent's Directives
/// and stopped there for one release - decoded, carried, and acted on by
/// nothing - so a cluster group sat cold for four minutes with a readiness
/// strip correctly reporting "the model is not built yet" and nothing ever
/// building it.
@Suite("holding a model loaded")
struct KeepLoadedTests {
    @Test("a control plane too old to say means lazy")
    func absentIsLazy() {
        // Which is what every machine did before this existed, so an older
        // control plane keeps the behaviour it was written against.
        #expect(ControlPlane.Directives().keepLoaded == false)
        #expect(ControlPlane.Directives(servingModel: "m").keepLoaded == false)
    }

    @Test("carries what it was told")
    func carries() {
        #expect(ControlPlane.Directives(servingModel: "m", keepLoaded: true).keepLoaded)
    }

    @Test("the two directives are independent")
    func independent() {
        // A machine can be told to hold what it already has, which is the
        // ordinary case once a cluster group has settled: the model does not
        // change and the instruction to keep it does not stop applying.
        let d = ControlPlane.Directives(renewRequested: true, servingModel: nil,
                                        keepLoaded: true)
        #expect(d.servingModel == nil)
        #expect(d.keepLoaded)
        #expect(d.renewRequested)
    }
}


/// What a machine may warm, and what it must not.
///
/// `MLXRuntime` knows nothing about splits: loading it builds the whole model.
/// So a machine warming half of a 32B took all 18.4 GB to serve 9.45 GB of it,
/// and then never used the result - the split path builds its own model with
/// num_hidden_layers cut to this rank's range. Peak memory became both at once
/// on a machine with a 37.4 GB working set: a mechanism meant to halve memory
/// multiplying it instead.
@Suite("what a machine may warm")
struct WarmEligibilityTests {
    @Test("a whole model on a dedicated group is warmed")
    func wholeModel() {
        let d = ControlPlane.Directives(servingModel: "m", keepLoaded: true, machines: 1)
        #expect(d.keepLoaded)
        #expect(!d.isSplit)
    }

    @Test("a model that runs across machines is not")
    func splitModel() {
        // The instruction to hold it loaded still stands; what must not happen
        // is holding the wrong thing. Doing nothing is strictly better than
        // taking twice the memory for a copy nobody reads.
        let d = ControlPlane.Directives(servingModel: "m", keepLoaded: true, machines: 2)
        #expect(d.keepLoaded)
        #expect(d.isSplit)
    }

    @Test("a control plane too old to say means whole, so warming is skipped safely")
    func absentMeansOne() {
        // Absent has to fail toward the safe side. Treating an unknown model as
        // split would stop warming a machine that should be warm; treating it as
        // whole and warming it wrongly is the failure being fixed. One is a
        // missed optimisation, the other doubles memory - so absent means 1 and
        // an older control plane simply keeps the behaviour it had.
        #expect(ControlPlane.Directives().machines == 1)
        #expect(!ControlPlane.Directives(servingModel: "m", keepLoaded: true).isSplit)
    }

    @Test("a nonsense width is clamped rather than believed")
    func clamped() {
        #expect(ControlPlane.Directives(machines: 0).machines == 1)
        #expect(ControlPlane.Directives(machines: -3).machines == 1)
    }
}
