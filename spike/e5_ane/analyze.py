#!/usr/bin/env python3
"""
Aggregate E5 viewport results across interleaved reps.

The reason this exists rather than a single before/after comparison: two full
runs of E5 produced baseline p95 of 17.79ms and 24.22ms with no load at all — a
36% swing. Against a single leading baseline that variance made gpu-25gb look 3x
gentler than gpu-4gb in one run and identical to it in the next. Any effect
smaller than the baseline's own spread is not an effect.
"""

import json
import pathlib
import re
import statistics
import sys

ORDER = ["baseline", "gpu-25gb", "gpu-4gb", "ane"]


def load_groups(out):
    groups = {}
    for path in sorted(pathlib.Path(out).glob("*.json")):
        try:
            data = json.load(open(path))
        except (json.JSONDecodeError, OSError):
            continue
        if "p95_ms" not in data:
            continue
        stem = re.sub(r"\.\d+$", "", path.stem)          # "gpu-4gb.2" -> "gpu-4gb"
        if stem.startswith("baseline"):                   # -a / -b both pool
            stem = "baseline"
        groups.setdefault(stem, []).append(data)
    return groups


def med(rows, key):
    return statistics.median(r[key] for r in rows)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "results"
    groups = load_groups(out)
    if "baseline" not in groups:
        sys.exit(f"no baseline samples in {out}/")

    base_p95 = med(groups["baseline"], "p95_ms")
    samples = sorted(round(r["p95_ms"], 2) for r in groups["baseline"])
    spread = (max(samples) / min(samples) - 1) * 100 if len(samples) > 1 else 0.0

    print(f"baseline p95 samples: {samples}")
    print(f"baseline spread: {spread:.0f}%  <- effects smaller than this are noise\n")

    print(f"{'condition':<11} {'n':>3} {'p50':>8} {'p95':>8} {'p99':>8} "
          f"{'fps':>7} {'p95 vs base':>12}")
    print("-" * 64)
    for label in ORDER:
        rows = groups.get(label)
        if not rows:
            continue
        delta = (med(rows, "p95_ms") / base_p95 - 1) * 100
        verdict = "" if abs(delta) > spread else "  (within noise)"
        print(f"{label:<11} {len(rows):>3} {med(rows,'p50_ms'):>8.2f} "
              f"{med(rows,'p95_ms'):>8.2f} {med(rows,'p99_ms'):>8.2f} "
              f"{med(rows,'mean_fps'):>7.1f} {delta:>11.1f}%{verdict}")

    print("\nMedians across interleaved reps.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
