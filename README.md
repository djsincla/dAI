# dAI — Distributed AI on Harvested Apple Silicon

Centrally scheduled AI compute harvested from idle Apple Silicon workstations.

The premise comes from the second-GPU render farm: hardware that is already
bought and sits idle 16 hours a day can do useful work at a marginal cost of
roughly electricity — and, critically, without data ever leaving the building.

**Positioning is sovereignty and sunk cost, not price-performance.** Per-token,
harvested Macs lose to both cloud APIs and rented GPUs. The winning arguments
are that the marginal cost is electricity and that the data stays on premises.

Full design: [`docs/PLAN.md`](docs/PLAN.md).

## Where the analogy breaks

The render farm worked because of *physical* isolation — a dedicated card the
artist's session could not touch. Apple Silicon has unified memory: GPU, CPU,
and ANE share one memory pool and one bandwidth budget with the artist's
interactive work. Isolation here is **policy-enforced, not hardware-enforced**,
which is a much weaker guarantee.

Socially there is about one strike. One artist noticing their machine got slow
will end the program.

## Status: Phase 0 validation spike

No product code yet. The spike answers the questions that could kill or reshape
the idea before any architecture is committed.

| Experiment | Question | Status |
|---|---|---|
| **E1** | Can MLX reach Metal from a `launchd` daemon with no user session? | **PASSES** ✅ |
| **E2** | At what memory ceiling and QoS does the interactive user notice? | Harness built ✅ · Sweep ⏳ |
| **E3** | What is aggregate throughput vs. an API call or a rented GPU hour? | **Scheduling ✅ · cost ⏳** |
| **E4** | What does preemption cost, and what work-unit size amortizes it? | **PASSES** ✅ |
| **E5** | Is ANE work less perceptible than GPU work? | **PASSES** ✅ |

E1 is the existential gate — if GPU access requires an active GUI session, the
fleet is limited to logged-in-but-idle machines and the product is materially
weaker. See [`spike/e1_metal_access/FINDINGS.md`](spike/e1_metal_access/FINDINGS.md).

### A note on the E2 workloads

`spike/e2_contention/` drives an Xcode build and a Blender viewport. **Neither is
part of the product.** dAI is distributed AI compute; nothing about rendering or
graphics ships.

They are *victim workloads* — instruments standing in for "whatever the human at
this machine is doing that must not be disturbed." The central claim is that
idle Macs can be harvested without their owner noticing, and that claim is
untestable without measuring something a human actually looks at. The two
instruments cover different contention paths:

- **Xcode build** — CPU-side, contends for *memory bandwidth*
- **Blender viewport** — contends for the *GPU directly*, and sets the stricter
  threshold, because people perceive frame stutter far more acutely than a
  batch job finishing slightly late

### Confirmed so far

- **E1 passes.** MLX reaches Metal from a `LaunchDaemon` in session 0 (`uid 0`,
  `security_session = System`), screen locked or unlocked, and every presence
  signal stays readable there. **The node agent can ship as a single system
  daemon** — no split into a computing daemon plus a sensing agent, and no
  dependency on a logged-in user. Reading presence via IOKit and `pmset` rather
  than AppKit was the load-bearing decision.
  *Still open:* the fully-logged-out `ABSENT` state is untested, which caps
  confidence in overnight capacity but is no longer existential.
- **Background QoS costs ~2.4× GPU throughput** (~3183 vs ~7830 GFLOPS fp32).
  `ProcessType: Background` matches `taskpolicy -b`. This is the politeness
  dial, so it should be dynamic — Background while a user is present, promoted
  to Standard once the machine is confirmed idle.
- Metal self-caps at `max_recommended_working_set_size` = 51.8 GiB on a 64 GB
  machine (~81%). Agent memory ceilings sit under *that*, not under installed RAM.
- **Preemption is ~20x cheaper than the plan assumed.** A 14B 4-bit model loads
  in 1.4 s warm / 2.8 s cold and releases in 28 ms, against a planned assumption
  of 30-60 s. Unified memory is why: there is no host→device PCIe transfer, so
  weights land straight in memory the GPU already addresses. Minimum work units
  are 4-25 s, not the ~10 minutes targeted. **The agent should yield
  aggressively** — the reload costs seconds.
