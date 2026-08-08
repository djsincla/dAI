#!/usr/bin/env python3
"""
E4 — What does preemption cost, and what work-unit size amortizes it?

The harvest tier yields the moment a user returns, throwing away whatever was
in flight. Two numbers decide whether that is affordable:

  L  seconds to get a model resident and generating
  D  seconds of useful work per unit

Load is pure overhead paid again after every preemption, so overhead fraction is
L/(L+D). Holding that under a target t requires D >= L*(1-t)/t — at t=10%,
D >= 9L. That single inequality sizes the work-unit protocol, which is why E4
blocks Phase 1.

Measured per model:
  - warm load (page cache hot) and an estimated cold load
  - resident unified memory once loaded
  - time to first token, and steady-state generation throughput
  - release time when yielding in-process

Two traps this avoids:

  lazy=False is mandatory. mlx_lm.load defaults to eager but accepts lazy=True,
  which defers weight materialization to first use and would report a load time
  a fraction of the real one.

  Warm != cold. After downloading, weights sit in the page cache, so a measured
  load is the best case. A genuinely cold load needs `sudo purge`, so instead
  disk read bandwidth is measured once and cold load is reported as an estimate.
  The agent's real-world reload after a long idle period is the cold number.
"""

import argparse
import fcntl
import gc
import json
import os
import pathlib
import statistics
import subprocess
import time

import mlx.core as mx

F_NOCACHE = getattr(fcntl, "F_NOCACHE", 48)  # macOS: bypass the page cache

DEFAULT_MODELS = [
    "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
    "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/Qwen2.5-14B-Instruct-4bit",
]

PROMPT = "Summarize the causes of the 1973 oil crisis in three sentences."
GEN_TOKENS = 96
OVERHEAD_TARGETS = [0.05, 0.10, 0.20]


def time_uncached_read(path):
    """Seconds to read a model's weight files straight off the device.

    This is the disk portion of a cold load, measured on the real files rather
    than inferred from a synthetic benchmark. Two earlier attempts were both
    wrong in the optimistic direction:

      Reading back a file just written returns it from the page cache (measured
      9.83 GB/s on an M2 Max, well above the NVMe's real rate).

      Adding F_NOCACHE was not enough, because the synthetic file was written as
      zeros and APFS stores those sparsely — reading it never touched the device
      at all, and the number went *up* to 15.35 GB/s.

    Reading the actual safetensors sidesteps both: real data, real file layout,
    real sizes. A warm load is essentially parse and allocate with no disk time,
    so cold load is approximately warm load plus this.
    """
    chunk_size = 8 << 20
    total_bytes = 0
    elapsed = 0.0
    for entry in sorted(pathlib.Path(path).glob("*.safetensors")):
        real = entry.resolve()  # HF snapshots symlink into the blobs store
        with open(real, "rb") as f:
            fcntl.fcntl(f.fileno(), F_NOCACHE, 1)
            t0 = time.perf_counter()
            while True:
                block = f.read(chunk_size)
                if not block:
                    break
                total_bytes += len(block)
            elapsed += time.perf_counter() - t0
    if not total_bytes:
        return None, None
    return elapsed, total_bytes / elapsed / (1 << 30)


def snapshot_size_gb(repo):
    from huggingface_hub import snapshot_download
    path = snapshot_download(repo)
    out = subprocess.run(["du", "-skL", path], capture_output=True, text=True)
    try:
        return int(out.stdout.split()[0]) / (1 << 20), path
    except (ValueError, IndexError):
        return None, path


def time_load(repo):
    from mlx_lm import load
    mx.clear_cache()
    mx.reset_peak_memory()
    before = mx.get_active_memory()
    t0 = time.perf_counter()
    # lazy=False forces materialization now; lazy=True would defer it to first
    # use and report a load time that is not the one the agent actually pays.
    model, tokenizer = load(repo, lazy=False)
    mx.eval(model.parameters())
    elapsed = time.perf_counter() - t0
    resident = mx.get_active_memory() - before
    return model, tokenizer, elapsed, resident


def time_release(model, tokenizer):
    """In-process yield. The agent's other option is killing the process, where
    the kernel reclaims immediately — this measures the cheaper-to-restart path
    of keeping the worker alive."""
    before = mx.get_active_memory()
    t0 = time.perf_counter()
    del model, tokenizer
    gc.collect()
    mx.clear_cache()
    elapsed = time.perf_counter() - t0
    return elapsed, before - mx.get_active_memory()


