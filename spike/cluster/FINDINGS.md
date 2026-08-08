# Cluster tier — admission control

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
layer per token — 160 round-trips per token against a 7B's 56.

Solving for the largest model depth that clears an 8 tok/s floor:

| Interconnect | All-reduce | Max layers |
|---|---|---|
| WiFi | 16.687 ms | ~1 |
| Gigabit Ethernet | 0.61 ms | **~38** |
| Thunderbolt 4 (est. 0.1 ms) | ~0.1 ms | ~230 |

**A 70B has 80 layers; a 110B has ~88.** At gigabit only 7B-13B class models
clear the floor — and those fit on a single node, so they should never be
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

`orca` vanished twice during this work — once asleep, once from a flat battery —
and a gang-scheduled job dies when any member goes.

**These are deliberately not enforced at admission for now.** On laptops in
active use, requiring AC power and disabled sleep would make the tier unusable,
and this is a development fleet. Recorded as a production consideration:

- **AC power**, with battery state health-checked before a job is scheduled
- **Sleep disabled** (`caffeinate -dimsu` or `pmset` policy)
- Health checks that fail a pool *before* work is dispatched onto it, not after

Not enforcing them creates an obligation instead: the gang scheduler must handle
node loss cleanly — detect the member going away, fail the job with a specific
reason rather than hanging, release the pool, and requeue rather than strand.
`caffeinate -dimsu -t <seconds>` remains available as an opt-in for a specific
run without making it a standing rule.

The harvest tier already handles the power case through its on-battery policy
gate. Notably, the node that drained its battery was running the older
`e3_fleet/worker.py`, which has no presence logic at all — the tier with the
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

## Next

Re-run over Thunderbolt. The prediction to test is that an 80-layer model moves
from ~3.7 tok/s to roughly 20-25 tok/s, which would make it the first
configuration where the cluster tier is genuinely usable.