- **Yield latency is now dominated by presence polling, not memory release.**
  Release is ~20 ms; polling at 2 s means up to 2 s of work continues after a
  user returns. Tune the polling interval, not the release path.
- **Capability is workload-dependent, not a machine property.** Across an
  M2 Max/64 GB and an M4 Pro/48 GB, the M2 Max led by 7.5% on a 1.5B model and
  26.3% on a 7B — relative capability moved 3.5x from model size alone, and
  neither figure matches the 47% their memory-bandwidth ratio predicts. A stored
  per-node capability scalar would misallocate by 20-40% depending on workload.
  **The Phase 1 probe must profile per workload class, not per machine.** Note
  the newer chip is the slower one, so generation and core count rank nodes
  backwards here.
- **Fleet coordination is not the bottleneck.** Scaling efficiency 0.952 (1.5B)
  and 0.963 (7B) over WiFi at 27 ms RTT; pull-based batching amortises
  round-trips across ~1.5 s units. Residual loss is a 7-8% straggler tail from
  fixed batch sizing, not network overhead. Says nothing about n=20.
- **ANE load is indistinguishable from no load.** Sustaining 169 inferences/s of
  verified Neural Engine work, viewport p95 moved −16% — inside a 36% baseline
  noise floor — against +59% to +100% for equivalent GPU work. Placement proven
  with `MLComputePlan` (100% of ops on `MLNeuralEngineComputeDevice`), not
  assumed. **This makes daytime harvesting viable**, roughly doubling usable
  fleet hours. E5 says ANE work is *invisible*, not that it is *fast*.
- **Memory fraction is not a politeness dial.** A 4 GB load on a 64 GB machine
  degraded p95 by 100%. Footprint governs what fits, not how much a user is
  disturbed; throttling disturbance needs a compute-rate limit.
- **Baselines must be interleaved.** Viewport p95 moved 36% between runs with
  nothing loaded. A single leading baseline silently attributes that drift to
  whichever condition ran next — it manufactured, then unmanufactured, a finding.
- **Contention shows up in the tail, not the median.** One unreplicated run at a
  25 GB ceiling under background QoS: p50 frame time moved +3% while p95 moved
  +65% and p99 +82% (mean fps 68.7 → 53.4). Reporting medians or mean fps would
  have read as "negligible impact"; the tail is where the user sees stutter.
  This is why the harness reports percentiles and hitch counts.

## Runtime

**MLX** — Apple's own framework, built around unified memory. Phase 1 targets
`mlx-swift` so the node agent ships as a single signed binary with no Python on
the fleet. **Core ML** is a second, narrow runtime for ANE work, which matters
because the ANE is separate silicon from the GPU and is the closest thing Apple
Silicon has to the original dedicated card.

## Layout

```
spike/
  e1_metal_access/     Metal + presence access from a session-0 daemon (E1)
  e2_contention/       victim workloads + MLX load generator (E2)
  e4_preemption/       model load/release cost and work-unit sizing (E4)
  e5_ane/              ANE vs GPU contention, with placement verification (E5)
  e3_fleet/            coordinator + worker; heterogeneous scheduling (E3)
  presence/            user-presence detection: the agent's primary control
docs/
  PLAN.md              full design: tiers, use cases, architecture, verification
```

## Running the spike

```bash
cd spike
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt

# E1 baseline (interactive)
E1_CONTEXT=interactive ./.venv/bin/python e1_metal_access/probe.py /tmp/e1.json

# E1 gate (daemon, session 0, root)
cd e1_metal_access
sudo ./run_daemon_test.sh install     # samples every 20s
# lock the screen ~60s, unlock; optionally log out ~60s and back in
./run_daemon_test.sh collect
sudo ./run_daemon_test.sh uninstall
```

> The `launchd` plists carry absolute paths to this checkout. Adjust them if you
> clone somewhere other than `/Users/dwayne/Developer/dAI`.

Requires Apple Silicon and macOS 26+.