def measure_generation(model, tokenizer):
    from mlx_lm import stream_generate
    t0 = time.perf_counter()
    ttft = None
    tokens = 0
    for response in stream_generate(model, tokenizer, PROMPT, max_tokens=GEN_TOKENS):
        if ttft is None:
            ttft = time.perf_counter() - t0
        tokens += 1
    total = time.perf_counter() - t0
    steady = (tokens - 1) / (total - ttft) if ttft and total > ttft else None
    return {
        "ttft_s": round(ttft, 3) if ttft else None,
        "tokens": tokens,
        "total_s": round(total, 3),
        "steady_tok_s": round(steady, 1) if steady else None,
    }


def measure_model(repo, warm_reps):
    size_gb, path = snapshot_size_gb(repo)
    record = {"repo": repo, "disk_gb": round(size_gb, 2) if size_gb else None}

    disk_s, disk_gbs = time_uncached_read(path)
    record["disk_read_s"] = round(disk_s, 3) if disk_s else None
    record["disk_read_gb_s"] = round(disk_gbs, 2) if disk_gbs else None

    loads = []
    for i in range(warm_reps):
        model, tokenizer, elapsed, resident = time_load(repo)
        loads.append(elapsed)
        if i == 0:
            record["resident_gb"] = round(resident / (1 << 30), 2)
            record["generation"] = measure_generation(model, tokenizer)
        release_s, freed = time_release(model, tokenizer)
        if i == 0:
            record["release_s"] = round(release_s, 3)
            record["released_gb"] = round(freed / (1 << 30), 2)

    record["load_warm_s"] = round(statistics.median(loads), 3)
    record["load_warm_all"] = [round(x, 3) for x in loads]

    # Cold load pays the device read on top of the parse/allocate work that the
    # warm number already contains.
    if disk_s:
        record["load_cold_est_s"] = round(record["load_warm_s"] + disk_s, 2)
    return record


def derive_work_units(record):
    """D >= L*(1-t)/t for a target overhead fraction t."""
    out = {}
    for basis in ("load_warm_s", "load_cold_est_s"):
        L = record.get(basis)
        if not L:
            continue
        out[basis] = {
            f"overhead_{int(t * 100)}pct_min_unit_s": round(L * (1 - t) / t, 1)
            for t in OVERHEAD_TARGETS
        }
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", nargs="*", default=DEFAULT_MODELS)
    ap.add_argument("--reps", type=int, default=3, help="warm load repetitions")
    ap.add_argument("--out", default="results.json")
    args = ap.parse_args()

    results = []
    for repo in args.models:
        print(f"--- {repo}")
        try:
            record = measure_model(repo, args.reps)
            record["work_units"] = derive_work_units(record)
            results.append(record)
            g = record.get("generation", {})
            print(f"    disk {record.get('disk_gb')} GB | resident {record.get('resident_gb')} GB")
            print(f"    load warm {record['load_warm_s']}s"
                  f" | cold est {record.get('load_cold_est_s')}s"
                  f" | release {record.get('release_s')}s")
            print(f"    ttft {g.get('ttft_s')}s | {g.get('steady_tok_s')} tok/s")
        except Exception as exc:
            print(f"    FAILED: {exc!r}")
            results.append({"repo": repo, "error": repr(exc)})

    payload = {"gen_tokens": GEN_TOKENS, "results": results}
    with open(args.out, "w") as f:
        json.dump(payload, f, indent=2)

    ok = [r for r in results if "load_warm_s" in r]
    if ok:
        print(f"\n{'model':<44} {'resident':>9} {'warm':>7} {'cold~':>7} "
              f"{'tok/s':>7} {'unit@10%':>9}")
        print("-" * 88)
        for r in ok:
            unit = r["work_units"].get("load_cold_est_s", {}).get(
                "overhead_10pct_min_unit_s", "-")
            print(f"{r['repo'].split('/')[-1]:<44} {r.get('resident_gb','-'):>9} "
                  f"{r['load_warm_s']:>7} {r.get('load_cold_est_s','-'):>7} "
                  f"{r.get('generation',{}).get('steady_tok_s','-'):>7} {unit:>9}")
        print("\nunit@10% = minimum work-unit seconds to keep model-load overhead")
        print("under 10%, based on the cold-load estimate. Shorter units lose less")
        print("work per preemption but pay reload more often; this is the floor.")
    print(f"\nWrote {args.out}")


if __name__ == "__main__":
    raise SystemExit(main())
