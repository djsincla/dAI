# E6 - Splitting a model across the pool

**Fleet:** `rotorua` M2 Max / 64 GB · `orca` M4 Pro / 48 GB, both MLX 0.32.0
**Interconnects tested:** WiFi 192.168.4.0/22 (~27 ms RTT) and USB gigabit
Ethernet 10.0.0.0/24 (~0.48 ms RTT). Thunderbolt attempted, no link established.
**Method:** measured all-reduce latency via MLX ring backend, 60 iterations after warmup

> **Superseded in part - see `spike/e7_thunderbolt/FINDINGS.md`.**
>
> Thunderbolt later came up and was measured at **0.85 ms RTT / 324 MB/s**. Two
> things below need reading with that in mind.
>
> Thunderbolt is *higher* latency than the gigabit adapter used here, not lower.
> This file's conclusion that the cluster tier does not require Thunderbolt
> therefore holds, and for a stronger reason than it was given: Thunderbolt
> would have made the all-reduce measured here slower, not faster.
>
> Everything below measures **tensor** parallelism, which pays two all-reduces
> per layer per token. E7 measures **pipeline** parallelism, which pays one
> crossing per token whatever the depth, and splits an 80-layer 72B at a 13.2%
> cost. Where this file says model depth is the binding constraint, that is a
> property of the technique rather than of the fleet.

## Result: the interconnect decides everything

Measured on two interconnects between the same two machines, same code:

| Payload | Size | WiFi (27 ms RTT) | GbE (0.48 ms RTT) | Improvement |
|---|---|---|---|---|
| 1 token (generation) | 7 KB | 16.687 ms | **0.563 ms** | **30x** |
| 32 tokens (prefill) | 224 KB | 239.6 ms | 2.198 ms | 109x |
| 512 tokens (prefill) | 3.6 MB | 3104.6 ms | 31.665 ms | 98x |
| **comm-only token ceiling** | | **1.07 tok/s** | **31.72 tok/s** | **30x** |

The GbE link is a USB gigabit Ethernet adapter (AX88179A, `1000baseT
full-duplex`) on a private 10.0.0.0/24 - **not** Thunderbolt, which showed no
device connected on either machine at the time of this run. It came up later and
is measured in E7: 0.85 ms RTT, which is *slower* than this adapter.

Two regimes are visible in the GbE column:

- **Generation is latency-bound and near wire speed.** 0.563 ms per all-reduce
  against a 0.48 ms ping means MLX's ring backend adds almost no overhead. That
  cost is physics, not software, and only a lower-latency link improves it.
- **Prefill is bandwidth-bound.** 3.6 MB in 31.665 ms is 116 MB/s, roughly 928
  Mbps - saturating the gigabit link. Only a wider link improves it.

They respond to different upgrades, which matters when choosing an interconnect.

## End-to-end: sharding is a memory technique, not a speed technique

The ceiling above counts only network time. Measured for real, Qwen2.5-7B-4bit,
128 tokens, greedy, median of 3:

| | Single (rotorua) | Sharded (2 nodes, GbE) |
|---|---|---|
| Steady throughput | **77.46 tok/s** | **11.69 tok/s** |
| Resident per node | 3.99 GB | **2.28 GB** |
| Time to first token | 0.19 s | 0.62 s |
| Load | 0.65 s | 0.83 s |

**Sharding costs 6.6x throughput to save 43% of per-node memory.** That is the
whole trade, and it means splitting is never worth doing for speed - only to fit
a model that otherwise would not.

### The 31.72 tok/s ceiling was 2.7x optimistic

Only 11.69 of the predicted 31.72 tok/s materialised - 37%. The microbenchmark
overestimated because a tight all-reduce loop enjoys warm connections and no
synchronisation stalls, while a real forward pass pays both.

Accounting per token: 85.5 ms actual, against ~31.5 ms of raw all-reduce latency
(56 x 0.563 ms) plus roughly 6.5 ms of split compute. Some 47 ms is unaccounted
for - synchronisation and per-op overhead that the microbenchmark's steady-state
loop never exposes.

**Lesson: a latency microbenchmark bounds a distributed system, it does not
predict it.** Treat any such ceiling as optimistic by a factor of two or more
until an end-to-end run confirms it. This is the same failure mode as the E2/E5
measurement traps - the error runs in the flattering direction.

### The verdict changed with the wire

On WiFi, splitting ran at **1.4%** of single-machine speed - never worth doing.
On gigabit Ethernet the ceiling is **31.72 tok/s against 77.5 tok/s** for the
same model on rotorua alone: still slower, but the same order of magnitude
rather than two off.

**This is the important product finding: the cluster tier does not require
Thunderbolt.** A commodity USB Ethernet adapter reaches a usable regime, which is
far more deployable across a studio than Thunderbolt's requirement that machines
sit physically adjacent.

### The arithmetic

mlx-lm's Qwen2 implements `shard(group)` - **tensor** parallelism, not pipeline
parallelism. Attention and MLP projections are split and recombined with an
all-reduce after each block, so a 28-layer model pays ~2 all-reduces per layer
per token: **56 network round-trips for every token generated.**

    WiFi: ceiling = 1 / (16.687ms x 2 x 28) =  1.07 tokens/s
    GbE:  ceiling = 1 / (0.563ms  x 2 x 28) = 31.72 tokens/s

Against **77.5 tok/s for the same model on rotorua alone** (E4). Both ceilings
assume infinitely fast GPUs, because they count only network time - real
throughput is lower.

