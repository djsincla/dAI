#!/usr/bin/env python3
"""
E5 step 2 — sustained ANE load, the counterpart to e2_contention/load.py.

Runs the verified ANE-resident model in a loop so the viewport benchmark can be
measured against Neural Engine pressure instead of GPU pressure. If the ANE is
genuinely separate silicon, this should disturb an artist's viewport far less
than equivalent MLX work, which would make daytime harvesting viable.

Run with the Python 3.12 venv (.venv-coreml); coremltools has no working
BlobWriter on 3.14.

    ../.venv-coreml/bin/python ane_load.py --duration 60
"""

import argparse
import json
import signal
import sys
import time

import numpy as np
import coremltools as ct

_stop = False


def _handle_stop(signum, frame):
    global _stop
    _stop = True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", default="ane_load.mlpackage")
    ap.add_argument("--duration", type=float, default=0,
                    help="seconds to run; 0 means until SIGTERM")
    ap.add_argument("--report", help="path for a JSON summary on exit")
    args = ap.parse_args()

    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)

    # CPU_AND_NE excludes the GPU entirely. That exclusion is the whole point:
    # ALL would let Core ML schedule onto the GPU and silently reintroduce the
    # contention this experiment exists to avoid.
    model = ct.models.MLModel(args.model, compute_units=ct.ComputeUnit.CPU_AND_NE)
    spec = model.get_spec()
    inp = spec.description.input[0]
    shape = tuple(int(d) for d in inp.type.multiArrayType.shape)
    name = inp.name

    batch = np.random.randn(*shape).astype(np.float32)
    model.predict({name: batch})  # warm up: first predict pays compilation

    print(json.dumps({"event": "loaded", "input": name, "shape": list(shape)}),
          flush=True)

    start = time.perf_counter()
    iters = 0
    while not _stop:
        if args.duration and time.perf_counter() - start >= args.duration:
            break
        model.predict({name: batch})
        iters += 1

    elapsed = time.perf_counter() - start
    summary = {
        "event": "done",
        "iters": iters,
        "elapsed_s": round(elapsed, 3),
        "inferences_per_s": round(iters / elapsed, 1) if elapsed else 0,
    }
    print(json.dumps(summary), flush=True)
    if args.report:
        with open(args.report, "w") as f:
            json.dump(summary, f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
