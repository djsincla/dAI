# E7 - Thunderbolt, and splitting a model that fits on neither machine

**Fleet:** `rotorua` M2 Max / 64 GB · `orca` M4 Pro / 48 GB
**Runtime:** MLX 0.29.3 / mlx-lm 0.29.1
**Link:** Thunderbolt bridge, 192.168.99.1 / 192.168.99.2
**Method:** *pipeline* parallelism - layers divided, one hidden state crossing
the boundary per token. Not the tensor parallelism E6 measured.

A shareable write-up of these results, with charts, is published at
<https://claude.ai/code/artifact/3d82fdae-7551-491f-b16a-c77fe580608c>.

## The link finally came up, and it is not what E6 assumed

E6 recorded "Thunderbolt attempted, no link established" and the cluster spike
projected Thunderbolt at ~0.1 ms all-reduce on that basis. Both are now
superseded by measurement.

| Link | Round trip | Throughput |
|---|---|---|
| WiFi | ~70 ms | 13 MB/s |
| USB gigabit Ethernet (E6) | 0.48 ms | 116 MB/s |
| **Thunderbolt bridge** | **0.85 ms** | **324 MB/s** |

RTT is 20 ICMP samples. The 324 MB/s figure is a **floor, not a ceiling** - it
came from a verified 2.1 GB encrypted transfer, so the cipher was the bottleneck
rather than the cable.

### The surprise: Thunderbolt is wider, not quicker

**Thunderbolt's round trip is 1.8x *worse* than the USB gigabit adapter's**
(0.85 ms against 0.48 ms), while its bandwidth is 2.8x better. The cluster
spike's estimate of ~0.1 ms was optimistic by roughly 8.5x, and in the direction
that matters.

That is worth holding onto, because it inverts the intuition the name invites.
Thunderbolt is a bandwidth upgrade. For anything latency-bound it is not an
upgrade at all over a commodity Ethernet adapter.

Which technique you are using therefore decides whether the cable helps:

- **Pipeline parallelism** sends one hidden state per token - a few kilobytes,
  once. It is insensitive to both, and everything below works over either link.
- **Tensor parallelism** pays ~2 all-reduces per layer per token. It is
  latency-bound, so Thunderbolt would make it *slower* than gigabit.

See "What this corrects" below.

## Memory divides almost exactly, which is the whole point

Three models, each run alone and then split, identical prompt.

| Model | Configuration | Throughput | Per token | Peak memory |
|---|---|---|---|---|
| 16B MoE (DeepSeek-Coder-V2-Lite) | one machine | 113.9 tok/s | 8.78 ms | 9.11 GB |
| | split | 68.4 tok/s | 14.62 ms | **4.68 + 4.40 GB** |
| 32B dense (Qwen2.5-Coder) | one machine | 16.5 tok/s | 60.5 ms | 18.64 GB |
| | split | 14.2 tok/s | 70.6 ms | **9.83 GB each** |
| 72B dense (Qwen2.5) | one machine | 7.3 tok/s | 137.7 ms | 41.10 GB |
| | split | 6.3 tok/s | 158.7 ms | **21.31 GB each** |

Repeat runs at two generation lengths agreed within 1%. The 72B was measured at
60 generated tokens, the others at 120 to 500.

**The 72B is the result that matters.** At 41.10 GB it exceeds orca's 37.4 GB
Metal working set outright, so it cannot run there at any speed. Split, it runs
on both at 6.3 tok/s. Splitting is not a way to run it faster; it is the only
way to run it.

Time to first token *improved* in every case - 9.1 s to 4.9 s on the 72B -
because reading the prompt parallelises across both machines.

## The cost holds at 13-14% for dense models

| Model | Own work per token | Added by splitting | Cost |
|---|---|---|---|
| 16B MoE | 8.8 ms | 5.8 ms | **40%** |
| 32B dense | 60.5 ms | 10.1 ms | 14.3% |
| 72B dense | 137.7 ms | 21.0 ms | 13.2% |

The mixture-of-experts model is the outlier because it activates a fraction of
its weights per token: it is very fast for its size, so a fixed crossing cost
lands on a very short step and hurts.

### The per-token toll scales with the model, and we predicted otherwise

An earlier draft projected ~8% for a 70B by extrapolating from the smaller
models on the assumption that the overhead was fixed. Measured, it is 13.2%.

The middle column roughly **doubles as the model doubles** - 5.8, 10.1, 21.0 ms.
Splitting does not become free as models grow. The percentage stays flat only
because the model's own work grows at a similar rate.

Note also that 5.8 ms of added cost sits against a 0.85 ms round trip. **Wire
time is a minority of the toll.** The rest is serialisation, a synchronisation
barrier, and per-step overhead across two processes - which is why a faster
cable would not recover most of it.

## What this corrects

**E6:** "Thunderbolt attempted, no link established", and the conclusion that
the cluster tier does not require Thunderbolt. The link works. The conclusion
survives but for a better reason than it was given: E6 was right that a
commodity Ethernet adapter reaches a usable regime, and we can now add that
Thunderbolt would not have helped the technique E6 measured, because it is the
higher-latency link of the two.

**cluster/FINDINGS.md:** the row `Thunderbolt 4 (est. 0.1 ms) | ~230 layers` is
an estimate that measurement does not support. At 0.85 ms the Thunderbolt row
belongs *below* the gigabit row, not above it. The max-layers column should be
re-derived rather than patched, since it was built on the estimate.

**The deeper correction is about technique, not cable.** E6 and the cluster
spike both measured tensor parallelism and concluded that model depth was the
binding constraint, because that technique pays two all-reduces per layer per
token. Pipeline parallelism pays one crossing per *token* regardless of depth.
The 72B has 80 layers - the depth that made tensor parallelism hopeless - and it
splits at a 13.2% cost. The constraint was the technique.

## What this does not show

- **Two ranks only.** Whether the per-token toll stays flat or grows with each
  additional hop is unmeasured.
- **Prototype, not product.** This ran on stock mlx-lm with a small local
  modification. The Swift implementation in `agent/` came later and is measured
  separately; see `docs/SPLIT_MODEL_ERRORS.md`.
- **No failure story.** Nothing was tested for one half of the pair
  disappearing mid-token, which is the first thing that will happen in real use.
- **Gigabit was not re-tested with pipeline parallelism.** Given the toll is
  mostly not wire time, a pipeline split over the USB gigabit adapter would
  probably land close to these numbers - but that is a prediction, and this file
  exists because the last prediction was wrong by 5 points.