Tensor parallelism is a latency problem, and a 7 KB payload costing 16.7 ms on
WiFi is pure latency. That is the wrong kind of budget for it; 0.563 ms is not.

## The tier separation holds, but the boundary moved

Same two machines, two workload shapes, across both interconnects:

| | Round-trips | WiFi | GbE |
|---|---|---|---|
| **E3** batch fan-out (independent units) | 1 per ~1.5 s unit | **0.95 efficiency** | not needed |
| **E6** tensor-parallel (split model) | 56 per token | **1.4% of one machine** | **41% of one machine** |

The harvest tier is **interconnect-insensitive** - it reached 0.95 scaling
efficiency over 27 ms WiFi, because a round-trip per 1.5 s unit is nothing. The
cluster tier is **interconnect-defined**: identical code swings 30x on the wire
alone.

That is still a genuine separation, but not the one originally argued. The claim
was that the cluster tier needs Thunderbolt and therefore physical adjacency. It
does not - it needs a *dedicated low-latency link*, and commodity gigabit
Ethernet clears the bar. A studio can rack cluster-tier nodes on an ordinary
switch rather than daisy-chaining them.

## Thunderbolt is still not connected

Both machines report `Status: No device connected` on **every** Thunderbolt port,
and `bridge0` is `status: inactive` with no IP on either side. There is no
Thunderbolt link.

Port speeds, once linked: rotorua negotiates **up to 40 Gb/s** (TB4), orca **up
to 120 Gb/s** (TB5). The link would run at 40 Gb/s, the lower of the two.

The most likely cause is a **USB-C charge-only cable**, which is physically
identical but carries no Thunderbolt data. A Thunderbolt-certified cable is
required (marked with the ⚡ symbol or TB3/TB4/TB5).

The GbE result already delivered the predicted sub-millisecond all-reduce, so
Thunderbolt is now an optimisation rather than a prerequisite. Extrapolating from
the GbE numbers, TB4 at 40 Gb/s would relieve the prefill bandwidth bound
entirely and, if latency fell to ~0.1 ms, lift the generation ceiling past
single-machine throughput - the point at which splitting stops being a
compromise. Worth measuring, no longer worth blocking on.

## What would make splitting worth it anyway

Even on a fast interconnect, splitting is only justified when a model does not
fit on one machine. On this fleet that threshold is high: rotorua's 64 GB holds
a 70B at 4-bit (~40 GB) unassisted. Splitting would only be needed above roughly
100B at 4-bit, or a 70B at 8-bit.

So the cluster tier's real question is not "can we split" but "**is there a model
we need that does not fit on the biggest single box**". If not, the correct
architecture is one large machine, not several linked ones - which is exactly
the check the plan flagged before committing to Phase 2.

The measured trade sharpens this. Sharding a 7B across two nodes yields 11.69
tok/s where one node alone yields 77.46. Nobody should accept a 6.6x slowdown
for a model that fits. The only defensible use is a model that does not, and even
then the comparison is against buying one larger machine - an M3 Ultra with
512 GB holds anything this fleet could assemble, at full single-node speed.

### `lazy=True` is mandatory, and it is not the default

Peak memory during load decides whether sharding can hold an oversized model at
all. Measured per rank, 7B-4bit across two nodes:

| Load mode | Peak per rank | Resident | Full model |
|---|---|---|---|
| `lazy=False` (eager) | **5.01 GB** | 2.28 GB | 3.99 GB |
| `lazy=True` | **2.90 GB** | 2.28 GB | 3.99 GB |

Eager peaks *above* the full model, because each rank briefly holds full weights
and the sharded copy at once. Lazy peaks well below it, materialising only this
rank's slice.

**So a fleet CAN hold a model no single node could load - but only lazily.** With
eager loading the fleet would OOM on precisely the model the second machine was
bought for, and `lazy=False` is the more obvious thing to write.

Capacity follows from the ~1.27x transient overhead above slice size. For N nodes
whose smallest has M_min memory, the largest loadable model is roughly
`N x M_min / 1.27`. For this pair (48 GB smallest) that is ~75 GB - a 70B at
8-bit, or roughly a 130B at 4-bit. Neither machine could load either alone.

## Measurement notes

Two macOS-specific traps cost time here and will recur:

- **Port 5000 is macOS AirPlay Receiver.** MLX's ring backend defaults to
  `--starting-port 5000`, so ranks connect to AirPlay instead of each other and
  hang with no error. Use a high port (9100+). This looked exactly like a
  firewall block; it was not - connectivity tested fine.
- **`MLX_HOSTFILE` at runtime is not the `mlx.launch` schema.** `mlx.launch`
  takes `[{"ssh": host, "ips": [...]}]`, but the runtime variable takes a list
  of lists of endpoints: `[["ip:port"], ["ip:port"]]`. Passing the launch schema
  raises `type must be string, but is array`.

Launching ranks directly with `MLX_HOSTFILE` and `MLX_RANK` avoids `mlx.launch`'s
requirement that the coordinating node be able to SSH to itself.

## Reproducing

```bash
# One endpoint list per rank, ports well clear of 5000.
# Use the dedicated link's addresses, not the WiFi ones - that swing is 30x.
echo '[["10.0.0.2:9100"], ["10.0.0.1:9101"]]' > hosts_gbe.json

# rank 1 first so it is listening
ssh orca.local 'cd ~/e6 && MLX_HOSTFILE=hosts_gbe.json MLX_RANK=1 python allreduce_bench.py &'
MLX_HOSTFILE=hosts_gbe.json MLX_RANK=0 python allreduce_bench.py
```
