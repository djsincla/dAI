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
| **E1** | Can MLX reach Metal from a `launchd` daemon with no user session? | Agent ✅ · Daemon ⏳ |
| **E2** | At what memory ceiling and QoS does the interactive user notice? | Harness built ✅ · Sweep ⏳ |
| **E3** | What is aggregate throughput vs. an API call or a rented GPU hour? | Not started |
| **E4** | What does preemption cost, and what work-unit size amortizes it? | Not started |
| **E5** | Is ANE work less perceptible than GPU work? | Not started |

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

- MLX 0.32.0 runs from a `LaunchAgent` in the user's Aqua session, GPU verified.
- **Background QoS costs ~2.4× GPU throughput** (~3183 vs ~7830 GFLOPS fp32).
  `ProcessType: Background` matches `taskpolicy -b`. This is the politeness
  dial, so it should be dynamic — Background while a user is present, promoted
  to Standard once the machine is confirmed idle.
- Metal self-caps at `max_recommended_working_set_size` = 51.8 GiB on a 64 GB
  machine (~81%). Agent memory ceilings sit under *that*, not under installed RAM.
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
  e1_metal_access/     probe + launchd plists + runner for the E1 gate
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
