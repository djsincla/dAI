#!/usr/bin/env python3
"""
Background MLX load with a controlled unified-memory footprint.

Stands in for a harvest-tier inference worker. Synthetic rather than a real
model on purpose: it isolates the two variables E2 actually sweeps — resident
memory and sustained GPU work — without confounding them with model-specific
load times or download size. A real-model rerun should follow once the
synthetic sweep identifies the interesting region.

Cycles matmuls across a ring of large buffers rather than hammering one, so the
working set genuinely streams through memory. Reusing a single buffer would sit
in cache and understate bandwidth contention, which is the whole mechanism we
are trying to measure on unified memory.

QoS is set by the caller (`taskpolicy -b`), not here — that mirrors how launchd
applies ProcessType and keeps this process honest about what it inherited.
"""

import argparse
import json
import signal
import sys
import time

import mlx.core as mx

_stop = False


def _handle_stop(signum, frame):
    global _stop
    _stop = True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--memory-gb", type=float, required=True,
                    help="target resident GPU memory")
    ap.add_argument("--matrix-n", type=int, default=4096,
                    help="edge length of each buffer")
    ap.add_argument("--duration", type=float, default=0,
                    help="seconds to run; 0 means until SIGTERM")
    ap.add_argument("--report", help="path to write a JSON summary on exit")
    args = ap.parse_args()

    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    mx.set_default_device(mx.gpu)

    n = args.matrix_n
    bytes_per_buffer = n * n * 4  # fp32
    n_buffers = max(3, int(args.memory_gb * (1 << 30) / bytes_per_buffer))

    buffers = [mx.random.normal((n, n), dtype=mx.float32) for _ in range(n_buffers)]
    mx.eval(buffers)  # MLX is lazy; without this nothing is actually resident

    resident = mx.get_active_memory()
    print(json.dumps({
        "event": "loaded",
        "requested_gb": args.memory_gb,
        "buffers": n_buffers,
        "matrix_n": n,
        "resident_bytes": resident,
        "resident_gb": round(resident / (1 << 30), 2),
    }), flush=True)

    start = time.perf_counter()
    iters = 0
    i = 0
    while not _stop:
        if args.duration and time.perf_counter() - start >= args.duration:
            break
        # Walk the ring so each matmul touches a different pair of buffers.
        a = buffers[i % n_buffers]
        b = buffers[(i + 1) % n_buffers]
        mx.eval(a @ b)
        iters += 1
        i += 1

    elapsed = time.perf_counter() - start
    summary = {
        "event": "done",
        "iters": iters,
        "elapsed_s": round(elapsed, 3),
        "gflops": round(2 * (n ** 3) * iters / elapsed / 1e9, 1) if elapsed else 0,
        "resident_gb": round(resident / (1 << 30), 2),
        "peak_gb": round(mx.get_peak_memory() / (1 << 30), 2),
    }
    print(json.dumps(summary), flush=True)
    if args.report:
        with open(args.report, "w") as f:
            json.dump(summary, f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
