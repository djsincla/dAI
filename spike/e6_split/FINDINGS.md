# E6 — Splitting a model across the pool

**Fleet:** `rotorua` M2 Max / 64 GB · `orca` M4 Pro / 48 GB, both MLX 0.32.0
**Interconnect:** WiFi, 192.168.4.0/22, ~27 ms RTT
**Method:** measured all-reduce latency via MLX ring backend, 60 iterations after warmup

## Result: split-model inference is not viable on this interconnect

| Payload | Size | All-reduce latency |
|---|---|---|
| 1 token (generation) | 7 KB | **16.7 ms** |
| 32 tokens (prefill) | 224 KB | 239.6 ms |
| 512 tokens (prefill) | 3.6 MB | 3104.6 ms |

mlx-lm's Qwen2 implements `shard(group)` — **tensor** parallelism, not pipeline
parallelism. Attention and MLP projections are split and recombined with an
all-reduce after each block, so a 28-layer model pays ~2 all-reduces per layer
per token: **56 network round-trips for every token generated.**

    ceiling = 1 / (16.7ms x 2 x 28) = 1.07 tokens/s

Against **77.5 tok/s for the same model on rotorua alone** (E4). Splitting runs
at **1.4% of single-machine speed** — and that ceiling assumes infinitely fast
GPUs, because it counts only network time. Real throughput would be lower.

A 7 KB payload costing 16.7 ms is latency, not bandwidth. Tensor parallelism is
a latency problem, and WiFi has the wrong kind of budget for it.

## This validates the plan's tier separation empirically

The same network, the same two machines, two workload shapes:

| | Interconnect demand | Result |
|---|---|---|
| **E3** batch fan-out (independent units) | 1 round-trip per ~1.5 s unit | **0.95-0.96 scaling efficiency** |
| **E6** tensor-parallel (split model) | 56 round-trips per token | **1.4% of one machine** |

That is a ~70x swing from workload shape alone. The harvest tier and the cluster
tier are not two configurations of one system; they have incompatible network
requirements, and the plan's decision to build them as separate tiers holds.

## Thunderbolt was attempted and is not connected

Both machines report `Status: No device connected` on **every** Thunderbolt port,
and `bridge0` is `status: inactive` with no IP on either side. There is no
Thunderbolt link.

Port speeds, once linked: rotorua negotiates **up to 40 Gb/s** (TB4), orca **up
to 120 Gb/s** (TB5). The link would run at 40 Gb/s, the lower of the two.

The most likely cause is a **USB-C charge-only cable**, which is physically
identical but carries no Thunderbolt data. A Thunderbolt-certified cable is
required (marked with the ⚡ symbol or TB3/TB4/TB5).

This measurement should be repeated over Thunderbolt before the cluster tier is
judged. Sub-millisecond all-reduce would move the ceiling from ~1 tok/s to
plausibly 30-60 tok/s, which is the difference between "never" and "viable".

## What would make splitting worth it anyway

Even on a fast interconnect, splitting is only justified when a model does not
fit on one machine. On this fleet that threshold is high: rotorua's 64 GB holds
a 70B at 4-bit (~40 GB) unassisted. Splitting would only be needed above roughly
100B at 4-bit, or a 70B at 8-bit.

So the cluster tier's real question is not "can we split" but "**is there a model
we need that does not fit on the biggest single box**". If not, the correct
architecture is one large machine, not several linked ones — which is exactly
the check the plan flagged before committing to Phase 2.

## Measurement notes

Two macOS-specific traps cost time here and will recur:

- **Port 5000 is macOS AirPlay Receiver.** MLX's ring backend defaults to
  `--starting-port 5000`, so ranks connect to AirPlay instead of each other and
  hang with no error. Use a high port (9100+). This looked exactly like a
  firewall block; it was not — connectivity tested fine.
- **`MLX_HOSTFILE` at runtime is not the `mlx.launch` schema.** `mlx.launch`
  takes `[{"ssh": host, "ips": [...]}]`, but the runtime variable takes a list
  of lists of endpoints: `[["ip:port"], ["ip:port"]]`. Passing the launch schema
  raises `type must be string, but is array`.

Launching ranks directly with `MLX_HOSTFILE` and `MLX_RANK` avoids `mlx.launch`'s
requirement that the coordinating node be able to SSH to itself.

## Reproducing

```bash
# hosts.json — one endpoint list per rank, ports well clear of 5000
echo '[["192.168.4.24:9100"], ["192.168.4.26:9101"]]' > hosts.json

# rank 1 first so it is listening
ssh orca.local 'cd ~/e6 && MLX_HOSTFILE=hosts.json MLX_RANK=1 python allreduce_bench.py &'
MLX_HOSTFILE=hosts.json MLX_RANK=0 python allreduce_bench.py
```
