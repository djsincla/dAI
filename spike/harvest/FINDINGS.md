# Harvest worker — fleet dispatch with presence-driven yield

The intersection nothing had tested. E3 measured a fleet with nobody at the
keyboards; E2 and E5 measured contention with no scheduler. This runs both at
once.

## It works end to end

Driven by a real signal — `caffeinate -d` holds a genuine
`PreventUserIdleDisplaySleep` assertion, the same one a video call or media
playback holds, which `presence.py` classifies as PASSIVE. The worker is told
nothing.

```
[00:54:10]  loaded model in 3.68s (state=IDLE)
[00:56:23]  YIELD -> PASSIVE (user present); 6 done, 2 returned
[00:56:25]  standing down in PASSIVE; released in 452ms
[00:57:32]  loaded model in 4.64s (state=IDLE)          <- resumed
```
```
harvest-test   6 items in 133.38s   394 left   YIELD +2 requeued
```

Detect → yield mid-unit → return unfinished items → coordinator requeues →
unload → resume. Yield granularity is **between items, not between work units**:
a unit is a batch, so checking only at unit boundaries would let a whole batch
run on after someone returns.

## Background QoS costs ~26x on bursty work, not 2.4x

E1 measured background QoS at ~2.4x on a sustained 50-iteration matmul loop.
A harvest worker does not look like that. Measured on the real item path,
0.5B model, 24 tokens, same code and only the QoS flag differing:

| QoS | Per item | Samples |
|---|---|---|
| standard | **0.136 s** | 0.137, 0.135, 0.135, 0.137 |
| background | **3.528 s** | 1.997, 3.858, 3.409, 4.848 |

**26x, with large variance.** Each item is a 0.136 s burst with Python between
GPU submissions, and under background priority macOS deschedules the process in
those gaps. A continuous stream amortises that; fine-grained work does not.

This is why the first working run managed only 6 items in 133 s. IDLE stacked
background QoS (26x) on top of duty 0.25 (4x).

**Generalisation worth carrying: QoS penalties measured on sustained workloads do
not transfer to bursty ones.** Any throughput figure taken from a tight loop is
optimistic for a worker that interleaves CPU and GPU work.

## Consequence: IDLE became ANE-only

GPU work is now permitted only in LOCKED and ABSENT.

| State | GPU | ANE | QoS | duty_max | mem_frac |
|---|---|---|---|---|---|
| ACTIVE | ✗ | ✓ | background | 0.00 | 0.00 |
| PASSIVE | ✗ | ✓ | background | 0.00 | 0.15 |
| IDLE | ✗ | ✓ | background | 0.00 | 0.35 |
| LOCKED | ✓ | ✓ | standard | 1.00 | 0.70 |
| ABSENT | ✓ | ✓ | standard | 1.00 | 0.85 |

IDLE previously allowed GPU at background/0.25, the gentlest setting E2 measured.
Two findings compound against it: E2 put that setting at +46% of viewport p95
(the screen is on, the user may be reading), and the 26x burst penalty made the
resulting throughput negligible anyway. Paying a visible cost for almost no work
is the worst available trade.

Where GPU harvesting does run — LOCKED and ABSENT — standard QoS applies and
neither penalty exists.

**This raises the stakes on E5 again.** ANE work is now the *only* thing a
harvest worker may do while a user is logged in at all, across three of five
states. The Core ML worker path is no longer an optimisation.

## Bug found: sleep assertions are not a contention signal

The first two test runs produced no work at all. The worker was correctly in
IDLE with 300+ seconds of HID idle, but a single `caffeinate` assertion tripped a
"machine busy" gate that forced `gpu: false`.

`PreventUserIdleSystemSleep` means only "do not sleep". Safari, `coreaudiod`,
music players, downloads and `caffeinate` hold it more or less permanently, so
gating on it blocks harvesting entirely on any normally-used machine.

This is the **same failure as the earlier sharingd/Handoff bug, one layer down**.
That fix split display assertions from system assertions so presence would be
classified correctly — and then used the system assertions as a hard policy gate,
which is just as wrong. The gate is removed; the signal is still surfaced for
observability. A real contention signal would have to measure utilisation.

