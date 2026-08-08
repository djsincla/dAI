#!/usr/bin/env python3
"""
E3 worker — pulls work units, runs MLX inference, reports throughput.

Deliberately minimal in its dependencies: MLX and mlx-lm and nothing else. This
is the piece that has to run on every harvested machine, so anything it needs is
something the fleet has to install and keep in sync. The shipping agent replaces
this with a single signed mlx-swift binary for exactly that reason.

Reports its machine identity so the coordinator can attribute throughput. The
coordinator never trusts a declared capability — it derives throughput from
completed work, because measured behaviour and spec sheets disagree on Apple
Silicon (bandwidth-bound work inverts the ranking core counts would predict).

    python3 worker.py --coordinator http://10.0.0.5:8712
"""

import argparse
import json
import platform
import subprocess
import time
import urllib.error
import urllib.request

MAX_TOKENS = 24  # short outputs: this measures fleet scaling, not generation length


def machine_label():
    """Chip and memory, for attribution in the results table."""
    try:
        out = subprocess.run(["system_profiler", "SPHardwareDataType"],
                             capture_output=True, text=True, timeout=20).stdout
        chip = next((l.split(":", 1)[1].strip() for l in out.splitlines()
                     if "Chip:" in l), "unknown")
        mem = next((l.split(":", 1)[1].strip() for l in out.splitlines()
                    if "Memory:" in l), "?")
        return f"{chip} / {mem}"
    except Exception:
        return platform.machine()


def post(url, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--coordinator", required=True)
    ap.add_argument("--model", default="mlx-community/Qwen2.5-1.5B-Instruct-4bit")
    ap.add_argument("--name", default=platform.node().split(".")[0])
    args = ap.parse_args()

    from mlx_lm import load, generate

    label = machine_label()
    print(f"worker {args.name} ({label})")
    print(f"loading {args.model} ...", flush=True)
    t0 = time.perf_counter()
    model, tokenizer = load(args.model, lazy=False)
    print(f"loaded in {time.perf_counter() - t0:.2f}s\n", flush=True)

    units = items = 0
    while True:
        try:
            with urllib.request.urlopen(
                    f"{args.coordinator}/work?worker={args.name}", timeout=60) as resp:
                work = json.load(resp)
        except urllib.error.URLError as exc:
            print(f"coordinator unreachable ({exc}); retrying in 3s", flush=True)
            time.sleep(3)
            continue

        if work.get("wait"):
            print(f"  waiting for {work['need']} more worker(s) to join...", flush=True)
            time.sleep(3)
            continue

        if work.get("done"):
            break

        batch = work["items"]
        t0 = time.perf_counter()
        for item in batch:
            messages = [{"role": "user", "content": item["prompt"]}]
            prompt = tokenizer.apply_chat_template(messages, add_generation_prompt=True)
            generate(model, tokenizer, prompt, max_tokens=MAX_TOKENS, verbose=False)
        elapsed = time.perf_counter() - t0

        post(f"{args.coordinator}/result", {
            "worker": args.name,
            "machine": label,
            "unit_id": work["unit_id"],
            "count": len(batch),
            "seconds": elapsed,
        })
        units += 1
        items += len(batch)
        print(f"  unit {units}: {len(batch)} items in {elapsed:.2f}s "
              f"({len(batch)/elapsed:.2f}/s)", flush=True)

    print(f"\ndone: {units} units, {items} items")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
