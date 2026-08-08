#!/usr/bin/env python3
"""
E5 step 1 - build an ANE-resident Core ML model, and prove it is ANE-resident.

The hypothesis worth testing: the Neural Engine is separate silicon from the
GPU, so ANE work should not compete with an artist's viewport the way MLX does.
If true, ANE workloads can run during working hours rather than overnight only,
roughly doubling usable fleet hours. That is the largest single upside left in
the spike.

The trap is that Core ML silently falls back. Asking for CPU_AND_NE is a
*preference*, not a guarantee: unsupported ops, unsupported dtypes, or awkward
tensor shapes quietly land on CPU. A run that measured "ANE load barely disturbs
the viewport" while actually executing on CPU would be both wrong and extremely
persuasive, which is the worst combination.

So placement is verified with MLComputePlan, which reports the compute device
per operation, rather than inferred from timing.

Requires the Python 3.12 venv (.venv-coreml). coremltools 9.0 ships no compiled
BlobWriter for 3.14, so conversion fails there with "BlobWriter not loaded".

    ../.venv-coreml/bin/python build_model.py --layers 16 --channels 64
"""

import argparse
import pathlib

import numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb


def build(layers, channels, size):
    """A deep fp16 convolution stack - the shape the ANE is happiest with.

    Conv/ReLU is chosen deliberately: it is the most reliably ANE-mappable
    pattern available. Something more exotic risks measuring CPU fallback and
    calling it an ANE result.
    """
    @mb.program(input_specs=[mb.TensorSpec(shape=(1, channels, size, size))])
    def prog(x):
        for i in range(layers):
            # fp32 weights here; compute_precision=FLOAT16 casts at compile
            # time. Declaring fp16 weights against an fp32 input spec is a
            # dtype-mismatch error in the MIL builder.
            w = np.random.randn(channels, channels, 3, 3).astype(np.float32) * 0.05
            x = mb.conv(x=x, weight=w, pad_type="same", name=f"conv{i}")
            x = mb.relu(x=x, name=f"relu{i}")
        return x

    return ct.convert(
        prog,
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        compute_precision=ct.precision.FLOAT16,
    )


def verify_placement(path):
    """Report which compute device each operation actually landed on.

    Returns (counts, total). An ANE share well below 1.0 means the load
    generator is not measuring what it claims to measure.
    """
    from coremltools.models.compute_plan import MLComputePlan

    # MLComputePlan needs a compiled .mlmodelc, not the .mlpackage. Handed the
    # package it aborts the process at the C++ level rather than raising, so
    # compile first and never pass the package path.
    #
    # The reference must stay alive: the compiled artifact lives in a temp
    # directory owned by the MLModel, and letting it fall out of scope on the
    # same line deletes the .mlmodelc before the plan can read it.
    model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_AND_NE)
    compiled = model.get_compiled_model_path()

    # Pass the same preference through, or the plan reports placement for a
    # different compute-unit policy than the load generator will actually use.
    plan = MLComputePlan.load_from_path(
        str(compiled), compute_units=ct.ComputeUnit.CPU_AND_NE
    )
    structure = plan.model_structure
    program = getattr(structure, "program", None)
    if program is None:
        return None, 0

    counts, total = {}, 0
    for function in program.functions.values():
        for op in function.block.operations:
            usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
            if usage is None:
                continue
            device = type(getattr(usage, "preferred_compute_device", None)).__name__
            # Const ops are metadata, not compute; counting them dilutes the
            # signal we actually care about.
            if getattr(op, "operator_name", "") == "const":
                continue
            counts[device] = counts.get(device, 0) + 1
            total += 1
    return counts, total


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--layers", type=int, default=16)
    ap.add_argument("--channels", type=int, default=64)
    ap.add_argument("--size", type=int, default=256)
    ap.add_argument("--out", default=str(pathlib.Path(__file__).parent / "ane_load.mlpackage"))
    args = ap.parse_args()

    print(f"Building {args.layers}x conv({args.channels}ch) @ {args.size}x{args.size} fp16...")
    model = build(args.layers, args.channels, args.size)
    out = pathlib.Path(args.out)
    model.save(str(out))
    print(f"Saved {out}")

    print("\nVerifying compute placement (MLComputePlan)...")
    counts, total = verify_placement(out)
    if not total:
        print("  Could not read a compute plan. Placement is UNVERIFIED - do not")
        print("  trust any contention result produced with this model.")
        return 1

    for device, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {device:<32} {n:>4} ops  ({100 * n / total:.0f}%)")

    ane = sum(n for d, n in counts.items() if "NeuralEngine" in d)
    share = ane / total
    print(f"\nANE share: {share:.0%} of {total} compute ops")
    if share < 0.8:
        print("VERDICT: NOT ANE-resident enough. Core ML fell back for most ops, so")
        print("this model would measure CPU/GPU contention while claiming to measure")
        print("ANE. Adjust the op mix before running the contention comparison.")
        return 1
    print("VERDICT: ANE-resident. Safe to use as the E5 load generator.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