## Design notes

- **Partial results make preemption cheap.** The worker returns completed items
  and hands back what it did not reach; the coordinator requeues the remainder at
  the head of the queue. Without this a yield would cost a whole batch, which is
  the expense E4's economics exist to avoid.
- **QoS follows presence at runtime** via `setpriority(PRIO_DARWIN_PROCESS, 0,
  PRIO_DARWIN_BG)` — the same mechanism `taskpolicy -b` uses, callable on self,
  so it is not fixed at launch by a plist.
- **Capability estimates ignore yielded units.** A yield with zero items done
  would otherwise register as zero throughput and poison the node's profile in
  the scheduler.
- **Promotion delay is configurable but defaults long** (300 s). E4 showed a
  false "they are gone" costs a model load and an immediate preemption. Tests
  lower it; production should not.

## The ANE path: a logged-in machine now contributes

GPU work is permitted in only two of five presence states, so without an ANE
runtime a logged-in machine stood down entirely. `ane_runtime.py` adds the
second runtime and the worker now advertises which *kinds* of work it may
currently run.

**Work is typed and capability-negotiated.** Units carry a `kind`; the worker
sends `?kinds=embed,generate` reflecting what policy permits right now; the
coordinator serves only those and keeps separate queues. Running in IDLE with a
mixed 200-item corpus:

    queues at start:  {generate: 100, embed: 100}
    queues after:     {generate: 100, embed: 0}

The GPU queue is untouched while the ANE queue drains completely — which is
exactly the policy made visible, and the first time a machine with a user logged
into it has done any work at all.

**Placement is verified at load, and the runtime refuses to start without it.**
Core ML treats `CPU_AND_NE` as a preference and falls back to CPU silently. A
worker that believed it was on the ANE while actually running on the CPU would
be disturbing the very user it is trying to avoid, and every log would look
fine. `MLComputePlan` is checked at load and anything below 80% ANE residency
is rejected rather than run.

### Two bugs, ~50x between them

ANE throughput started at 0.5 items/s against 36.7 items/s for the same model
run standalone.

**Background QoS was being applied to ANE work.** Duty cycling had been exempted
but QoS had not. E5 measured ANE work as invisible, so there is nothing to be
polite about — and background QoS costs ~26x on bursty items. The worker was
paying a large throughput tax to buy politeness that was already free, in
precisely the states where ANE work is the *only* thing permitted. Making QoS
kind-aware: **0.5 -> 6.5 items/s**.

**Presence polling cost 4x the work it guarded.** `read_signals()` is ~116 ms —
six subprocess calls (`ioreg`, `pmset` x3, `stat`) — against a 27 ms ANE item.
Polling per item spent 81% of the worker's time asking whether the user was
back. Caching for `POLL_INTERVAL_ACTIVE` costs nothing in responsiveness,
because that interval already *is* the designed yield latency (E4: sampling
frequency dominates end-to-end yield, not the ~20 ms release). **6.5 -> ~30
items/s**, matching the standalone ceiling.

Both errors share a shape worth noting: **a safety mechanism sized without
reference to the work it protects.** Politeness that costs 26x where it buys
nothing, and a check costing 4x the operation it guards.

## Caveats

- Single machine, single yield cycle. Not yet run across the fleet with both
  nodes yielding independently.
- Yield latency was not measured precisely — the log shows detection to unload
  within ~2 s, but that bound is the poll interval plus item duration, and item
  duration was inflated by the QoS bug during the run that produced it.
- The ANE workload is E5's verified conv stack, not a real embedding model.
  Converting one needs torch and is a separate task; the mechanism, placement
  verification and policy integration are what this exercises, and swapping the
  model changes only `ANERuntime.run`.
- The GPU path has still only been exercised in IDLE and PASSIVE. LOCKED and
  ABSENT — where `generate` work actually runs — need a locked screen to test.
- Everything now runs on one Python 3.13 venv (`.venv-harvest`) carrying both
  MLX and coremltools, which also matches orca. The 3.12/3.14 split is gone.
