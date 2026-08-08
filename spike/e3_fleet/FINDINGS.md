# E3 - Fleet throughput and heterogeneous scheduling

**Fleet:** `rotorua` MacBook Pro M2 Max / 64 GB / macOS 26.3 · `orca` M4 Pro (10P+4E) / 48 GB / macOS 26.5.1
**Network:** WiFi, 8–47 ms RTT (avg 27 ms)
**Workload:** batch classification, 24 output tokens per item, 4-bit MLX models

## Result

| Workload | rotorua | orca | M2 Max advantage | Aggregate | Sum of solo | Efficiency |
|---|---|---|---|---|---|---|
| Qwen2.5-1.5B | 5.133/s | 4.776/s | **+7.5%** | 9.429/s | 9.909/s | **0.952** |
| Qwen2.5-7B | 1.990/s | 1.576/s | **+26.3%** | 3.433/s | 3.566/s | **0.963** |

## Capability is workload-dependent, not a machine property

The same two machines running the same code differ by 7.5% on a 1.5B model and
26.3% on a 7B - **relative capability moved 3.5x purely from model size.**

Neither number matches the spec sheet. Memory bandwidth is ~400 GB/s on the M2
Max against ~273 GB/s on the M4 Pro, a 47% advantage. Observed: 7.5% at 1.5B,
26.3% at 7B, trending toward but not reaching the bandwidth ratio.

The mechanism is what the ratio is *made of*. At 1.5B with 24-token outputs,
per-item fixed costs - tokenization, prompt evaluation, sampling setup - dominate,
and the M4 Pro's newer cores close most of the gap. At 7B the weights actually
have to stream, bandwidth starts to bind, and the older wider chip pulls ahead.

**Consequence for the scheduler:** a single stored capability score per node is
wrong. Weighting by bandwidth would have over-loaded rotorua by 40% on the 1.5B
run; weighting by the 1.5B result would under-load it by 20% on the 7B run.
Capability has to be probed **per workload class** and kept as a running
estimate from completed units, which is what `coordinator.py` does. The Phase 1
capability probe should record a profile per workload family, not a scalar.

This also disposes of the tempting shortcut of ranking nodes by chip generation
or core count. The newer chip is the slower one here, and by a margin that
depends on what you ask it to do.

## Coordination is not the bottleneck at this scale

Scaling efficiency of 0.952 and 0.963 against the sum of solo rates, over WiFi
with 27 ms average RTT. Pull-based batching absorbs network latency well because
round-trips amortise across ~1.5 s work units.

The residual loss is a straggler tail, not network overhead: orca finished 6.3 s
before rotorua on the 7B run (7.3% idle) and 5.3 s before it on the 1.5B run
(8.4%). That is the granularity cost of a fixed batch size - the last batch each
node takes is sized for steady state, not for the end of the queue. Tapering
batch size as the queue drains, or plain work-stealing, would recover most of it.

**This does not predict n=20.** Two nodes prove the mechanism works; they say
nothing about coordinator load, tail stragglers, or contention at fleet scale.

## Weighted dispatch barely engaged

At a 7.5% spread, `8 * rate/mean` rounds to 8 for both nodes, so the 1.5B run was
effectively round-robin. The observed 324/276 work split came from pull-based
self-pacing - fast nodes simply ask for more work sooner - rather than from the
weighting logic.

That is worth stating plainly: **pull-based dispatch is self-balancing, and
capability weighting is a second-order correction on top of it.** Weighting earns
its keep on wide spreads (an M1/8 GB beside an M3 Ultra/512 GB) and on sizing
units so a preemption loses proportionally similar work everywhere. A
round-robin comparison run was skipped for this reason: at these spreads it would
measure nothing.

## Incidental finding: MLX works as a non-console user

`orca` had `kim` logged in at the console while the worker ran over SSH as
`dwayne`. Metal was reachable and GPU matmuls executed normally.

That is a session context E1 did not cover - E1 tested a root daemon in session
0 and a LaunchAgent in the console user's Aqua session. Adds evidence that Metal
access on Apple Silicon is not gated on owning the console session.

## Outstanding

- **Cost comparison against API and rented GPU was not completed.** Aggregate 7B
  throughput is ~82 output tokens/s across both machines, perhaps 25x below a
  datacenter GPU, against a marginal cost of roughly electricity. Doing this
  properly needs measured wall power, not estimates, and the plan's position is
  that sovereignty rather than price-performance is the argument anyway.
- **Wider capability spread untested.** Both machines are within 26% of each
  other. The scheduling behaviour that matters - an 8 GB node beside a 512 GB
  one - is unexercised.
- **No preemption during the run.** E3 measured a quiet fleet. Combining it with
  presence-driven yield is the real test of the harvest tier.

## Reproducing

```bash
# coordinator (any node)
python3 coordinator.py --corpus 300 --policy weighted --min-workers 2

# each worker
curl -fsSL http://<coordinator>:8712/bootstrap.sh | bash
```

`--min-workers` holds dispatch until the whole fleet checks in; without it the
faster node drains the queue while a late joiner is still installing, and the run
measures one machine while reporting two.
