#!/usr/bin/env python3
"""
E2 rerun — what settings keep a harvest agent below the perception threshold?

Supersedes run_e2.py, which swept memory ceiling against an Xcode build with a
single leading baseline. Three things were wrong with that:

  Wrong instrument. An Xcode build contends for memory bandwidth; the Blender
  viewport contends for the GPU directly and sets the stricter bar, because
  people perceive frame stutter far more acutely than a build finishing late.

  Wrong axis. E5 measured a 4 GB load costing 100% of viewport p95, so memory
  footprint does not govern how much a user is disturbed. Occupancy does. This
  sweeps QoS and duty cycle, with one memory condition retained only to confirm
  memory really is the weak axis.

  Wrong baseline discipline. Viewport p95 moved 36% between runs with nothing
  loaded. Measured once at the start, that drift is silently attributed to
  whichever condition follows — it manufactured a finding in E5 that had to be
  retracted. Baselines are interleaved here and the spread becomes the noise
  floor that every result is judged against.

Output is the policy table `presence/presence.py` currently fills with guesses.

    ../.venv/bin/python run_sweep.py --frames 150
"""

import argparse
import json
import pathlib
import statistics
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).parent
BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
VIEWPORT = HERE / "blender_viewport.py"
MLX_PY = HERE.parent / ".venv" / "bin" / "python"

# Fixed at 8 GB except where noted: roughly a 14B 4-bit model, the largest thing
# a harvest agent would realistically hold on a mid-range machine.
CONDITIONS = [
    {"label": "bg-duty25",   "qos": "background", "duty": 0.25, "mem": 8},
    {"label": "bg-duty50",   "qos": "background", "duty": 0.50, "mem": 8},
    {"label": "bg-duty100",  "qos": "background", "duty": 1.00, "mem": 8},
    {"label": "std-duty25",  "qos": "standard",   "duty": 0.25, "mem": 8},
    {"label": "std-duty50",  "qos": "standard",   "duty": 0.50, "mem": 8},
    {"label": "std-duty100", "qos": "standard",   "duty": 1.00, "mem": 8},
    # Same occupancy, 4x the memory. If memory mattered this would differ from
    # std-duty100; E5 predicts it will not.
    {"label": "std-mem32",   "qos": "standard",   "duty": 1.00, "mem": 32},
]

BASELINE_EVERY = 2  # re-measure baseline after this many loaded conditions


def run_viewport(out_dir, label, frames):
    subprocess.run(
        [BLENDER, "--python", str(VIEWPORT), "--",
         "--out", str(out_dir / f"{label}.json"),
         "--frames", str(frames), "--label", label],
        capture_output=True, text=True,
    )
    path = out_dir / f"{label}.json"
    if not path.exists():
        return None
    try:
        return json.load(open(path))
    except json.JSONDecodeError:
        return None


class Load:
    """Starts load.py and blocks until memory is resident.

    Waiting for the 'loaded' event matters: starting the benchmark during
    allocation measures a transient rather than steady-state contention.
    """

    def __init__(self, cond, log_path):
        self.cond, self.log_path, self.proc = cond, log_path, None

    def __enter__(self):
        cmd = [str(MLX_PY), str(HERE / "load.py"),
               "--memory-gb", str(self.cond["mem"]),
               "--duty", str(self.cond["duty"])]
        if self.cond["qos"] == "background":
            # Same throttling launchd applies via ProcessType: Background.
            cmd = ["taskpolicy", "-b"] + cmd
        self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True)
        deadline = time.time() + 180
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("load exited before becoming resident")
            try:
                if json.loads(line).get("event") == "loaded":
                    return self
            except json.JSONDecodeError:
                continue
        raise RuntimeError("timed out waiting for load")

    def __exit__(self, *exc):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        return False


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--frames", type=int, default=150)
    ap.add_argument("--out", default=str(HERE / "sweep_results"))
    args = ap.parse_args()

    out_dir = pathlib.Path(args.out)
    out_dir.mkdir(exist_ok=True)

    baselines, results = [], []
    n_base = 0

    def take_baseline():
        nonlocal n_base
        n_base += 1
        print(f"  baseline {n_base} ...", flush=True)
        row = run_viewport(out_dir, f"baseline.{n_base}", args.frames)
        if row and "p95_ms" in row:
            baselines.append(row)
            print(f"    p95 {row['p95_ms']:.2f} ms", flush=True)

    take_baseline()
    for i, cond in enumerate(CONDITIONS, 1):
        print(f"  {cond['label']} (qos={cond['qos']} duty={cond['duty']} "
              f"mem={cond['mem']}GB) ...", flush=True)
        try:
            with Load(cond, out_dir / f"{cond['label']}.load.log"):
                row = run_viewport(out_dir, cond["label"], args.frames)
        except Exception as exc:
            print(f"    FAILED: {exc!r}", flush=True)
            continue
        if row and "p95_ms" in row:
            row.update(cond)
            results.append(row)
            print(f"    p95 {row['p95_ms']:.2f} ms", flush=True)
        if i % BASELINE_EVERY == 0:
            take_baseline()
    take_baseline()

    if len(baselines) < 2:
        sys.exit("need at least two baselines to establish a noise floor")

    base_p95 = statistics.median(b["p95_ms"] for b in baselines)
    samples = sorted(round(b["p95_ms"], 2) for b in baselines)
    noise = (max(samples) / min(samples) - 1) * 100

    print(f"\nbaseline p95 samples: {samples}")
    print(f"baseline median: {base_p95:.2f} ms")
    print(f"NOISE FLOOR: {noise:.0f}%  <- smaller effects are not measurable\n")

    print(f"{'condition':<13} {'qos':<11} {'duty':>5} {'mem':>5} {'p95':>8} "
          f"{'vs base':>9}  verdict")
    print("-" * 72)
    safe = []
    for r in sorted(results, key=lambda r: r["p95_ms"]):
        delta = (r["p95_ms"] / base_p95 - 1) * 100
        ok = delta <= noise
        if ok:
            safe.append(r)
        print(f"{r['label']:<13} {r['qos']:<11} {r['duty']:>5.2f} {r['mem']:>4}G "
              f"{r['p95_ms']:>8.2f} {delta:>8.1f}%  "
              f"{'SAFE (within noise)' if ok else 'PERCEPTIBLE'}")

    payload = {
        "baseline_median_p95_ms": round(base_p95, 2),
        "baseline_samples": samples,
        "noise_floor_pct": round(noise, 1),
        "conditions": [
            {k: r[k] for k in ("label", "qos", "duty", "mem", "p50_ms",
                               "p95_ms", "p99_ms", "mean_fps", "hitch_pct")}
            for r in results
        ],
    }
    with open(out_dir / "summary.json", "w") as f:
        json.dump(payload, f, indent=2)

    print("\nPolicy implication: the most permissive SAFE row is what a harvest")
    print("agent may run while a user is present. Anything marked PERCEPTIBLE")
    print("belongs to LOCKED/ABSENT states only.")
    if safe:
        best = max(safe, key=lambda r: r["duty"])
        print(f"\n  -> user-present ceiling: qos={best['qos']} duty={best['duty']}")
    else:
        print("\n  -> no GPU setting is safe with a user present; ANE-only "
              "(see E5) is the daytime option.")
    print(f"\nWrote {out_dir / 'summary.json'}")


if __name__ == "__main__":
    raise SystemExit(main())
