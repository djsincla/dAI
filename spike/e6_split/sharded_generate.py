#!/usr/bin/env python3
"""
E6 part 2 - end-to-end sharded generation, to test the all-reduce ceiling.

`allreduce_bench.py` derived a 31.72 tok/s ceiling over gigabit Ethernet from
communication latency alone. That number assumes infinitely fast GPUs and counts
only network time, so it is an upper bound, not a prediction. This runs the real
thing and reports how much of it survives contact with actual compute.

Two modes against the same model and prompt:

    --mode single   one machine, no distributed group
    --mode shard    tensor-parallel across the ring, via model.shard(group)

mlx-lm's Qwen2 `shard()` splits attention and MLP projections across ranks and
all-reduces after each block. Every rank loads full weights and then keeps its
slice, so peak memory during load is the whole model on every node - fine at 7B,
and worth remembering before assuming sharding lets a fleet hold a model no
single node could load.

Greedy sampling (temp 0) keeps ranks in lockstep: logits are all-reduced so every
rank sees identical values and selects the same token. Any sampling randomness
would need a shared seed or the ranks would diverge into different sequences.

    # single
    MLX_HOSTFILE= python sharded_generate.py --mode single

    # sharded, rank 1 first so it is listening
    ssh orca 'MLX_HOSTFILE=hosts_gbe.json MLX_RANK=1 python sharded_generate.py --mode shard'
    MLX_HOSTFILE=hosts_gbe.json MLX_RANK=0 python sharded_generate.py --mode shard
"""

import argparse
import json
import time

import mlx.core as mx

PROMPT = ("Explain, in about 150 words, why unified memory changes the trade-offs "
          "for running large language models on consumer hardware.")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", choices=["single", "shard"], required=True)
    ap.add_argument("--model", default="mlx-community/Qwen2.5-7B-Instruct-4bit")
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--lazy", action="store_true",
                    help="defer weight materialisation until after shard(); "
                         "determines whether peak load memory is the full model "
                         "or only this rank's slice")
    args = ap.parse_args()

    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler

    group = None
    rank, size = 0, 1
    if args.mode == "shard":
        group = mx.distributed.init(backend="ring")
        rank, size = group.rank(), group.size()
        if size < 2:
            if rank == 0:
                print(json.dumps({"error": "only one rank; check MLX_HOSTFILE"}))
            return 1

    mx.reset_peak_memory()
    t0 = time.perf_counter()
    # lazy=True defers materialisation. If shard() then only realises this
    # rank's slice, peak stays at the slice size and a fleet CAN hold a model no
    # single node could load. If peak still hits full model size, sharding is
    # useless for exactly the case it is wanted for.
    model, tokenizer = load(args.model, lazy=args.lazy)
    if group is not None:
        # Tensor-parallel: each rank keeps its slice of every projection.
        model.shard(group)
    mx.eval(model.parameters())
    load_s = time.perf_counter() - t0
    resident_gb = mx.get_active_memory() / (1 << 30)
    peak_gb = mx.get_peak_memory() / (1 << 30)

    # Greedy via an explicit sampler; stream_generate takes `sampler`, not
    # `temp`. Determinism is load-bearing under sharding: logits are all-reduced
    # so every rank must select the same token or the ranks diverge.
    sampler = make_sampler(temp=0.0)

    messages = [{"role": "user", "content": PROMPT}]
    prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)

    runs = []
    for rep in range(args.reps):
        t0 = time.perf_counter()
        ttft, tokens = None, 0
        for _ in stream_generate(model, tokenizer, prompt,
                                 max_tokens=args.max_tokens, sampler=sampler):
            if ttft is None:
                ttft = time.perf_counter() - t0
            tokens += 1
        total = time.perf_counter() - t0
        steady = (tokens - 1) / (total - ttft) if ttft and total > ttft else None
        runs.append({"rep": rep, "tokens": tokens, "ttft_s": round(ttft, 3),
                     "total_s": round(total, 3),
                     "steady_tok_s": round(steady, 2) if steady else None})

    if rank == 0:
        rates = [r["steady_tok_s"] for r in runs if r["steady_tok_s"]]
        payload = {
            "mode": args.mode,
            "nodes": size,
            "model": args.model,
            "load_s": round(load_s, 2),
            "lazy": args.lazy,
            "resident_gb_this_rank": round(resident_gb, 2),
            "peak_gb_this_rank": round(peak_gb, 2),
            "runs": runs,
            "median_steady_tok_s": round(sorted(rates)[len(rates) // 2], 2) if rates else None,
        }
        print("E6_GEN_RESULT " + json.dumps(payload), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
