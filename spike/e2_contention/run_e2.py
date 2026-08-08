#!/usr/bin/env python3
"""
E2 — At what memory ceiling and QoS does the interactive user notice?

Sweeps background MLX load across two axes and measures the cost to a clean
Xcode build:

  memory ceiling : fraction of Metal's max_recommended_working_set_size
  QoS            : background (taskpolicy -b, matching launchd ProcessType)
                   vs standard

The QoS axis exists because E1 found Background QoS costs ~2.4x GPU throughput.
That makes it a dial, not a setting: if Background is imperceptible to the
build, harvesting can run during the working day instead of overnight only,
which roughly doubles usable fleet hours.

An Xcode build is CPU and memory-bandwidth bound while MLX is GPU and
memory-bandwidth bound, so this measures *bandwidth* contention — the real
mechanism on unified memory. It does not measure GPU-vs-GPU contention; a
Blender or Resolve workload is needed for that.

  python3 gen_workload.py             # once
  python3 run_e2.py --calibrate       # check build duration is in range
  python3 run_e2.py --reps 3          # full sweep
"""

import argparse
import json
import pathlib
import shutil
import statistics
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).parent
WORKLOAD = HERE / "workload"
VENV_PY = HERE.parent / ".venv" / "bin" / "python"
DERIVED = HERE / "DerivedData"

CEILING_FRACTIONS = [0.25, 0.50, 0.75]
QOS_MODES = ["background", "standard"]


def metal_working_set_bytes():
    """Metal's own cap, which sits well below installed RAM (~81% on M2 Max).

    Ceilings are expressed against this rather than total memory because this is
    the number that actually bounds an allocation.
    """
    out = subprocess.run(
        [str(VENV_PY), "-c",
         "import mlx.core as mx; print(mx.device_info()['max_recommended_working_set_size'])"],
        capture_output=True, text=True, check=True,
    )
    return int(out.stdout.strip())


def detect_build_cmd():
    """Prefer xcodebuild for fidelity; fall back to swift build (same compiler)."""
    probe = subprocess.run(
        ["xcodebuild", "-scheme", "E2Workload", "-destination", "platform=macOS",
         "-derivedDataPath", str(DERIVED), "-showBuildSettings"],
        cwd=WORKLOAD, capture_output=True, text=True,
    )
    if probe.returncode == 0:
        return ["xcodebuild", "-scheme", "E2Workload", "-destination", "platform=macOS",
                "-derivedDataPath", str(DERIVED), "build"], "xcodebuild"
    return ["swift", "build", "-c", "debug"], "swift build"


def clean():
    for path in (WORKLOAD / ".build", DERIVED):
        shutil.rmtree(path, ignore_errors=True)


def thermal_pressure():
    out = subprocess.run(["pmset", "-g", "therm"], capture_output=True, text=True)
    for line in out.stdout.splitlines():
        if "Pressure" in line or "Speed" in line:
            return line.strip()
    return "unknown"


def timed_build(build_cmd):
    """Clean build, wall time. Cleaning every rep is the point — incremental
    builds would hide the contention under a warm cache."""
    clean()
    t0 = time.perf_counter()
    proc = subprocess.run(build_cmd, cwd=WORKLOAD, capture_output=True, text=True)
    elapsed = time.perf_counter() - t0
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout)[-1500:]
        raise RuntimeError(f"build failed ({proc.returncode}):\n{tail}")
    return elapsed


class BackgroundLoad:
    """Starts load.py and blocks until its memory is actually resident.

    Waiting for the 'loaded' event matters: starting the build during the
    allocation phase would measure a transient instead of steady-state
    contention.
    """

    def __init__(self, memory_gb, qos):
        self.memory_gb = memory_gb
        self.qos = qos
        self.proc = None
        self.info = None

    def __enter__(self):
        cmd = [str(VENV_PY), str(HERE / "load.py"), "--memory-gb", str(self.memory_gb)]
        if self.qos == "background":
            cmd = ["taskpolicy", "-b"] + cmd
        self.proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
        )
        deadline = time.time() + 180
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("load process exited before becoming resident")
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("event") == "loaded":
                self.info = event
                return self
        raise RuntimeError("timed out waiting for load to become resident")

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
    ap.add_argument("--calibrate", action="store_true",
                    help="time one unloaded clean build and exit")
    ap.add_argument("--reps", type=int, default=3, help="builds per condition")
    ap.add_argument("--out", default=str(HERE / "results.json"))
    args = ap.parse_args()

    if not WORKLOAD.exists():
        sys.exit("No workload. Run: python3 gen_workload.py")

    build_cmd, build_name = detect_build_cmd()
    print(f"build system: {build_name}")

    if args.calibrate:
        t = timed_build(build_cmd)
        print(f"clean build: {t:.1f}s")
        if t < 20:
            print("  Too short — variance will swamp the signal.")
            print("  Regenerate with more modules: python3 gen_workload.py --modules 120")
        elif t > 120:
            print("  Longer than needed; the full sweep will take a while.")
            print("  Regenerate with fewer: python3 gen_workload.py --modules 30")
        else:
            print("  Good range. Run the sweep: python3 run_e2.py --reps 3")
        return 0

    ws = metal_working_set_bytes()
    ws_gb = ws / (1 << 30)
    print(f"Metal max_recommended_working_set_size: {ws_gb:.1f} GiB")

    conditions = [{"label": "baseline (no load)", "memory_gb": 0, "qos": None}]
    for frac in CEILING_FRACTIONS:
        for qos in QOS_MODES:
            conditions.append({
                "label": f"{int(frac * 100)}% ceiling / {qos} QoS",
                "memory_gb": round(ws_gb * frac, 1),
                "qos": qos,
                "ceiling_frac": frac,
            })

    print(f"{len(conditions)} conditions x {args.reps} reps\n")
    results = []
    for cond in conditions:
        times = []
        for rep in range(args.reps):
            try:
                if cond["memory_gb"] == 0:
                    times.append(timed_build(build_cmd))
                else:
                    with BackgroundLoad(cond["memory_gb"], cond["qos"]) as load:
                        if rep == 0:
                            cond["resident_gb"] = load.info["resident_gb"]
                        times.append(timed_build(build_cmd))
            except Exception as e:
                print(f"  {cond['label']} rep {rep}: FAILED — {e}")
        if not times:
            continue
        cond["times"] = [round(t, 2) for t in times]
        cond["median_s"] = round(statistics.median(times), 2)
        cond["thermal"] = thermal_pressure()
        results.append(cond)
        print(f"  {cond['label']:<34} median {cond['median_s']:>7.2f}s   {cond['times']}")

    baseline = results[0]["median_s"]
    for r in results:
        r["slowdown_pct"] = round((r["median_s"] / baseline - 1) * 100, 1)

    print(f"\n{'condition':<34} {'median':>9} {'vs baseline':>13}")
    print("-" * 58)
    for r in results:
        print(f"{r['label']:<34} {r['median_s']:>8.2f}s {r['slowdown_pct']:>12.1f}%")

    with open(args.out, "w") as f:
        json.dump({"build_system": build_name,
                   "metal_working_set_gb": round(ws_gb, 1),
                   "reps": args.reps,
                   "results": results}, f, indent=2)
    print(f"\nWrote {args.out}")

    print("\nInterpretation: the threshold that matters is where slowdown becomes")
    print("perceptible to a person, not where it becomes measurable. Treat >10%")
    print("as the danger zone for daytime harvesting — a build that takes 10%")
    print("longer is a build an engineer will notice and complain about.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
