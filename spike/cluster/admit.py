#!/usr/bin/env python3
"""
Cluster-tier admission control - verify a pool before serving on it.

The cluster tier exists for one reason: running a model no single node can hold.
E6 measured the cost of that - 11.69 tok/s sharded across two nodes against
77.46 tok/s for the same model on one - so splitting is never a speed decision
and a pool should be refused rather than silently deliver something unusable.

Two properties are checked, both of which E6 showed decide viability:

  interconnect  Tensor parallelism all-reduces after every attention and MLP
                block, so a 28-layer model pays ~56 round-trips per token. The
                same code swung 30x between WiFi (16.687 ms all-reduce) and
                gigabit (0.563 ms). Latency, not bandwidth, is the binding
                constraint at generation time.

  capacity      shard() splits resident weights but every rank still transiently
                holds ~1.27x its slice during load, so the largest loadable
                model is roughly N x smallest_node / 1.27. A pool that cannot
                hold the target model is useless no matter how fast its wire is.

Projected throughput deliberately applies an empirical correction. The
comm-only ceiling from all-reduce latency alone predicted 31.72 tok/s where
reality delivered 11.69 - a tight benchmark loop pays neither synchronisation
nor per-op overhead. Admission uses the measured 0.37 realisation factor rather
than the raw ceiling, because promising a number 2.7x above what the pool will
actually serve is worse than refusing it.

    mlx.launch-style: MLX_HOSTFILE=hosts.json MLX_RANK=n python admit.py \\
        --model-gb 40 --layers 80 --hidden 8192 --min-tok-s 8
"""

import argparse
import json
import time

import mlx.core as mx

# Fraction of the comm-only ceiling that materialised end to end on gigabit
# (11.69 / 31.72). Derived from one interconnect and one model; re-measure when
# either changes materially.
CEILING_REALISATION = 0.37

# Transient multiple of slice size each rank holds during a lazy sharded load.
LOAD_OVERHEAD = 1.27

WARMUP, ITERS = 10, 60


def measure_allreduce(group, hidden):
    """Latency of the all-reduce a single generated token pays, per layer."""
    x = mx.random.normal((1, hidden), dtype=mx.float16)
    mx.eval(x)
    for _ in range(WARMUP):
        mx.eval(mx.distributed.all_sum(x, group=group))
    mx.eval(mx.distributed.all_sum(mx.zeros((1,)), group=group))  # barrier

    t0 = time.perf_counter()
    for _ in range(ITERS):
        mx.eval(mx.distributed.all_sum(x, group=group))
    return (time.perf_counter() - t0) / ITERS


def node_memory_gb():
    """Metal's own working-set cap, which sits well below installed RAM (~81%
    on an M2 Max). Sizing against installed memory would overcommit."""
    info = mx.device_info()
    return int(info["max_recommended_working_set_size"]) / (1 << 30)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model-gb", type=float, required=True,
                    help="on-disk size of the target model")
    ap.add_argument("--layers", type=int, required=True)
    ap.add_argument("--hidden", type=int, required=True)
    ap.add_argument("--min-tok-s", type=float, default=8.0,
                    help="refuse the pool below this projected throughput")
    ap.add_argument("--allreduce-per-layer", type=int, default=2)
    ap.add_argument("--out")
    args = ap.parse_args()

    group = mx.distributed.init(backend="ring")
    rank, size = group.rank(), group.size()
    if size < 2:
        if rank == 0:
            print(json.dumps({"admitted": False,
                              "reason": "pool has one node; nothing to shard"}))
        return 1

    latency_s = measure_allreduce(group, args.hidden)

    # Every rank reports its own ceiling; the smallest node bounds the pool.
    local_gb = node_memory_gb()
    gathered = mx.distributed.all_gather(
        mx.array([local_gb], dtype=mx.float32), group=group)
    mx.eval(gathered)
    per_node = [float(v) for v in gathered.tolist()]
    smallest = min(per_node)

    ceiling = 1.0 / (latency_s * args.allreduce_per_layer * args.layers)
    projected = ceiling * CEILING_REALISATION
    capacity_gb = size * smallest / LOAD_OVERHEAD

    reasons = []
    if projected < args.min_tok_s:
        reasons.append(
            f"projected {projected:.1f} tok/s is below the {args.min_tok_s:.1f} "
            f"floor (all-reduce {latency_s*1000:.3f} ms x {args.allreduce_per_layer} "
            f"x {args.layers} layers)")
    if args.model_gb > capacity_gb:
        reasons.append(
            f"model needs {args.model_gb:.1f} GB but the pool can load "
            f"{capacity_gb:.1f} GB ({size} nodes x {smallest:.1f} GB smallest "
            f"/ {LOAD_OVERHEAD} load overhead)")
    # The tier only earns its cost when the model does not fit on one node.
    if args.model_gb <= smallest / LOAD_OVERHEAD:
        reasons.append(
            f"model fits on a single node ({smallest:.1f} GB available); "
            f"sharding would cost ~6.6x throughput for no benefit")

    payload = {
        "admitted": not reasons,
        "reasons": reasons,
        "nodes": size,
        "allreduce_ms": round(latency_s * 1000, 4),
        "comm_only_ceiling_tok_s": round(ceiling, 2),
        "projected_tok_s": round(projected, 2),
        "per_node_working_set_gb": [round(v, 1) for v in per_node],
        "pool_capacity_gb": round(capacity_gb, 1),
        "model_gb": args.model_gb,
    }

    if rank == 0:
        print("ADMIT_RESULT " + json.dumps(payload), flush=True)
        if args.out:
            with open(args.out, "w") as f:
                json.dump(payload, f, indent=2)
    return 0 if payload["admitted"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
