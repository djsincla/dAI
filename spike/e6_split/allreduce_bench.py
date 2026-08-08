#!/usr/bin/env python3
"""
E6 — what does splitting a model across this fleet actually cost?

Measures the fundamental quantity rather than the end result: the latency of a
single all-reduce between two nodes. Everything about tensor-parallel inference
follows from it.

Why all-reduce specifically. mlx-lm's Qwen2 implements `shard(group)`, which is
*tensor* parallelism — attention and MLP projections are split across nodes and
recombined with an all-reduce after each block. A 28-layer model therefore pays
roughly 2 all-reduces per layer per token, or ~56 network round-trips for every
single token generated. Pipeline parallelism would pay 1 per hop per token; the
plan's cluster tier assumes that cheaper shape and a Thunderbolt interconnect.

So the token-rate ceiling is:

    tokens/s <= 1 / (all_reduce_latency * 2 * n_layers)

That bound is independent of how fast the GPUs are. If it lands below what a
single machine already achieves, splitting is strictly worse than not splitting,
and the cluster tier does not belong on this interconnect.

Tensor sizes match real activations: hidden_size 3584 for Qwen2.5-7B, batch 1,
fp16 — the actual payload crossing the wire per all-reduce during generation.

    mlx.launch --backend ring --hostfile hosts.json allreduce_bench.py
"""

import json
import time

import mlx.core as mx

# Qwen2.5-7B geometry. Payload per all-reduce during single-token generation is
# tiny (one row of hidden state), so this measures latency, not bandwidth —
# which is the point. Tensor parallelism is a latency problem.
HIDDEN = 3584
LAYERS = 28
ALLREDUCE_PER_LAYER = 2  # one after attention, one after MLP

SIZES = [
    ("1 token  (generation)", (1, HIDDEN)),
    ("32 tokens (prefill)", (32, HIDDEN)),
    ("512 tokens (prefill)", (512, HIDDEN)),
]
WARMUP, ITERS = 10, 60


def main():
    group = mx.distributed.init(backend="ring")
    rank, size = group.rank(), group.size()

    if size < 2:
        if rank == 0:
            print(json.dumps({"error": "only one node in the group; "
                                       "launch with a hostfile listing both"}))
        return 1

    results = {}
    for label, shape in SIZES:
        x = mx.random.normal(shape, dtype=mx.float16)
        mx.eval(x)

        for _ in range(WARMUP):
            mx.eval(mx.distributed.all_sum(x, group=group))

        # Barrier before timing so a slow node's warmup does not land inside
        # the measured window.
        mx.eval(mx.distributed.all_sum(mx.zeros((1,)), group=group))

        t0 = time.perf_counter()
        for _ in range(ITERS):
            mx.eval(mx.distributed.all_sum(x, group=group))
        elapsed = (time.perf_counter() - t0) / ITERS

        results[label] = {
            "shape": list(shape),
            "bytes": shape[0] * shape[1] * 2,
            "latency_ms": round(elapsed * 1000, 3),
        }

    if rank == 0:
        gen = results["1 token  (generation)"]["latency_ms"] / 1000
        ceiling = 1.0 / (gen * ALLREDUCE_PER_LAYER * LAYERS)
        payload = {
            "nodes": size,
            "model_geometry": {"hidden": HIDDEN, "layers": LAYERS,
                               "allreduce_per_layer": ALLREDUCE_PER_LAYER},
            "allreduce": results,
            "comm_only_token_ceiling_tok_s": round(ceiling, 2),
        }
        print("E6_RESULT " + json.dumps(payload), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
