import DaiAgent
import Foundation
import MLXLLM

/// Serves interactive requests pushed down from the control plane.
///
/// Batch work is pulled: the node asks when it is ready, which suits a queue.
/// Interactive requests cannot wait for the next poll, so the node dials out and
/// parks on a long-lived request, and the scheduler pushes down the open
/// connection. Outbound, so no inbound firewall rules and no NAT traversal;
/// pushed, so routing costs milliseconds rather than a poll interval.
///
/// It runs alongside the batch loop rather than inside it. A request arriving
/// while a batch unit is mid-flight must not wait for that unit to finish, and
/// folding both into one loop would make the interactive latency depend on the
/// batch size.
///
/// **This is not for harvested machines.** A conversation needs a resident model
/// and a node that will still be there in a minute, and preemption is fatal to
/// both. The control plane decides where to route; the agent's part is to be
/// honest about what it can serve and to release the model the moment its
/// presence state stops permitting GPU work.
public actor ReverseChannel {
    private var controlPlane: any ControlPlaneClient
    /// Replaced when this machine's group changes what it serves. The batch
    /// loop owns that decision and hands the new runtime over, the same way it
    /// hands over a renewed certificate.
    private var gpu: MLXRuntime?

    /// The embedding model this node currently holds, if any.
    ///
    /// Separate from `gpu` because it is a different model with a different
    /// runtime, and one at a time because a node holding two sets of weights is
    /// twice the resident memory for a machine whose owner may want it back.
    /// Swapping when a request names a different model is the simple policy; a
    /// fleet embedding two corpora at once would want better, and would notice.
    private var embedder: EmbedRuntime?

    /// Whether this node will answer embed dispatches.
    ///
    /// Held separately from `gpu` because the two are different capabilities
    /// and the serve loop gated on the wrong one. `mayServe` required a
    /// generation runtime before taking any dispatch at all, so a node staged
    /// with an embedding model and no chat model held the channel open, was
    /// routed to, and never took the request: the loop declined before the
    /// handler that would have answered it was reached. Nothing logged, because
    /// from the loop's point of view it was correctly refusing to serve.
    private let embeds: Bool
    /// Reported, not used. Both loops heartbeat and each replaces
    /// `resident_models` wholesale, so a loop that can only see half of what
    /// this machine holds erases the other half every twenty seconds - which
    /// made residency flap between the two answers and the readiness strip
    /// flicker between ready and preparing.
    private let ane: ANERuntime?
    private let source: SignalSource
    private let monitor: PresenceMonitor
    private let pauseSwitch = PauseSwitch()

    /// What the machine's owner is shown.
    ///
    /// Serving published nothing, so a machine answering requests all day told
    /// its owner nothing was installed - the exact failure the panel exists to
    /// prevent. Serving is also not the same activity as overnight batch work,
    /// and saying which matters more to the person at the desk than to anyone
    /// else: "answering requests for the studio" and "running batch work" are
    /// different bargains.
    private let status: StatusPublisher
    private var served = 0

    private var policy: [PresenceState: StatePolicy] = defaultPolicy
    /// Set from the control plane's view of this node, not assumed.
    private var isCluster = false

    /// The identity this machine joins a split with, and the CA it trusts its
    /// peer against.
    ///
    /// Passed in rather than read from disk here. The credential belongs to the
    /// process that enrolled and already holds it, and a worker that goes
    /// looking for one would need to know where enrolment put it - which is the
    /// CLI's business, not the loop's. Nil on a machine that cannot join a
    /// split, which is reported rather than crashed on.
    ///
    /// The peer CA is the *node* CA, not the server CA used everywhere else.
    /// The other end of a split is a node, and pinning the wrong root fails the
    /// handshake with "unknown CA" - which reads as a broken network rather
    /// than the wrong trust anchor.
    private var splitIdentity: (identity: NodeIdentity, peerCAPEM: String)?

    /// This machine's built share of a split model, kept between requests.
    ///
    /// Building it reads weights off disk and constructs a model, which is most
    /// of what a cold split request costs. The channel it runs over does not
    /// last and is not kept; the model is.
    /// When the last request finished, and how long to hold the model after it.
    ///
    /// The presence policy answers "somebody wants their machine back". This
    /// answers "nobody wants anything", which nothing did: a machine that served
    /// one request at nine in the morning held gigabytes until its owner
    /// returned.
    ///
    /// Decided here rather than in the batch loop deliberately. This actor is
    /// the one that serves requests, so when it decides to let go there is
    /// nothing in flight - and 21100c2 records what the other arrangement cost:
    /// the batch loop released the model the serving loop was using, destroying
    /// the prompt cache on every request and turning 0.5s into 37.5s.
    private var lastRequestEndedAt: Date?
    /// Requests being served right now.
    ///
    /// The idle window is decided from when the last request *ended*, which is
    /// stale for the whole of the one currently running: this loop suspends at
    /// every await, so a heartbeat can run mid-request, read a timestamp from
    /// the previous one and decide the machine has gone quiet. The unload then
    /// queues behind the generation and executes the instant it finishes,
    /// discarding the prompt cache of a request that just completed.
    ///
    /// Guaranteed for anything longer than the window, and there is a measured
    /// example: 19,243 tokens took 377 seconds against a 300 second default.
    /// That is the failure Worker.swift:707 records, reintroduced by the
    /// mechanism written to respect it.
    private var serving = 0
    private var idleWindow: TimeInterval?

    private var share: SplitRunner?
    /// What the held share was built for. A different rank or gang size means
    /// different layers, so the share is for a fleet that no longer exists.
    private var heldPlan: SplitRunner.Plan?

    public init(controlPlane: any ControlPlaneClient, gpu: MLXRuntime?,
                embeds: Bool = false,
                ane: ANERuntime? = nil,
                source: SignalSource = MacSignalSource(),
                status: StatusPublisher = StatusPublisher(),
                promoteAfter: TimeInterval = idlePromoteSeconds,
                splitIdentity: (identity: NodeIdentity, peerCAPEM: String)? = nil) {
        self.status = status
        self.controlPlane = controlPlane
        self.gpu = gpu
        self.embeds = embeds
        self.ane = ane
        self.source = source
        self.monitor = PresenceMonitor(promoteAfter: promoteAfter)
        self.splitIdentity = splitIdentity
    }

    public func setPolicy(_ policy: [PresenceState: StatePolicy]) {
        self.policy = policy
    }

    public func setCluster(_ isCluster: Bool) {
        self.isCluster = isCluster
    }

    /// Start presenting a renewed certificate.
    ///
    /// The batch loop owns renewal and this one does not, but they are two
    /// loops in one process holding two references to the same identity. The
    /// first renewal on real hardware showed what that costs: the batch loop
    /// swapped its client and carried on, and this loop went on presenting the
    /// certificate the control plane had just retired, reconnecting every five
    /// seconds to be told "unknown certificate" - for as long as the process
    /// lived, since nothing here ever reloads.
    ///
    /// Both credentials, because renewal replaces both. The node certificate is
    /// also what this machine joins a split with, and a node acquires its node
    /// CA by renewing - so a machine that could not join a split before the
    /// renewal can afterwards, and only if it is told.
    public func adopt(controlPlane: any ControlPlaneClient,
                      splitIdentity: (identity: NodeIdentity, peerCAPEM: String)?) {
        self.controlPlane = controlPlane
        // Kept rather than cleared when the new one is nil. Losing the ability
        // to join a split because a reload failed is worse than running on the
        // previous credential, which is still valid until it expires.
        if let splitIdentity { self.splitIdentity = splitIdentity }
        log("now presenting the renewed certificate")
    }

    /// Serve a different model, because the group now serves a different model.
    ///
    /// Isolated to this actor, so it cannot land in the middle of a request:
    /// `handle` runs here too, and the two are serialised by construction.
    public func adopt(runtime: MLXRuntime, named: String) {
        gpu = runtime
        log("now serving \(named)")
    }

    /// What this loop is presenting, and what it would join a split with.
    ///
    /// Reachable only from a test. The loop touches its client nowhere a test
    /// can see without a GPU on the machine - it refuses to connect at all when
    /// there is none - so proving that a renewal actually landed here needs a
    /// way to ask.
    func presenting() -> (client: any ControlPlaneClient,
                          split: (identity: NodeIdentity, peerCAPEM: String)?) {
        (controlPlane, splitIdentity)
    }

    /// Nonisolated because the peer link logs from an event loop thread, and
    /// hopping onto this actor to print would put the transport's own reports
    /// behind whatever the actor is doing - which, when a split is stuck, is
    /// waiting for the very thing the log line is about.
    nonisolated private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).suffix(9).prefix(8)
        print("[\(stamp)] serve: \(message)")
    }

    /// Whether this node may answer an interactive request right now.
    ///
    /// The same gate as batch GPU work, deliberately. A request served while
    /// somebody is using the machine is exactly the intrusion the whole design
    /// exists to prevent, and being interactive does not make it more welcome.
    private func mayServe() -> (ok: Bool, state: PresenceState, maxTokens: Int) {
        let reading = monitor.update(source.read(), now: Date().timeIntervalSince1970)
        let p = policy[reading.state] ?? reading.policy

        // The owner's pause still applies, on every tier. It is the one control
        // with no override, and a dedicated box is still somebody's machine.
        if pauseSwitch.read().paused { return (false, reading.state, 0) }

        // A cluster node is a dedicated box that is never preempted, so
        // presence does not gate it: nobody is sitting at it, and a
        // conversation needs a model that will still be resident a minute from
        // now, which the harvest tier cannot promise by design.
        // Either runtime is enough to be worth holding the channel open for.
        let canServe = gpu != nil || embeds
        if isCluster {
            return (canServe, reading.state,
                    defaultPolicy[.absent]!.maxCompletionTokens)
        }
        return (p.gpu && p.dutyMax > 0 && canServe, reading.state, p.maxCompletionTokens)
    }

    public func run(maxSeconds: TimeInterval = .infinity) async {
        let deadline = Date().addingTimeInterval(maxSeconds)
        log("holding the reverse channel open")

        // Heartbeats run on their own task, not in the request loop.
        //
        // A large prompt takes minutes to read - 19,243 tokens measured at 377
        // seconds - and for all of that the loop is inside a single call. With
        // the heartbeat inline the node went silent while it worked, the
        // scheduler dropped it for being stale, and it looked exactly like a
        // crash: gone from the fleet, no error anywhere, back a few minutes
        // later. It was answering the whole time.
        let beating = Task { [weak self] in
            while !Task.isCancelled {
                await self?.heartbeatNow()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        defer { beating.cancel() }

        defer { log("serve loop returning; deadline was \(deadline)") }

        while Date() < deadline {
            let gate = mayServe()

            // nil means "nothing to say": the batch loop's activity stands,
            // rather than this one claiming the panel while idle.
            await publish(gate.state, activity: nil)
            guard gate.ok else {
                // Not connecting at all is the honest signal: the control plane
                // only routes to nodes holding the channel open, so dropping it
                // takes this machine out of rotation rather than having it
                // accept a request and refuse.
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            do {
                guard let dispatch = try await controlPlane.awaitDispatch() else {
                    continue  // 204, reconnect
                }
                await handle(dispatch, maxTokens: gate.maxTokens)
            } catch {
                // A control plane that has gone away must not become a busy
                // loop against a dead socket.
                log("channel error: \(error)")
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Report in, whatever the request loop is doing.
    private func publish(_ state: PresenceState, activity: String?) async {
        status.updateServing(
            ready: gpu != nil && !pauseSwitch.read().paused,
            activity: activity,
            requestsAnswered: served,
            residentGb: await (gpu?.isLoaded ?? false) ? (await gpu?.residentGb ?? 0) : 0)
    }

    private func heartbeatNow() async {
        let signals = source.read()
        let state = monitor.update(signals, now: Date().timeIntervalSince1970).state
        // nil: a heartbeat is not an activity, and claiming one here would
        // overwrite whatever the loop last said it was doing.
        await publish(state, activity: nil)
        // What this machine actually has built.
        //
        // Reported under the model's own id whether it is the whole model or
        // this rank's share of it, because that is what the catalogue reads to
        // decide what can be served here. Before splits stopped warming the
        // whole model, "loaded" on a split group meant the monolith was resident
        // and the share was not - the readiness view said warm while every
        // request still built cold.
        var resident: [String: Double] = [:]
        if let gpu, await gpu.isLoaded { resident[await gpu.name] = await gpu.residentGb }
        if let ane, await ane.isLoaded { resident["ane:embed"] = 0.3 }
        if let held = share, let plan = heldPlan, await held.isBuilt {
            resident[plan.modelId] = await held.residentGb
        }
        // Advertised whether or not the model is loaded right now: the window a
        // model accepts does not depend on whether it happens to be resident,
        // and a client asking what this node can serve wants the answer either
        // way.
        var info: [String: Int] = [:]
        if let gpu, let context = await gpu.contextLength { info[await gpu.name] = context }
        // The directives were already coming back and being discarded. The
        // window is a property of the group this machine serves for, so it
        // arrives the same way its model does.
        let directives = try? await controlPlane.heartbeat(
            state: state, onACPower: signals.onACPower, thermalOK: signals.thermalOK,
            userPaused: pauseSwitch.read().paused,
            residentModels: resident, modelInfo: info)
        idleWindow = directives?.idleUnloadSeconds.map(TimeInterval.init)

        // Both caches this loop can reach, on every beat, so a change to the
        // group takes effect without restarting anything.
        //
        // Applied before the release below rather than after: lowering the budget
        // is a reason to let conversations go, and doing it in the other order
        // would leave the machine over its new ceiling until the next beat.
        let cacheGb = directives?.promptCacheGb
        await gpu?.setPromptCacheBudget(gb: cacheGb)
        await share?.setPromptCacheBudget(gb: cacheGb)

        await releaseIfIdle()
        if let directives { await warmShareIfAsked(directives) }
    }

    /// Build this machine's share of a split before anything asks for it.
    ///
    /// A split cannot begin until every rank has built its share, so a cold gang
    /// pays the slowest machine's load before the first token - and pays it
    /// again whenever the group falls idle. The operator already accepted that
    /// cost by standing the group up: these machines are out of harvesting for
    /// as long as it stands, so the memory is spoken for whether or not it holds
    /// anything.
    ///
    /// The rank arrives from the heartbeat and the dispatch decides again. This
    /// is an optimisation and never a claim: a dispatch naming a different rank
    /// rebuilds, because the share was built for a fleet that no longer exists.
    /// What the heartbeat is asking this machine to do about its split share.
    ///
    /// Pulled out of `warmShareIfAsked` because the two absent cases used to be
    /// one guard and they mean opposite things - the shape `Worker.directive`
    /// already has for the whole-model path, and for the same reason: it is the
    /// decision, not the doing, that is worth being able to check.
    enum ShareDirective: Equatable {
        /// Nothing claims this machine. Let go of whatever is held.
        case release
        /// Claimed by a group that has named no model. Hold what was built.
        case holdWhatIsHeld
        /// Build this share before anything asks for it.
        case warm(model: String, rank: Int, size: Int)
    }

    static func shareDirective(_ d: ControlPlane.Directives) -> ShareDirective {
        // `keepLoaded` is the only thing that tells this machine it is in a
        // cluster group at all. A node never learns which groups it is in - that
        // keeps the shape of the fleet out of a credential on somebody's
        // workstation - so the intent stands in for the membership. False means
        // no group is claiming it: stood down, or handed back.
        //
        // releaseShare existed and nothing called it, which is the same shape as
        // keepLoaded reaching the agent and being acted on by nothing: written,
        // plausible, and doing nothing. The socket already tells callers the
        // machines have been handed back, and that has to be true of the
        // workstation as well as the scheduler.
        guard d.keepLoaded else { return .release }

        // Still claimed, but nothing is named. That is a group serving whichever
        // staged model is asked for, and the share it built to answer the last
        // request is exactly what it should still be holding.
        //
        // Releasing here is what the single guard used to do, and it would have
        // undone the feature at the first heartbeat: built to answer a request,
        // let go twenty seconds later, rebuilt for the next one. The protocol
        // already says so - servingModel's own contract is that nil means nobody
        // has said, which is not an instruction to unload - and the whole-model
        // path honours it. This is the split path catching up.
        guard let model = d.servingModel, let seat = d.standingSplit else {
            return .holdWhatIsHeld
        }
        return .warm(model: model, rank: seat.rank, size: seat.size)
    }

    private func warmShareIfAsked(_ directives: ControlPlane.Directives) async {
        let model: String
        let seat: (rank: Int, size: Int)
        switch Self.shareDirective(directives) {
        case .release:
            await releaseShare()
            return
        case .holdWhatIsHeld:
            return
        case .warm(let m, let rank, let size):
            model = m
            seat = (rank, size)
        }

        let directory = MLXRuntime.modelDirectory.appendingPathComponent(model)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            // The weights have not arrived. Not a fault: model sync is still
            // working, and the readiness view says so in those words.
            return
        }

        let plan = SplitRunner.Plan(modelId: model, rank: seat.rank, size: seat.size)
        let runner = await shareFor(plan)
        guard await !runner.isBuilt else { return }
        do {
            let started = Date()
            if try await runner.prepare(directory: directory) {
                log(String(format: "built %@ in %.1fs, held for this group",
                           String(describing: plan), Date().timeIntervalSince(started)))
            }
        } catch {
            // Left for the next heartbeat rather than retried here. The usual
            // cause is a machine busy with the request that is keeping it warm.
            log("could not build \(plan): \(error)")
        }
    }

    /// Let go of the model when nothing has been asked of this machine for a
    /// while.
    ///
    /// Nil window means never, which is what a group pinned to a model gets and
    /// what every machine did before this existed.
    ///
    /// Both the whole model and the split share, because a machine can be
    /// holding either. This only ever unloaded `gpu`, which was harmless while
    /// the sole groups with a window were harvest groups - they hold no share.
    /// A group serving whichever staged model is asked for holds nothing else:
    /// the share *is* the memory, so leaving it out would mean the first model
    /// anyone asked for stayed resident for as long as the group stood, chosen
    /// by whoever asked first and never released.
    private func releaseIfIdle() async {
        // Never while answering. Idleness is about nothing being asked, and
        // something is being asked. Decided once, for both, by the rule that
        // already counts requests in flight rather than trusting a timestamp
        // that does not move until the current request ends.
        guard Worker.shouldReleaseWhenIdle(lastRequestEndedAt: lastRequestEndedAt,
                                           now: Date(), window: idleWindow,
                                           serving: serving)
        else { return }

        var released = false
        if let gpu, await gpu.isLoaded {
            let freed = await gpu.unload()
            log(String(format: "idle for %.0fs; released %@ in %.1fs",
                       idleWindow ?? 0, await gpu.name, freed))
            released = true
        }
        if let held = share, await held.isBuilt {
            let plan = heldPlan
            await releaseShare()
            log(String(format: "idle for %.0fs; released this machine's share of %@",
                       idleWindow ?? 0, plan?.modelId ?? "a split model"))
            released = true
        }
        // Only once something was actually let go. Clearing it on every idle
        // heartbeat would restart the clock against nothing and the window
        // would never elapse.
        if released { lastRequestEndedAt = nil }
    }

    /// Be one rank of a split model.
    ///
    /// Rank 0 listens and holds the output head, so it is the one with an
    /// answer to report. The others hold earlier layers, hand their hidden state
    /// across, and report that they did their share - the control plane takes
    /// rank 0's reply as the completion and needs the rest only to know they
    /// did not fail.
    ///
    /// The dial retries, because the ranks are dispatched at the same instant
    /// and the listener is frequently not up when the first attempt arrives.
    /// That is ordinary rather than a failure; a peer that never comes is
    /// separated from one that is slow by giving up after a bounded time.
    /// The built share for this plan, kept across requests.
    ///
    /// One at a time, and keyed by the whole plan rather than the model alone.
    /// A rank or a gang size that differs means the layers this machine owns
    /// differ, so the built model is for a fleet that no longer exists and has
    /// to be replaced rather than reused. The dispatch stays authoritative: a
    /// kept share is an optimisation and never a claim about what the control
    /// plane decided.
    private func shareFor(_ plan: SplitRunner.Plan) async -> SplitRunner {
        if let held = share, heldPlan == plan { return held }
        if share != nil {
            log("this machine's share is for \(heldPlan.map(String.init(describing:)) ?? "nothing")"
                + "; rebuilding for \(plan)")
            await share?.release()
        }
        let runner = SplitRunner(plan: plan)
        share = runner
        heldPlan = plan
        return runner
    }

    /// What this loop is holding, for the loop that cannot see it.
    ///
    /// Both heartbeat and each replaces resident_models wholesale, so each has
    /// to report the whole picture or it erases the other's half.
    public func residentShare() async -> [String: Double] {
        guard let held = share, let plan = heldPlan, await held.isBuilt else { return [:] }
        return [plan.modelId: await held.residentGb]
    }

    /// Let go of the built share and its memory.
    ///
    /// Called when this machine stops being part of a split. Releasing lives
    /// here, with the thing that owns it, for the reason 21100c2 records: two
    /// loops releasing one model is how the batch loop freed the model the
    /// serving loop was using.
    public func releaseShare() async {
        guard let held = share else { return }
        await held.release()
        share = nil
        heldPlan = nil
        log("released this machine\'s share of a split model")
    }

    private func runSplit(_ split: SplitDispatch,
                          dispatch: ControlPlane.Dispatch) async {
        // A split is a request too, and the clock now decides something. A group
        // pinned to a model is still sent no window and holds its share for as
        // long as it stands; a group serving whichever staged model is asked for
        // is sent one, and this is what stops it counting a long split as idle
        // time and unloading the model it is in the middle of serving from.
        serving += 1
        defer { serving -= 1; lastRequestEndedAt = Date() }

        let directory = MLXRuntime.modelDirectory
            .appendingPathComponent(split.model)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil,
                error: "rank \(split.rank) does not hold \(split.model)")
            return
        }

        guard let credentials = splitIdentity else {
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil,
                error: "this machine has no enrolled identity to join a split with")
            return
        }
        let identity = credentials.identity
        let ca = credentials.peerCAPEM

        await publish(mayServe().state, activity: "rank \(split.rank) of a split model")
        // The link logs through this loop's own logger, so what the two halves
        // said to each other reads in order beside everything else the node was
        // doing at the time.
        let channel = PipelineChannel(log: { [log] in log($0) })
        // Closed however this ends, including the ways it ends badly.
        //
        // Without this the listening rank holds port 7710 for the life of the
        // daemon, and the *next* split on that machine fails to bind - which is
        // what happened here: one attempt left its socket behind, the second
        // could not listen, and the dialer connected to the corpse of the first
        // and completed a handshake with it. A leaked listener does not merely
        // waste a port; it answers.
        // Detached, because a Task made inside an actor inherits its isolation
        // and would queue behind whatever this loop does next - which is take
        // the following request, on the port it has not released yet.
        defer { let c = channel; Task.detached { await c.close() } }
        let started = Date()
        do {
            switch split.role {
            case .listen:
                _ = try await channel.listen(port: split.port,
                                             identity: identity, peerCAPEM: ca)
                log("rank \(split.rank) listening on \(split.port)")
            case .dial:
                try await channel.connectWithRetry(
                    host: split.peer!, port: split.port, identity: identity,
                    peerCAPEM: ca, serverName: split.peer!)
                log("rank \(split.rank) connected to \(split.peer!)")
            }

            // Kept between requests when the plan has not changed, because
            // building the share is most of what a cold split costs. The
            // channel is not kept - one is opened per request and closed on
            // every exit path - so the model is pointed at this request's link
            // rather than rebuilt against it.
            let runner = await shareFor(
                .init(modelId: split.model, rank: split.rank, size: split.size))
            await runner.rebind(channel)
            // The cap the control plane already applied, computed from the
            // presence of the machine holding the head. Read rather than
            // recomputed, so the decision lives in one place.
            let budget = dispatch.body["max_tokens"]?.intValue ?? 256
            let done = try await runner.run(directory: directory,
                                            prompt: promptFrom(dispatch.body),
                                            maxTokens: budget)

            let seconds = Date().timeIntervalSince(started)
            // Split into reading the prompt and producing the answer, because
            // one number cannot be acted on and these two can.
            //
            // An 11,819 token question took 110.5s and the line said only that.
            // Whether that was the link, the prefill or the decode needed an
            // experiment, and the runner had already measured all three and
            // thrown them away at the log line.
            let o = done.outcome
            log(String(format:
                "rank %d (layers %d..<%d) finished %d tokens in %.1fs "
                + "(prompt %d tokens in %.1fs, %d reused; decode %d in %.1fs)",
                split.rank, done.layers.lowerBound, done.layers.upperBound,
                o.tokens, seconds,
                o.promptTokens, o.promptSeconds, o.reusedTokens,
                o.tokens, o.decodeSeconds))
            // Only the rank holding the head has text. The others report a
            // completion with none, which is what tells the control plane they
            // did not fail.
            try await controlPlane.reportDispatch(
                id: dispatch.id,
                text: done.isHead ? done.outcome.text : nil,
                error: nil,
                promptTokens: done.reported.prompt,
                completionTokens: done.reported.completion,
                // Empty on every rank but the head, which is where the control
                // plane assembles the caller's answer. It is the evidence that
                // the model was divided rather than the declaration that it
                // should be: two hostnames prove two machines were sent work,
                // where 0..<24 beside 24..<48 proves neither held the whole
                // model.
                layerPlan: done.layerPlan)
        } catch {
            // A pipeline failure already names the rank that noticed, which is
            // not always this one: rank 0 timing out and rank 1 failing to send
            // are the same broken link seen from both ends, and prefixing both
            // with the local rank would say it twice and lose which end spoke.
            let detail = error is PipelineStep
                ? "\(error)" : "rank \(split.rank) failed: \(error)"
            log(detail)
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil, error: detail)
        }
    }

    /// Vectors for a batch of strings, reported as vectors rather than text.
    ///
    /// Everything here is arranged around one property: a wrong embedding is
    /// indistinguishable from a right one by inspection. So the failures are
    /// reported as failures rather than approximated, and the count of vectors
    /// is left to match the count of inputs so the control plane can check it.
    private func handleEmbed(_ dispatch: ControlPlane.Dispatch) async {
        let parsed = EmbedRequest.parse(modelHash: dispatch.modelHash, body: dispatch.body)
        guard case let .success(request) = parsed else {
            guard case let .failure(refusal) = parsed else { return }
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil, error: refusal.reason)
            return
        }
        let model = request.model
        let inputs = request.inputs
        let intent = request.intent

        // One embedding model at a time. A request naming a different one
        // releases the previous, because holding both doubles what a returning
        // user has to wait to get back.
        if let held = embedder, await held.name != model {
            _ = await held.unload()
            embedder = nil
        }
        if embedder == nil { embedder = EmbedRuntime(modelId: model) }
        guard let embedder else { return }

        await publish(mayServe().state, activity: "embedding \(inputs.count) inputs")
        let started = Date()
        do {
            if await !embedder.isLoaded { _ = try await embedder.load() }
            let vectors = try await embedder.embed(inputs, intent: intent)
            let seconds = Date().timeIntervalSince(started)
            log("embedded \(inputs.count) inputs as \(intent.rawValue) in "
                + String(format: "%.2fs", seconds))
            try await controlPlane.reportDispatch(
                id: dispatch.id, text: nil, error: nil, embeddings: vectors)
        } catch {
            // Reported rather than swallowed, and the runtime's refusals carry
            // their own explanation: an input over the model's length says so
            // and says it was not truncated, which is the difference between a
            // caller splitting the text and a caller wondering why retrieval
            // got worse.
            log("embed failed: \(error)")
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil, error: String(describing: error))
        }
    }

    private func handle(_ dispatch: ControlPlane.Dispatch, maxTokens: Int) async {
        // Stamped however this ends, including badly. A request that failed
        // still means somebody was asking a moment ago, and starting the idle
        // clock from a success only would release the model out from under a
        // client that is retrying.
        serving += 1
        defer { serving -= 1; lastRequestEndedAt = Date() }

        // Embedding, which needs neither the generation runtime nor any of the
        // machinery below it: no cancellation watch, no policy cap on length,
        // no tool parsing, no prompt cache. It is checked before the `gpu`
        // guard because a node can hold an embedding model and no chat model.
        if dispatch.body["operation"]?.stringValue == "embed" {
            await handleEmbed(dispatch)
            return
        }

        guard let gpu else {
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil, error: "no GPU runtime on this node")
            return
        }

        // Watch for the caller giving up while this runs. Two seconds is a
        // compromise: often enough that a cancel is felt as immediate, rare
        // enough to be free next to the work it is interrupting.
        let cancelled = CancelFlag()
        // Detached, and that detail is the whole thing.
        //
        // A plain Task created inside an actor inherits its isolation, so this
        // would queue behind the very call it is meant to interrupt: the actor
        // is occupied for the length of the generation, and a watcher that can
        // only run when the actor is free never runs at all. Detaching gives it
        // its own executor.
        let watching = Task.detached { [controlPlane] in
            while !Task.isCancelled {
                if await controlPlane.isDispatchCancelled(id: dispatch.id) {
                    cancelled.set()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { watching.cancel() }

        // A rank of a split model, which is a different piece of work from a
        // completion: two machines, one answer, and a channel between them that
        // has to exist before either can start.
        if let split = SplitDispatch(body: dispatch.body) {
            await runSplit(split, dispatch: dispatch)
            return
        }

        // Counting is not generating: no cancellation watch, no policy cap, no
        // tool parsing. It exists so a client can decide what to send, so it
        // has to be cheap enough to ask before every turn.
        if dispatch.body["operation"]?.stringValue == "count_tokens" {
            do {
                if await !gpu.isLoaded { _ = try await gpu.load() }
                let count = try await gpu.countTokens(
                    messages: chatFrom(dispatch.body, dialect: await gpu.toolDialect)
                        ?? [["role": "user", "content": promptFrom(dispatch.body)]],
                    tools: dispatch.body["tools"]?.arrayValue)
                log("counted \(count) tokens")
                try await controlPlane.reportDispatch(
                    id: dispatch.id, text: nil, error: nil, promptTokens: count)
            } catch {
                try? await controlPlane.reportDispatch(
                    id: dispatch.id, text: nil, error: String(describing: error))
            }
            return
        }

        await publish(mayServe().state, activity: "answering a request")
        let started = Date()
        do {
            // Refuse early rather than time out. A prompt beyond what this node
            // can read inside the budget produces the same failure either way,
            // but one takes two minutes to say so and gives the caller nothing
            // to act on.
            if MLXRuntime.adaptiveContextEnabled, let limit = await gpu.contextLength {
                let approximate = approximatePromptTokens(dispatch.body)
                if approximate > limit {
                    log("refusing ~\(approximate) prompt tokens; this node can read \(limit)")
                    try await controlPlane.reportDispatch(
                        id: dispatch.id, text: nil,
                        // Phrased so the control plane can recognise it: this
                        // is the caller's request being too large, not the node
                        // failing, and the two need different status codes.
                        error: "prompt is too long: about \(approximate) tokens, and this "
                             + "node can process \(limit) within the answer budget")
                    return
                }
            }
            if await !gpu.isLoaded {
                let seconds = try await gpu.load()
                log(String(format: "loaded model in %.2fs", seconds))
            }

            // Capped by the node's own policy as well as the control plane's.
            // The server applies the same ceiling, and this is the second of the
            // two: a single request has no seam to yield at, so its length is
            // the only thing bounding how long a returning user waits.
            let requested = dispatch.body["max_tokens"]?.intValue ?? 512
            let out = try await gpu.complete(
                prompt: promptFrom(dispatch.body),
                maxTokens: min(requested, maxTokens),
                tools: dispatch.body["tools"]?.arrayValue,
                messages: chatFrom(dispatch.body, dialect: await gpu.toolDialect),
                forceTool: forcedTool(dispatch.body),
                cancelled: cancelled)

            if cancelled.isSet {
                // Nothing to report. The control plane has already answered the
                // caller and closed the dispatch, so posting a partial result
                // here only earns a 409 and puts a failure in the log for a
                // request that did exactly what it was asked to.
                log(String(format: "cancelled by the caller after %.1fs",
                           Date().timeIntervalSince(started)))
                return
            }

            served += 1

            let elapsed = Date().timeIntervalSince(started)
            // The prompt rate is logged because it is what sizes the advertised
            // window, and a window nobody can explain is one nobody trusts.
            log(String(format: "prompt %d tokens in %.1fs wall%@; window %@",
                       out.promptTokens, elapsed,
                       out.reusedTokens > 0
                         ? String(format: ", %d of them reused (%.0f%% cached)",
                                  out.reusedTokens,
                                  Double(out.reusedTokens) / Double(max(out.promptTokens, 1)) * 100)
                         : "",
                       (await gpu.contextLength).map(String.init) ?? "unknown"))
            log(String(format: "answered in %.2fs (%d prompt, %d generated%@)",
                       elapsed, out.promptTokens, out.completionTokens,
                       out.toolCalls.isEmpty ? ""
                         : ", \(out.toolCalls.count) tool call"
                           + (out.toolCalls.count == 1 ? "" : "s")))
            // Coerced against the schema the caller declared, so a field the
            // model spelled as a string ("24" for an integer) does not make the
            // client reject a call it otherwise got right.
            let schemas = toolSchemas(dispatch.body)
            let calls = out.toolCalls.map { call in
                ToolCall(name: call.name,
                         arguments: ToolSchema.coerce(call.arguments, to: schemas[call.name]))
            }
            try await controlPlane.reportDispatch(
                id: dispatch.id, text: out.text, error: nil,
                promptTokens: out.promptTokens, completionTokens: out.completionTokens,
                cachedTokens: out.reusedTokens, toolCalls: calls)
        } catch {
            log("failed: \(error)")
            try? await controlPlane.reportDispatch(
                id: dispatch.id, text: nil, error: String(describing: error))
        }
    }

    /// The tool the caller insisted on, if it named one.
    private func forcedTool(_ body: JSONValue) -> String? {
        guard let choice = body["tool_choice"] else { return nil }
        guard choice["type"]?.stringValue == "tool" else { return nil }
        return choice["name"]?.stringValue
    }

    /// A rough token count, for deciding whether to attempt a request at all.
    ///
    /// Four characters per token is crude and known to be crude; it is used
    /// only to catch prompts far beyond what this node can read, where being
    /// wrong by a fifth changes nothing. The exact count comes from the
    /// tokeniser afterwards.
    private func approximatePromptTokens(_ body: JSONValue) -> Int {
        var characters = 0
        for message in body["messages"]?.arrayValue ?? [] {
            characters += (textOf(message["content"]) ?? "").count
        }
        for tool in body["tools"]?.arrayValue ?? [] {
            characters += String(describing: tool.anyValue).count
        }
        return characters / 4
    }

    /// Declared input schemas, keyed by tool name.
    private func toolSchemas(_ body: JSONValue) -> [String: JSONValue] {
        guard let tools = body["tools"]?.arrayValue else { return [:] }
        var out: [String: JSONValue] = [:]
        for tool in tools {
            guard let name = tool["name"]?.stringValue else { continue }
            // Both spellings: Anthropic calls it input_schema, OpenAI parameters.
            out[name] = tool["input_schema"] ?? tool["parameters"]
        }
        return out
    }

    /// The conversation as roles and content, for the chat template.
    ///
    /// Preferred over the flattened prompt whenever the template can be
    /// applied: the template is what renders tool definitions and tool results
    /// in the form the model was trained on, and flattening throws that away.
    private func chatFrom(_ body: JSONValue, dialect: ToolDialect?) -> [[String: String]]? {
        guard case let .array(messages)? = body["messages"] else { return nil }
        let mapped = messages.compactMap { message -> [String: String]? in
            guard let role = message["role"]?.stringValue else { return nil }

            // A message carrying tool results is not a user turn, whatever the
            // client labelled it. Llama's template branches on `ipython` and
            // most others on `tool`; sent as `user` the result renders as
            // ordinary prose, the model sees its call still unanswered, and it
            // calls again - forever, when the conversation ends on a tool
            // result, which is every agentic turn.
            if let results = toolResults(message["content"]), !results.isEmpty {
                return ["role": dialect?.toolResultRole ?? "tool",
                        "content": results.joined(separator: "\n")]
            }
            guard let content = textOf(message["content"]) else { return nil }
            return ["role": role, "content": content]
        }
        return mapped.isEmpty ? nil : mapped
    }

    /// The bodies of any tool_result blocks, unwrapped.
    ///
    /// Returned bare rather than annotated: the template supplies whatever
    /// framing the model was trained on, and adding a label of our own puts
    /// text in front of the model it has never seen in that position.
    private func toolResults(_ content: JSONValue?) -> [String]? {
        guard case let .array(blocks)? = content else { return nil }
        let results = blocks.compactMap { block -> String? in
            guard block["type"]?.stringValue == "tool_result" else { return nil }
            return textOf(block["content"]) ?? ""
        }
        return results.isEmpty ? nil : results
    }

    /// Flatten a messages array into a prompt.
    ///
    /// The runtime takes a single string, so the conversation is rendered here.
    /// A model's own chat template would be better and is what
    /// `MLXLMCommon` applies for the simple case; this keeps the shape the
    /// control plane sends without pretending to more fidelity than it has.
    private func promptFrom(_ body: JSONValue) -> String {
        guard case let .array(messages)? = body["messages"] else {
            return body["prompt"]?.stringValue ?? ""
        }
        return messages.compactMap { message -> String? in
            let role = message["role"]?.stringValue ?? "user"
            guard let content = textOf(message["content"]) else { return nil }
            return "\(role): \(content)"
        }.joined(separator: "\n\n")
    }

    /// Content is a string in the OpenAI shape and an array of blocks in the
    /// Anthropic one. Both arrive here, so both are handled.
    private func textOf(_ content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let text = content.stringValue { return text }
        if case let .array(blocks) = content {
            let parts = blocks.compactMap { block -> String? in
                if let text = block["text"]?.stringValue { return text }
                // A tool result comes back as its own block type. Rendering it
                // as text is what lets the loop continue: the model has to see
                // what its call returned or it will simply ask again.
                if block["type"]?.stringValue == "tool_result" {
                    let body = textOf(block["content"]) ?? ""
                    let id = block["tool_use_id"]?.stringValue ?? ""
                    return "[tool_result \(id)]\n\(body)"
                }
                if block["type"]?.stringValue == "tool_use" {
                    let name = block["name"]?.stringValue ?? ""
                    let input = block["input"].map { String(describing: $0.anyValue) } ?? ""
                    return "[tool_use \(name)] \(input)"
                }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if case .object = content { return String(describing: content.anyValue) }
        return nil
    }
}
