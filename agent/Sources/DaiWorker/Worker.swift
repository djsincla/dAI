import DaiAgent
import Foundation

/// The harvest worker: pull work, run it, get out of the way when someone sits
/// down.
///
/// Two properties carried over from the Python agent because both were learned
/// the hard way.
///
/// **Yield between items, not between units.** A unit is a batch; checking only
/// at unit boundaries would let a whole batch run on after someone returns.
/// Checking per item bounds the intrusion to one item, and completed items are
/// reported rather than discarded, so a preemption costs at most the item in
/// flight.
///
/// **Presence is cached, not re-read per item.** Reading signals costs real time
/// and an ANE item costs ~27ms, so polling per item spent most of the worker's
/// life asking whether the user was back. Caching for the poll interval costs
/// nothing in responsiveness because that interval already *is* the designed
/// yield latency.
public actor Worker {
    enum Failure: Error, CustomStringConvertible {
        case noGPURuntime
        case noANERuntime
        case noRenderer
        case noScene
        case notAFrame
        public var description: String {
            switch self {
            case .noGPURuntime:
                return "this node has no GPU runtime; generate work should not have been leased to it"
            case .noANERuntime:
                return "this node has no ANE runtime; embed work should not have been leased to it"
            case .noRenderer:
                return "this node has no renderer; render work should not have been leased to it"
            case .noScene:
                return "the unit is render work but its job names no scene"
            case .notAFrame:
                return "a render item carried no frame number"
            }
        }
    }

    /// Replaced when the certificate is renewed. Renewal retires the old
    /// certificate the moment the new one is issued, so a client still holding
    /// the old one would start being told it is unknown.
    private var controlPlane: any ControlPlaneClient
    private let source: SignalSource
    private let monitor: PresenceMonitor
    private let pauseSwitch: PauseSwitch
    /// Optional because a machine can be a useful fleet member without a
    /// working GPU runtime. MLX needs a Metal shader library built by a
    /// toolchain that is a separate Xcode download, and a machine missing it
    /// should still harvest ANE work rather than refuse to start: three of the
    /// five presence states permit nothing but ANE work anyway, so the GPU
    /// runtime is not what most of the fleet's hours are made of.
    /// The GPU runtime, which is replaced when this machine's group changes
    /// what it serves. A runtime is bound to one model at construction, so
    /// switching means a new one - and both loops have to be handed it.
    private var gpu: MLXRuntime?
    /// The runtime this machine was started with, from its own configuration.
    ///
    /// Kept so a machine can tell a model it adopted from a group apart from the
    /// one it was configured to run. Without that it cannot answer "is what I am
    /// holding mine", and every `nil` from the control plane looks the same.
    private let configuredGPU: MLXRuntime?
    private let ane: ANERuntime?

    private var policy: [PresenceState: StatePolicy] = defaultPolicy
    private var cached: PresenceMonitor.Reading?
    private var cachedAt: TimeInterval = 0
    private var qosBackground: Bool?
    private var capability: [String: Double] = [:]
    private var lastHeartbeat: TimeInterval = 0
    private var lastCacheSweep: TimeInterval = 0
    /// Last reported set of permitted kinds, so a change can be logged once
    /// rather than every poll.
    private var lastKinds: [WorkKind]?
    private var lastReason: String?
    private var wasPaused = false
    private var pausedByFleet = false
    /// A cluster node is never preempted, so presence does not gate it.
    private var isCluster = false
    /// Fetches weights this node has been assigned. Optional because a machine
    /// with no model directory configured has nowhere to put them.
    private var modelSync: ModelSync?

    /// Keeps this node's certificate current. Optional because a test, and a
    /// one-shot run, has no identity on disk to renew.
    private let renewer: (any CertificateRenewing)?

    /// Renders frames, when this machine has a renderer. Optional for the same
    /// reason the GPU runtime is: a machine without one is an ordinary fleet
    /// member that does AI work and never offers the render kind.
    private let renderer: RenderRuntime?
    /// Fetches the scene a render unit needs, on the critical path.
    private let scenes: SceneSync?
    /// Fetches a job's content, and deletes it again when the job is over.
    private let attachments: AttachmentSync?

    /// One transfer at a time. Without this the loop would launch another every
    /// pass while the first was still running, and a slow link would end up
    /// fetching the same model a dozen times over.
    /// When the running reconciliation pass began, or nil if none is running.
    ///
    /// A timestamp rather than a boolean, because a boolean is what broke. The
    /// flag was set before a detached transfer and cleared when it finished, and
    /// nothing in that path has a timeout: one transfer that hung left the flag
    /// set for good, so the node never attempted another pass and never said
    /// why. On this fleet a machine sat like that for twelve hours, heartbeating
    /// normally, silently not fetching a model it had been assigned.
    private var modelSyncStartedAt: Date?
    /// How long a pass may run before another is allowed to start. Generous:
    /// this bounds a stuck pass, and a legitimate one can be tens of gigabytes
    /// over a LAN.
    private let modelSyncStuckAfter: TimeInterval = 3600
    /// Reported on the next beat; nil until a pass has finished.
    private var pendingSyncFaults: [String: String]?
    /// Set by the control plane on a beat, acted on by the next loop turn.
    private var renewRequested = false
    /// Told when this node starts presenting a new certificate, so the other
    /// loop in this process can stop presenting the old one.
    private let onRenewed: (@Sendable (any ControlPlaneClient) async -> Void)?
    /// Told when this machine starts serving a different model, so the loop
    /// that answers requests stops holding the old runtime.
    private let onServingModelChanged: (@Sendable (MLXRuntime, String) async -> Void)?
    /// What the serving loop holds that this one cannot see. Read rather than
    /// owned: the split share belongs to the actor that serves requests.
    private let sharedModels: (@Sendable () async -> [String: Double])?

    /// Holds the machine awake while it is on AC and nobody has paused it.
    /// Released when either stops being true, and when the process dies.
    private let sleepAssertion: SleepAssertion
    private let status: StatusPublisher

    public struct Stats: Sendable {
        public var items = 0
        public var units = 0
        public var yields = 0
        public var loads = 0
    }
    public private(set) var stats = Stats()

    public init(controlPlane: any ControlPlaneClient, source: SignalSource = MacSignalSource(),
                gpu: MLXRuntime? = nil, ane: ANERuntime? = nil,
                pauseSwitch: PauseSwitch = PauseSwitch(),
                status: StatusPublisher = StatusPublisher(),
                modelSync: ModelSync? = nil,
                renderer: RenderRuntime? = nil,
                scenes: SceneSync? = nil,
                attachments: AttachmentSync? = nil,
                renewer: (any CertificateRenewing)? = nil,
                onRenewed: (@Sendable (any ControlPlaneClient) async -> Void)? = nil,
                onServingModelChanged: (@Sendable (MLXRuntime, String) async -> Void)? = nil,
                sharedModels: (@Sendable () async -> [String: Double])? = nil,
                sleepAssertion: SleepAssertion = SleepAssertion(),
                promoteAfter: TimeInterval = idlePromoteSeconds) {
        self.renewer = renewer
        self.onRenewed = onRenewed
        self.onServingModelChanged = onServingModelChanged
        self.sharedModels = sharedModels
        self.renderer = renderer
        self.scenes = scenes
        self.attachments = attachments
        self.sleepAssertion = sleepAssertion
        self.modelSync = modelSync
        self.status = status
        self.controlPlane = controlPlane
        self.source = source
        self.monitor = PresenceMonitor(promoteAfter: promoteAfter)
        self.pauseSwitch = pauseSwitch
        self.gpu = gpu
        self.configuredGPU = gpu
        self.ane = ane
    }

    /// A cluster node is never preempted, so presence does not gate it - and
    /// this loop must know, or it releases a model the serving loop is using.
    public func setCluster(_ isCluster: Bool) {
        self.isCluster = isCluster
    }

    // MARK: - Presence

    private func presence(maxAge: TimeInterval? = nil) -> PresenceMonitor.Reading {
        let age = maxAge ?? pollIntervalActive
        let now = Date().timeIntervalSince1970
        if let cached, now - cachedAt < age { return cached }
        let reading = monitor.update(source.read(), now: now)
        cached = reading
        cachedAt = now
        return reading
    }

    /// Work kinds permitted *right now*, narrowed to what this node can run.
    ///
    /// Advertised to the control plane so it hands out only servable work rather
    /// than work the agent must immediately hand back. Delegated rather than
    /// spelled out again, so there is one definition of what this machine will
    /// attempt and the diagnostic commands cannot disagree with the loop.
    private func availableKinds(_ p: StatePolicy) -> [WorkKind] {
        runnableKinds(p, hasGPU: gpu != nil, hasANE: ane != nil,
                      hasRenderer: renderer != nil && (attachments != nil || scenes != nil))
    }

    private func applyQoS(_ p: StatePolicy, kind: WorkKind) {
        // ANE work is never throttled: E5 measured it as indistinguishable from
        // no load, so background QoS buys politeness that is already free while
        // costing ~26x on bursty items.
        let want = p.qos == .background && kind.isGPU
        if want != qosBackground {
            ProcessQoS.setBackground(want)
            qosBackground = want
        }
    }

    // MARK: - Reporting

    private func residentModels() async -> [String: Double] {
        var out: [String: Double] = [:]
        if let gpu, await gpu.isLoaded { out[await gpu.name] = await gpu.residentGb }
        if let ane, await ane.isLoaded { out["ane:embed"] = 0.3 }
        // Whatever the serving loop is holding as its share of a split.
        //
        // Both loops heartbeat and each replaces resident_models wholesale, so
        // a loop reporting only what it can see erases what it cannot. That
        // made residency alternate between two partial answers every twenty
        // seconds, and the readiness strip flicker between ready and preparing
        // - a machine appearing to load and unload a model it never touched.
        for (name, gb) in await sharedModels?() ?? [:] { out[name] = gb }
        return out
    }

    /// Fetch assigned weights when the machine is free, using the presence
    /// judgement this loop has already made rather than reading the machine a
    /// second time. Two answers to "is somebody there" is how a machine ends up
    /// polite in one place and rude in another.
    /// Whether a pass that started at `startedAt` has been running long enough
    /// to be considered wedged.
    ///
    /// Pulled out as a function with no clock of its own so the decision can be
    /// tested, which the boolean it replaced could not be. nil means no pass is
    /// running, and the answer is that nothing is stuck.
    static func passIsStuck(startedAt: Date?, now: Date, after: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= after
    }

    private func syncModelsIfDue(_ reading: PresenceMonitor.Reading) async {
        guard let modelSync else { return }
        if let started = modelSyncStartedAt {
            let running = Date().timeIntervalSince(started)
            guard Self.passIsStuck(startedAt: started, now: Date(),
                                   after: modelSyncStuckAfter) else { return }
            // Said out loud rather than waited on forever. A pass this old is
            // wedged on something with no timeout of its own, and the choice is
            // between never syncing again and starting another; the transfers
            // are idempotent and hash-checked, so another is safe.
            log("model sync has been running \(Int(running))s; starting another")
            pendingSyncFaults = ["*": "a previous pass has been running for \(Int(running))s"]
        }
        let paused = pauseSwitch.read().paused
        let free = !paused && (isCluster || reading.policy.gpu)

        // Detached, because a transfer is measured in gigabytes and awaiting it
        // here stops the loop: no heartbeat for the length of the download, so
        // the scheduler drops the node for being silent and routes around the
        // machine that is busy doing what it was told. That is the same failure
        // this codebase already fixed once for serving, arriving by a new road.
        modelSyncStartedAt = Date()
        Task.detached { [weak self] in
            let outcome = await modelSync.syncIfDue(mayTransfer: free)
            await self?.finishModelSync(outcome)
        }
    }

    private func finishModelSync(_ outcome: ModelSync.Outcome?) {
        modelSyncStartedAt = nil
        guard let outcome else { return }
        for id in outcome.fetched { log("fetched model \(id)") }
        for id in outcome.repaired {
            log("wrote missing load metadata for \(id); it was held but not loadable")
        }
        for (id, why) in outcome.failed { log("model \(id) failed: \(why)") }

        // Kept for the next heartbeat rather than only written to the log. A
        // node that cannot fetch what it was assigned is invisible otherwise:
        // the fleet view shows a count of machines still wanting the model and
        // that count does not move whether the transfer is running, queued or
        // failing every time.
        //
        // A pass that reported nothing sets an empty map rather than nil, which
        // is what clears a fault that has since been fixed. nil means no pass
        // has finished, and says nothing.
        var faults = outcome.failed
        if let skipped = outcome.skipped, faults.isEmpty {
            // Not a failure, but the same question: why is this machine not
            // holding what it was told to hold.
            faults["*"] = skipped
        }
        pendingSyncFaults = faults
    }

    /// One frame: fetch what the scene needs, render it, hand it back.
    ///
    /// The upload is part of the item rather than part of the report. A frame
    /// that rendered and did not arrive is a unit that has to be done again, and
    /// reporting the item complete before the bytes are safe would lose it
    /// quietly - the job would read 100% and the sequence would have a hole.
    private func renderOne(_ item: WorkItem, lease: ControlPlane.Lease) async throws {
        guard let renderer else { throw Failure.noRenderer }
        // The one value a submission contributes to a command line, and it is a
        // number before it gets anywhere near one.
        guard let frame = item["frame"]?.intValue else { throw Failure.notAFrame }

        // Stopped mid-frame, not between frames. A render is minutes long and
        // the loop's own yield check only runs between items, so without this a
        // machine whose owner sat down would keep a GPU busy until the frame
        // finished. The whole basis for borrowing these machines is that they
        // are given back at once.
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if await !self.stillPermits(.render) {
                    await renderer.stop()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        // Content comes with the job and leaves with it. The scene catalogue is
        // still read when a job was submitted the old way, so a queue that
        // spans the change drains rather than failing half of itself.
        let ready: (entry: URL, root: URL)
        if let attachments, let jobId = lease.jobId {
            let got = try await attachments.ensure(jobId: jobId)
            ready = (got.entry, got.root)
        } else if let scenes, let sceneId = lease.sceneId {
            let got = try await scenes.ensure(sceneId: sceneId)
            ready = (got.entry, got.root)
        } else {
            throw Failure.noScene
        }
        // Written beside the scene rather than into it, so a re-registered
        // scene never picks up somebody's output as one of its own files.
        let out = ready.root.deletingLastPathComponent()
            .appendingPathComponent("out/\(lease.unitId)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try await renderer.render(scene: ready.entry, frame: frame, into: out,
                                                samples: item["samples"]?.intValue)
        let bytes = try await controlPlane.uploadOutput(
            unitId: lease.unitId, name: outcome.file.lastPathComponent, file: outcome.file)
        log(String(format: "frame %d in %.1fs, %.1fMB returned",
                   frame, outcome.seconds, Double(bytes) / 1_048_576))
    }

    /// Delete job content nothing is coming back for.
    ///
    /// `release` covers every job this machine sees the end of. This covers the
    /// ones it does not: a job finished by another node, one cancelled, or an
    /// agent restarted mid-render. Without it, "the fleet does not keep your
    /// assets" would be true only of the tidy cases, which is the half that
    /// does not need a promise.
    ///
    /// Hourly, because it walks a directory and the thing it is looking for is
    /// a day old.
    private func sweepJobCachesIfDue() async {
        guard let attachments else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastCacheSweep >= 3600 else { return }
        lastCacheSweep = now
        await attachments.sweep()
    }

    /// Whether this kind is still allowed, right now.
    ///
    /// Read fresh rather than from the value the unit started with. That value
    /// was true when somebody was not at the machine, and the question being
    /// asked is whether they are now.
    private func stillPermits(_ kind: WorkKind) -> Bool {
        let now = presence()
        return availableKinds(policy[now.state] ?? now.policy).contains(kind)
    }

    /// Keep the certificate current.
    ///
    /// In the loop rather than on a timer of its own, because this is the loop
    /// that runs for as long as the machine is a fleet member. The renewer
    /// decides whether anything is actually due, and rate-limits its own
    /// retries, so calling it every pass costs a comparison.
    ///
    /// Awaited rather than detached, unlike a model transfer. Renewal is one
    /// small request, and the client it hands back has to be in place before
    /// the next heartbeat goes out on the certificate that was just retired.
    /// Serve what this machine's group serves.
    ///
    /// The model belongs to the group rather than to the machine. Before this,
    /// a node served whatever its daemon was started with - one argument in one
    /// plist per box - so a group could say it served a 14B while its two
    /// machines ran a 32B and a 30B between them, and nothing disagreed because
    /// nothing was comparing them.
    ///
    /// Safe because this is an actor. A swap cannot land in the middle of a
    /// generation: the work that uses the runtime is isolated to this actor too,
    /// so the two are serialised by construction rather than by a lock somebody
    /// has to remember.
    ///
    /// The old model's weights are released. Two runtimes holding two models is
    /// how a machine with 64GB ends up unable to load either.
    /// What a machine should do about the model it is holding.
    ///
    /// Three answers, where there used to be two, because `nil` meant two
    /// different things and only one of them was handled.
    ///
    /// **Nobody has said** is a group that has not been given a model yet, or a
    /// machine configured with one in its plist and left alone. Keep what you
    /// have: a group with no opinion is not an instruction to unload.
    ///
    /// **Handed back** is a machine that adopted a group's model and is no
    /// longer claimed by any enabled group - the case after a split tier is
    /// stood down. Both arrive as `nil`, and treating them alike left orca
    /// holding half a 32B for a group that no longer existed: 9.45 GB spent on
    /// somebody's workstation for a model no socket would route to, while every
    /// request went to the other machine.
    ///
    /// The distinction is whether the model being held is this machine's own or
    /// one it adopted. A machine can always answer that without being told.
    enum ServingDirective: Equatable {
        case keep
        case adopt(String)
        /// Let go of an adopted model and fall back to what this machine was
        /// configured to run. Not "unload and hold nothing": constructing a
        /// runtime allocates nothing and loading happens on the next request, so
        /// this releases the memory now and costs nothing until it is wanted.
        case release
    }

    static func directive(wanted: String?, current: String,
                          configured: String?) -> ServingDirective {
        if let wanted, !wanted.isEmpty {
            return wanted == current ? .keep : .adopt(wanted)
        }
        // Nobody is naming a model. Only meaningful if this machine is holding
        // something that was not its own.
        guard let configured, configured != current else { return .keep }
        return .release
    }

    private func adoptServingModel(_ wanted: String?) async {
        // Only a machine that already runs one. Starting a runtime on a node
        // that was configured without a GPU model is a different decision, made
        // where the runtimes are built and where whether MLX works at all is
        // known.
        guard let current = gpu else { return }
        let running = await current.name

        let replacement: MLXRuntime
        let adopted: String
        switch Self.directive(wanted: wanted, current: running,
                              configured: await configuredGPU?.name) {
        case .keep:
            return
        case .adopt(let model):
            log("group serves \(model); this machine is running \(running)")
            if await current.isLoaded { _ = await current.unload() }
            replacement = MLXRuntime(modelId: model)
            adopted = model
        case .release:
            // The group that asked for this is gone. Give the memory back now
            // rather than holding it until something else happens to want it -
            // the socket already told the caller these machines were handed
            // back, and that has to be true of the workstation as well as the
            // scheduler.
            guard let configured = configuredGPU else { return }
            log("no group serves this machine; releasing \(running) and returning to "
                + "\(await configured.name)")
            if await current.isLoaded { _ = await current.unload() }
            replacement = configured
            adopted = await configured.name
        }
        gpu = replacement
        // The name travels with the runtime rather than being asked of it: the
        // receiving loop is a different actor, and awaiting the new runtime just
        // to log its name would be a hop for a string we already have.
        await onServingModelChanged?(replacement, adopted)
        log("now serving \(adopted)")
    }

    /// Build the model now, when the group says to hold it loaded.
    ///
    /// A cluster group exists because the model is large, often too large for
    /// one machine, and a split cannot begin until every rank has built its
    /// share - so a cold gang pays the slowest machine's load before the first
    /// token and pays it again whenever the group falls idle. The operator
    /// already accepted the cost by standing the group up: those machines are
    /// out of harvesting for as long as it stands, so the memory is spoken for
    /// whether or not it holds anything.
    ///
    /// Only ever loads. Unloading is `adoptServingModel`'s to do, and having two
    /// paths that both release a model is how the batch loop once freed the one
    /// the serving loop was using.
    ///
    /// Failure is logged and not retried here. The next heartbeat asks again,
    /// which is the right cadence for something whose usual cause is a machine
    /// busy with the request that is keeping it warm in the first place.
    /// Whether a machine should let go of the model it is holding.
    ///
    /// The presence policy already answers "somebody wants their machine back".
    /// Nothing answered "nobody wants anything", so a harvest machine that
    /// served one request at nine in the morning held gigabytes until its owner
    /// returned - memory belonging to a person who was not being asked.
    ///
    /// A pure function so the rule can be tested without a GPU, as `passIsStuck`
    /// and `directive` already are. The clock is a parameter for the same
    /// reason.
    ///
    /// Cluster machines never release on idleness: dedicated means loaded, and a
    /// split that unloaded between requests would rebuild its share every time.
    /// They arrive here with no window at all rather than a very long one,
    /// because a very long number is one somebody eventually sets short.
    static func shouldReleaseWhenIdle(lastRequestEndedAt: Date?, now: Date,
                                      window: TimeInterval?) -> Bool {
        guard let window else { return false }
        // Nothing has been served since this machine started or last let go.
        // There is nothing held that this rule put there, so there is nothing
        // for it to release.
        guard let lastRequestEndedAt else { return false }
        return now.timeIntervalSince(lastRequestEndedAt) >= window
    }

    private func warmIfAsked(_ directives: ControlPlane.Directives) async {
        guard directives.keepLoaded, let runtime = gpu else { return }

        // A model that runs across machines is not this runtime's to hold.
        //
        // `MLXRuntime` knows nothing about splits: loading it builds the whole
        // model, so a machine warming half of a 32B would take all 18.4 GB to
        // serve 9.45 GB of it - and then never use it, because the split path
        // builds its own model with num_hidden_layers cut to this rank's range.
        // Peak memory became both at once on a machine with a 37.4 GB working
        // set: a mechanism meant to halve memory multiplying it instead.
        //
        // Warming the share itself is a different piece of work. Until it
        // exists, doing nothing is strictly better than doing this.
        guard !directives.isSplit else { return }

        guard await !runtime.isLoaded else { return }
        do {
            let seconds = try await runtime.load()
            log(String(format: "held loaded for this group: %@ in %.1fs",
                       await runtime.name, seconds))
        } catch {
            log("could not hold \(await runtime.name) loaded: \(error)")
        }
    }

    private func renewIfDue() async {
        guard let renewer else { return }
        // Asked takes precedence over due. Somebody who requested a renewal
        // wants it now, and the clock would say no for another twenty days.
        let replacement = renewRequested
            ? await renewer.renewNow(now: Date())
            : await renewer.renewIfDue(now: Date())
        if let replacement {
            if renewRequested { log("renewed because the control plane asked") }
            renewRequested = false
            controlPlane = replacement
            log("now presenting the renewed certificate")
            // Everything else in this process holding the old certificate has
            // to be told, because nothing else will notice. Renewal retires the
            // old certificate the moment the new one is issued, so every loop
            // still holding it is refused with "unknown certificate" until the
            // daemon restarts.
            //
            // This list is the whole of it, and it has been wrong twice. The
            // serving loop was missed first and reconnected every five seconds
            // to be refused; the sync loop was missed next and spent the time
            // reporting "could not ask what to hold", which the fleet view
            // showed as a machine not holding its models rather than as a
            // machine that had been locked out.
            await modelSync?.present(replacement)
            await scenes?.present(replacement)
            await attachments?.present(replacement)
            await onRenewed?(replacement)
        }
    }

    private func syncIfDue(_ reading: PresenceMonitor.Reading) async {
        let now = Date().timeIntervalSince1970
        guard now - lastHeartbeat >= 30 else { return }
        lastHeartbeat = now
        let paused = pauseSwitch.read().paused
        do {
            log("heartbeat: \(reading.state.rawValue)\(paused ? " (user paused)" : "")")
            let directives = try await controlPlane.heartbeat(
                state: reading.state,
                onACPower: reading.signals.onACPower,
                thermalOK: reading.signals.thermalOK,
                userPaused: paused,
                capability: capability,
                residentModels: await residentModels(),
                storedModels: StoredModels.scan(base: MLXRuntime.hubBase),
                syncFaults: pendingSyncFaults)
            // What the control plane wants from this node, which it can only
            // say on a beat this node sent: a harvested machine dials out and
            // never listens.
            if directives.renewRequested { renewRequested = true }
            await adoptServingModel(directives.servingModel)
            await warmIfAsked(directives)
            // Cleared only once the report has actually landed. A dropped
            // heartbeat is common and the reason a node is not holding its
            // models is exactly the sort of thing that would be lost by
            // clearing optimistically.
            pendingSyncFaults = nil
        } catch {
            // Best effort. An unreachable control plane must never widen what
            // the agent will do, so a failed heartbeat is simply dropped.
            log("heartbeat failed: \(error)")
        }
    }

    /// Publish what the machine's owner should be able to see.
    ///
    /// Called on every loop rather than on change, so a stale file means the
    /// daemon stopped rather than that nothing is happening. Those look
    /// identical in the menu bar otherwise, and mean opposite things.
    private func publish(_ reading: PresenceMonitor.Reading, permitted: [WorkKind],
                         activity: String, pause: PauseSwitch.State) async {
        status.updateBatch(
            presence: reading.state.rawValue,
            permitted: permitted.map(\.rawValue),
            activity: activity,
            paused: pause.paused, pauseReason: pause.reason,
            pausedByFleet: pausedByFleet,
            items: stats.items, units: stats.units, yields: stats.yields,
            residentGb: await (gpu?.isLoaded ?? false) ? (await gpu?.residentGb ?? 0) : 0)
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).suffix(9).prefix(8)
        print("[\(stamp)] \(message)")
    }

    // MARK: - Run

    public func run(maxSeconds: TimeInterval = .infinity) async {
        log("worker starting against control plane")
        // Released when the loop ends for any reason, including a test that
        // runs for half a second. An assertion outliving the thing that wanted
        // it is a machine pinned awake by nobody.
        defer { sleepAssertion.set(false) }
        do {
            let served = try await controlPlane.fetchPolicy()
            policy = mergePolicy(local: defaultPolicy, served: served)
            status.markReachable()
            log("policy merged with control plane (stricter of the two wins)")
        } catch {
            // The local table is the conservative one, so starting on it is
            // correct rather than a fallback.
            log("could not fetch policy, using local table: \(error)")
        }

        let deadline = Date().addingTimeInterval(maxSeconds)
        while Date() < deadline {
            let reading = presence()
            let statePolicy = policy[reading.state] ?? reading.policy
            await renewIfDue()
            await sweepJobCachesIfDue()
            await syncIfDue(reading)
            await syncModelsIfDue(reading)

            // Checked here, before anything else, and locally: the machine
            // owner's pause has to work with the control plane unreachable.
            // Waiting for the server to agree would make the button fail in
            // exactly the situation where someone is reaching for it.
            let pause = pauseSwitch.read()

            // Keep the machine reachable while it is lending capacity, and stop
            // the moment it is unplugged or paused by anyone. A workstation that
            // sleeps when locked contributes nothing during exactly the hours
            // this product is made of: orca went dark for four to seven minutes
            // at a time overnight while still answering pings, because a sleep
            // proxy replies on a sleeping Mac's behalf.
            //
            // Reading the switch once and using that value for both decisions,
            // so the assertion and the work can never disagree about whether
            // somebody has pressed pause.
            sleepAssertion.set(SleepPolicy.shouldStayAwake(
                onACPower: reading.signals.onACPower,
                userPaused: pause.paused,
                pausedByFleet: pausedByFleet))
            await publish(reading, permitted: pause.paused ? [] : availableKinds(statePolicy),
                          activity: pause.paused ? "paused by you"
                                    : pausedByFleet ? "paused by the fleet" : "waiting",
                          pause: pause)
            if pause.paused {
                if !wasPaused {
                    wasPaused = true
                    lastKinds = nil
                    log("PAUSED by the machine owner"
                        + (pause.reason.map { ": \($0)" } ?? "")
                        + "; releasing everything and standing down")
                    if let gpu, await gpu.isLoaded { _ = await gpu.unload() }
                    // Reported immediately rather than at the next heartbeat, so
                    // the fleet view stops offering this machine within seconds
                    // of someone asking it to stop.
                    lastHeartbeat = 0
                    await syncIfDue(reading)
                }
                try? await Task.sleep(for: .seconds(monitor.pollInterval))
                continue
            }
            if wasPaused {
                wasPaused = false
                lastHeartbeat = 0
                log("resumed by the machine owner")
                await syncIfDue(reading)
            }

            let kinds = availableKinds(statePolicy)
            // The single most useful line in this log. Without it, a node doing
            // nothing is indistinguishable from a node that thinks it is not
            // allowed to, and the two have completely different causes.
            if kinds != lastKinds {
                lastKinds = kinds
                log("\(reading.state.rawValue): "
                    + (kinds.isEmpty ? "no work permitted"
                                     : "may run " + kinds.map(\.rawValue).joined(separator: ", "))
                    + " (gpu=\(statePolicy.gpu) ane=\(statePolicy.ane) "
                    + "duty=\(String(format: "%.2f", statePolicy.dutyMax)) "
                    + "runtimes: gpu=\(gpu != nil ? "yes" : "no") ane=\(ane != nil ? "yes" : "no"))")
            }
            if kinds.isEmpty {
                if !isCluster, let gpu, await gpu.isLoaded {
                    let freed = await gpu.unload()
                    log("standing down in \(reading.state.rawValue); released in "
                        + String(format: "%.0fms", freed * 1000))
                }
                try? await Task.sleep(for: .seconds(monitor.pollInterval))
                continue
            }

            // Release the GPU model as soon as GPU work stops being permitted,
            // even though ANE work continues. E4 puts reload at 1-3s, so holding
            // it against a possible return is not worth the resident memory.
            // Never on a cluster node.
            //
            // The batch loop released the GPU model one second after the
            // serving loop loaded it - presence was ACTIVE, harvest policy
            // forbids GPU work, and nothing told this loop the node was exempt.
            // It destroyed the prompt cache on every request: an 18s reload and
            // a full prefill each time, turning a 0.5s warm request back into
            // 37.5s. Two loops sharing one runtime, and only one of them knew
            // the rules.
            if !isCluster, !kinds.contains(.generate), let gpu, await gpu.isLoaded {
                let freed = await gpu.unload()
                log("GPU work not permitted in \(reading.state.rawValue); released in "
                    + String(format: "%.0fms", freed * 1000))
            }

            var lease: ControlPlane.Lease?
            var failure: String?
            do {
                lease = try await controlPlane.leaseWork(kinds: kinds)
                if lease == nil { failure = await controlPlane.lastLeaseReason }
            } catch {
                // Previously `try?`, which turned every transport and HTTP
                // error into an indistinguishable nil. A node being refused
                // work by the server and a node whose requests are failing look
                // identical from outside, and this hid the second for an entire
                // debugging session.
                failure = "request failed: \(error)"
            }

            guard let lease else {
                // Keyed on the kinds too. Keying on the message alone meant that
                // asking for something different and being refused for the same
                // stated reason logged nothing at all.
                // The agent has no other way to know it has been paused
                // centrally: nothing pushes that down, and the refusal on a
                // lease is the first and only sign. Without this the machine
                // sat reporting "waiting for work" to its owner while the fleet
                // was refusing it, which reads as the agent being broken.
                pausedByFleet = failure?.contains("node-paused") ?? false

                let key = kinds.map(\.rawValue).joined(separator: ",") + "|" + (failure ?? "")
                if key != lastReason {
                    lastReason = key
                    log("asked for \(kinds.map(\.rawValue).joined(separator: ", ")), "
                        + "got none: \(failure ?? "unknown")")
                }
                try? await Task.sleep(for: .seconds(monitor.pollInterval))
                continue
            }
            lastReason = nil
            pausedByFleet = false

            await process(lease, statePolicy: statePolicy, state: reading.state)
        }

        if let gpu { _ = await gpu.unload() }
        log("done: \(stats.units) units, \(stats.items) items, \(stats.yields) yields")
    }

    private func process(_ lease: ControlPlane.Lease,
                         statePolicy: StatePolicy, state: PresenceState) async {
        if lease.kind == .generate, let gpu, await !gpu.isLoaded {
            do {
                let seconds = try await gpu.load()
                stats.loads += 1
                log("loaded GPU model in " + String(format: "%.2fs", seconds))
            } catch {
                log("model load failed: \(error)")
                try? await controlPlane.report(unitId: lease.unitId, completed: [],
                                               unfinished: lease.items, seconds: 0, failed: true)
                return
            }
        }

        applyQoS(statePolicy, kind: lease.kind)
        // Clear any stop from a previous unit. A renderer is latched off when
        // the machine is wanted back, and this unit exists only because it was
        // leased, which means render is permitted again. Clearing it here rather
        // than inside `render` keeps the latch honest: a stop issued while a
        // frame is starting must not be lost to a reset racing it.
        if lease.kind == .render { await renderer?.resume() }

        let started = Date()
        var completed: [WorkItem] = []
        // Items that were attempted and did not finish. Returned rather than
        // dropped: a dropped item leaves the unit marked done with a hole in
        // it, which for rendering is a missing frame in a sequence nobody
        // notices until it is played back. Requeuing is bounded - a unit that
        // fails everywhere runs out of attempts and fails properly, which is
        // what a broken payload should do.
        var failed: [WorkItem] = []

        for (index, item) in lease.items.enumerated() {
            // Re-check that *this* kind is still permitted, not merely that some
            // work is: a machine going from LOCKED to ACTIVE keeps ANE work
            // legal while revoking GPU work mid-unit.
            let now = presence()
            let current = policy[now.state] ?? now.policy
            guard availableKinds(current).contains(lease.kind) else {
                let unfinished = Array(lease.items[index...])
                stats.yields += 1
                status.recordYield(at: Date())
                log("YIELD -> \(now.state.rawValue); \(completed.count) done, "
                    + "\(unfinished.count) returned")
                try? await controlPlane.report(unitId: lease.unitId, completed: completed,
                                               unfinished: unfinished,
                                               seconds: Date().timeIntervalSince(started))
                return
            }

            let itemStart = Date()
            do {
                switch lease.kind {
                case .embed:
                    // Guarded like generate below, rather than quietly doing
                    // nothing. `if let ane { ... }` fell through to the line
                    // that marks an item completed, so a node with no ANE
                    // runtime would have reported every embed item done without
                    // running one. Unreachable today because this kind is only
                    // offered when the runtime exists - which is exactly the
                    // invariant worth asserting rather than relying on.
                    guard let ane else { throw Failure.noANERuntime }
                    _ = try await ane.run(item: item)
                case .generate:
                    guard let gpu else { throw Failure.noGPURuntime }
                    let prompt = item["prompt"]?.stringValue ?? ""
                    _ = try await gpu.generate(prompt: prompt,
                                               maxTokens: statePolicy.maxCompletionTokens)
                case .render:
                    try await renderOne(item, lease: lease)
                }
                completed.append(.object(["id": item["id"] ?? .null]))
            } catch {
                log("item failed: \(error)")
                failed.append(item)
            }

            // E2 found duty cycle a real, monotonic lever independent of QoS.
            // ANE work is exempt: throttling something already invisible costs
            // throughput for nothing.
            let duty = lease.kind.isGPU ? statePolicy.dutyMax : 1.0
            if duty > 0, duty < 1 {
                let worked = Date().timeIntervalSince(itemStart)
                try? await Task.sleep(for: .seconds(worked * (1 / duty - 1)))
            }
        }

        let seconds = Date().timeIntervalSince(started)
        stats.items += completed.count
        stats.units += 1
        if seconds > 0, !completed.isEmpty {
            // Workload class rather than kind: throughput differs by model,
            // which is why the scheduler stores a profile rather than a scalar.
            let key = lease.kind == .generate ? (await gpu?.name ?? "generate") : "ane:embed"
            capability[key] = Double(completed.count) / seconds
        }
        let outcome = try? await controlPlane.report(unitId: lease.unitId, completed: completed,
                                                     unfinished: failed, seconds: seconds)
        // Deleted the moment the job is over rather than left for the sweep.
        // The difference is a day of somebody else's disk, on a machine the
        // agent is a guest on.
        if outcome?.jobFinished == true, let jobId = lease.jobId, let attachments {
            await attachments.release(jobId: jobId)
        }
        status.markReachable()
        log("\(lease.kind.rawValue)"
            + (lease.jobLabel.map { " [\($0)]" } ?? "")
            + (lease.jobSource == "api" ? "" : " (\(lease.jobSource))")
            + ": \(completed.count) items"
            + (failed.isEmpty ? "" : ", \(failed.count) returned")
            + " in "
            + String(format: "%.2fs", seconds)
            + " (\(String(format: "%.2f", Double(completed.count) / max(seconds, 0.001)))/s) "
            + "state=\(state.rawValue)")
    }
}
