# Cluster tier - admission control

Measured on `rotorua` (M2 Max / 64 GB) + `orca` (M4 Pro / 48 GB) over the
dedicated gigabit link, using `admit.py`.

## The gate decides correctly

| Case | Model | Layers | Decision | Reason |
|---|---|---|---|---|
| 1 | 7B-4bit, 4 GB | 28 | REFUSED | Fits on a single node (37.4 GB available); sharding costs ~6.6x for no benefit |
| 2 | 110B-4bit, 55 GB | 80 | **REFUSED** | Capacity fine (55 < 59 GB) but projected **3.68 tok/s** is below the 8.0 floor |
| 3 | 400 GB | 120 | REFUSED | 2.0 tok/s *and* exceeds the 59 GB pool capacity |

Pool capacity is `2 x 37.4 GB / 1.27 = 59 GB`, bounded by the **smaller** node.
Per-node figures are Metal working sets (51.8 and 37.4 GB), not installed RAM.

All-reduce measured 0.61-0.77 ms while the remote node carried a load average of
50 during post-reboot indexing, against 0.563 ms on a quiet machine. The
interconnect measurement is more robust to system load than expected.

## Model depth, not model size, is the binding constraint

Case 2 is the result worth keeping. A 110B model **fits** this pool and is still
refused, because it has 80 layers and tensor parallelism pays ~2 all-reduces per
layer per token - 160 round-trips per token against a 7B's 56.

Solving for the largest model depth that clears an 8 tok/s floor:

| Interconnect | All-reduce | Max layers |
|---|---|---|
| WiFi | 16.687 ms | ~1 |
| Gigabit Ethernet | 0.61 ms | **~38** |
| Thunderbolt 4 (est. 0.1 ms) | ~0.1 ms | ~230 |

**A 70B has 80 layers; a 110B has ~88.** At gigabit only 7B-13B class models
clear the floor - and those fit on a single node, so they should never be
sharded in the first place. The set of models that both *need* the cluster tier
and *pass* admission at gigabit is empty.

### This corrects an earlier conclusion

E6 concluded, after measuring a 28-layer 7B, that "Thunderbolt is now an
optimisation rather than a prerequisite" because gigabit delivered a usable
11.69 tok/s. That generalised from the wrong model.

Per-token cost scales linearly with depth, and the models that justify a cluster
tier are 80+ layers. **Thunderbolt is a requirement for this tier, not an
optimisation.** Gigabit is sufficient only for the harvest tier, which is
interconnect-insensitive.

The admission gate caught this; the E6 benchmark did not. A gate that encodes
the decision rule surfaces constraints that a benchmark measuring one
configuration will miss.

## Operational requirements learned the hard way

`orca` vanished twice during this work - once asleep, once from a flat battery -
and a gang-scheduled job dies when any member goes.

**These are deliberately not enforced at admission for now.** On laptops in
active use, requiring AC power and disabled sleep would make the tier unusable,
and this is a development fleet. Recorded as a production consideration:

- **AC power**, with battery state health-checked before a job is scheduled
- **Sleep disabled** (`caffeinate -dimsu` or `pmset` policy)
- Health checks that fail a pool *before* work is dispatched onto it, not after

Not enforcing them creates an obligation instead: the gang scheduler must handle
node loss cleanly - detect the member going away, fail the job with a specific
reason rather than hanging, release the pool, and requeue rather than strand.
`caffeinate -dimsu -t <seconds>` remains available as an opt-in for a specific
run without making it a standing rule.

The harvest tier already handles the power case through its on-battery policy
gate. Notably, the node that drained its battery was running the older
`e3_fleet/worker.py`, which has no presence logic at all - the tier with the
safety mechanism survived, the one without it died.

## What admission checks, and why each threshold exists

- **Fits on one node** → refuse. Sharding costs 6.6x throughput (11.69 vs 77.46
  tok/s measured) to save 43% of per-node memory.
- **Pool capacity** = `N x smallest_node / 1.27`. Every rank transiently holds
  ~1.27x its slice during a lazy load. `lazy=True` is mandatory: eager loading
  peaks at 5.01 GB against a 3.99 GB model, so a fleet would OOM on precisely
  the model the extra machines were bought for.
- **Projected throughput** applies a 0.37 realisation factor to the comm-only
  ceiling. The raw ceiling predicted 31.72 tok/s where reality delivered 11.69;
  admitting on the ceiling would promise 2.7x what the pool serves.

## Serving front-end

`serve.py` puts an OpenAI-compatible endpoint on a cluster pool. Verified across
both nodes over the gigabit link, Qwen2.5-7B-4bit:

```
loaded   nodes 2, load 1.38s, resident 2.28 GB/rank, peak 2.79 GB/rank
request  43 prompt + 34 completion tokens
result   4.3s, 7.91 tok/s
```

Against **77.5 tok/s on one machine**, which is the same story E6 told: over
gigabit this serves a model that would not otherwise fit, and pays roughly a 10x
throughput penalty to do it.

Peak of 2.79 GB against a 3.99 GB model confirms `lazy=True` is doing its job.
Eager loading peaks above the full model size on every rank, so a pool would OOM
on precisely the model the extra machines were bought for.

### The lockstep problem, and how the protocol avoids a second channel

Tensor parallelism means every rank runs the same forward pass. HTTP arrives at
one node, so the prompt has to reach the others before any of them can start,
and every rank must select the same token or they diverge into different
sequences.

The protocol uses the only primitive guaranteed to exist: a collective.
`all_sum` with zeros on non-root ranks is a broadcast, and it doubles as the
barrier that keeps ranks aligned. Non-root ranks block inside it, so a rank
waiting is exactly a rank ready to serve, with no polling loop and no second
channel to keep alive.

    control = all_sum([flag, prompt_len, max_tokens, seed])
    tokens  = all_sum(padded prompt)

The seed is broadcast rather than fixed. Logits are all-reduced so every rank
sees the same distribution, but each draws from it locally; without a shared
seed the ranks would diverge after the first sampled token.

Requests serialise on rank 0. The pool is one model, so concurrency would mean
interleaving two lockstep sequences across the same ranks.

### Admission measures rather than projects

With `--min-tok-s`, the server runs one real completion at startup and refuses
to serve below the floor. It does not use the comm-only ceiling, which proved
2.7x optimistic: 31.72 predicted against 11.69 delivered. A pool that cannot
clear the bar should say so before it is advertised, not after.

## Next

Re-run over Thunderbolt. The prediction to test is that an 80-layer model moves
from ~3.7 tok/s to roughly 20-25 tok/s, which would make it the first
configuration where the cluster tier is genuinely usable.
