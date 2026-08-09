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
        public var description: String {
            "this node has no GPU runtime; generate work should not have been leased to it"
        }
    }

    private let controlPlane: ControlPlane
    private let source: SignalSource
    private let monitor: PresenceMonitor
    /// Optional because a machine can be a useful fleet member without a
    /// working GPU runtime. MLX needs a Metal shader library built by a
    /// toolchain that is a separate Xcode download, and a machine missing it
    /// should still harvest ANE work rather than refuse to start: three of the
    /// five presence states permit nothing but ANE work anyway, so the GPU
    /// runtime is not what most of the fleet's hours are made of.
    private let gpu: MLXRuntime?
    private let ane: ANERuntime?

    private var policy: [PresenceState: StatePolicy] = defaultPolicy
    private var cached: PresenceMonitor.Reading?
    private var cachedAt: TimeInterval = 0
    private var qosBackground: Bool?
    private var capability: [String: Double] = [:]
    private var lastHeartbeat: TimeInterval = 0
    /// Last reported set of permitted kinds, so a change can be logged once
    /// rather than every poll.
    private var lastKinds: [WorkKind]?
    private var lastReason: String?

    public struct Stats: Sendable {
        public var items = 0
        public var units = 0
        public var yields = 0
        public var loads = 0
    }
    public private(set) var stats = Stats()

    public init(controlPlane: ControlPlane, source: SignalSource = MacSignalSource(),
                gpu: MLXRuntime? = nil, ane: ANERuntime? = nil,
                promoteAfter: TimeInterval = idlePromoteSeconds) {
        self.controlPlane = controlPlane
        self.source = source
        self.monitor = PresenceMonitor(promoteAfter: promoteAfter)
        self.gpu = gpu
        self.ane = ane
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

    /// Work kinds permitted *right now*, which is not the same as what this node
    /// is capable of. Advertised to the control plane so it hands out only
    /// servable work rather than work the agent must immediately hand back.
    private func availableKinds(_ p: StatePolicy) -> [WorkKind] {
        var kinds: [WorkKind] = []
        if p.ane, ane != nil { kinds.append(.embed) }
        // Advertising generate without a runtime to serve it would have the
        // control plane hand out work this node must immediately give back.
        if p.gpu, p.dutyMax > 0, gpu != nil { kinds.append(.generate) }
        return kinds
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
        return out
    }

    private func syncIfDue(_ reading: PresenceMonitor.Reading) async {
        let now = Date().timeIntervalSince1970
        guard now - lastHeartbeat >= 30 else { return }
        lastHeartbeat = now
        do {
            log("heartbeat: \(reading.state.rawValue)")
            try await controlPlane.heartbeat(
                state: reading.state,
                onACPower: reading.signals.onACPower,
                thermalOK: reading.signals.thermalOK,
                capability: capability,
                residentModels: await residentModels())
        } catch {
            // Best effort. An unreachable control plane must never widen what
            // the agent will do, so a failed heartbeat is simply dropped.
            log("heartbeat failed: \(error)")
        }
    }

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).suffix(9).prefix(8)
        print("[\(stamp)] \(message)")
    }

    // MARK: - Run

    public func run(maxSeconds: TimeInterval = .infinity) async {
        log("worker starting against control plane")
        do {
            let served = try await controlPlane.fetchPolicy()
            policy = mergePolicy(local: defaultPolicy, served: served)
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
            await syncIfDue(reading)

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
                if let gpu, await gpu.isLoaded {
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
            if !kinds.contains(.generate), let gpu, await gpu.isLoaded {
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
        let started = Date()
        var completed: [WorkItem] = []

        for (index, item) in lease.items.enumerated() {
            // Re-check that *this* kind is still permitted, not merely that some
            // work is: a machine going from LOCKED to ACTIVE keeps ANE work
            // legal while revoking GPU work mid-unit.
            let now = presence()
            let current = policy[now.state] ?? now.policy
            guard availableKinds(current).contains(lease.kind) else {
                let unfinished = Array(lease.items[index...])
                stats.yields += 1
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
                    if let ane { _ = try await ane.run(item: item) }
                case .generate:
                    guard let gpu else { throw Failure.noGPURuntime }
                    let prompt = item["prompt"]?.stringValue ?? ""
                    _ = try await gpu.generate(prompt: prompt,
                                               maxTokens: statePolicy.maxCompletionTokens)
                case .render:
                    break  // not yet implemented
                }
                completed.append(.object(["id": item["id"] ?? .null]))
            } catch {
                log("item failed: \(error)")
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
        try? await controlPlane.report(unitId: lease.unitId, completed: completed,
                                       unfinished: [], seconds: seconds)
        log("\(lease.kind.rawValue): \(completed.count) items in "
            + String(format: "%.2fs", seconds)
            + " (\(String(format: "%.2f", Double(completed.count) / max(seconds, 0.001)))/s) "
            + "state=\(state.rawValue)")
    }
}
