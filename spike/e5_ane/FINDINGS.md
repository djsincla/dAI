# E5 - Is ANE work less perceptible than GPU work?

**Test machine:** MacBook Pro, Apple M2 Max, 64 GB unified, macOS 26.3
**Interactive workload:** Blender 4.0.2 EEVEE viewport orbit (see `../e2_contention/`)
**ANE workload:** 16-layer fp16 conv stack, 169 inferences/s sustained
**Runs:** 2 full reps, medians below

## Result

| Condition | n | p50 | p95 | p99 | fps | p95 vs baseline |
|---|---|---|---|---|---|---|
| baseline | 2 | 16.59 | 21.00 | 21.78 | 67.7 | - |
| gpu-25gb | 2 | 21.18 | 33.45 | 34.08 | 45.0 | **+59.2%** |
| gpu-4gb | 2 | 32.81 | 42.01 | 42.69 | 32.2 | **+100.0%** |
| **ane** | 2 | 16.60 | **17.57** | 17.98 | 66.3 | **−16.4% (within noise)** |

Baseline p95 samples were 17.79 and 24.22 ms - a **36% spread with no load at
all**. That is the noise floor, and anything smaller than it is not an effect.

## ANE load is indistinguishable from no load

The hypothesis holds. While sustaining 169 inferences/s of verified Neural
Engine work, the viewport was statistically indistinguishable from idle: p95 of
17.33 and 17.81 ms across the two runs - a **tighter spread than the baseline's
own**, and sitting at the good end of baseline's range.

Against +59% to +100% for equivalent GPU work.

**The ANE really is the closest thing Apple Silicon has to the render farm's
dedicated second card.** It is separate silicon, and an artist's viewport does
not touch it. This is what makes daytime harvesting viable rather than
overnight-only, roughly doubling usable fleet hours.

### Placement was verified, not assumed

Core ML treats `CPU_AND_NE` as a *preference*. Unsupported ops, dtypes, or
shapes fall back to CPU silently. A result reading "ANE load barely disturbs the
viewport" would be both wrong and extremely persuasive if the work had actually
run on CPU.

`MLComputePlan` reports **100% of 34 compute ops on `MLNeuralEngineComputeDevice`**.
`build_model.py` refuses to proceed below an 80% ANE share.

## Memory fraction is not a politeness dial

A **4 GB** load - a small fraction of a 64 GB machine - degraded p95 by 100%.
Memory ceiling governs *what fits*; it does not govern *how much a user is
disturbed*. The agent must throttle compute rate, not just footprint.

This matters directly: `presence/presence.py` uses `mem_frac` as its per-state
politeness control. That is the wrong lever on its own.

### A retracted claim

An earlier single run showed gpu-4gb at +137% against gpu-25gb at +42%, and a
cache-residency mechanism was proposed to explain why a *smaller* footprint hurt
*more*. **It did not replicate.** In run 2 the two were near-identical (41.92 vs
41.61 ms). The gap came from gpu-25gb being unusually good in run 1, not from
any property of small allocations.

gpu-25gb is simply the high-variance condition (25.29 and 41.61 ms across runs)
while gpu-4gb is stable (42.10, 41.92). Whether footprint size affects
disturbance at all is **unresolved** and would need more reps to settle. What is
solid is that 4 GB is not gentle.

## Methodological finding: baselines must be interleaved

The baseline moved 36% between runs with nothing loaded. Measured once at the
start of a sweep, that variance is silently attributed to whatever condition ran
next - which is exactly how the retracted finding above was manufactured.

`run_e5.sh` now measures a baseline before *and* after each loaded condition and
pools them, and `analyze.py` prints the baseline spread and flags any delta
falling inside it as noise.

**This applies to E2's sweep as well**, which is currently written with a single
leading baseline across 7 conditions. It should be restructured the same way
before its numbers are trusted.

## Caveats

- Two reps. Enough to separate a 100% effect from a 36% noise floor; not enough
  to resolve smaller differences.
- The GPU load is a synthetic matmul, not real model inference, which has
  different memory access patterns. A real-model rerun should follow.
- The ANE workload is a conv stack. Real ANE-eligible work (embeddings, a
  Whisper encoder) may map less cleanly and should be re-verified with
  `MLComputePlan` before being trusted.
- ANE throughput is far lower than GPU throughput in absolute terms. E5 says ANE
  work is *invisible*, not that it is *fast*. Sizing the actual capacity of
  ANE-only harvesting is a separate measurement.

## Environment note

Core ML work runs in a **Python 3.12** venv (`.venv-coreml`). coremltools 9.0
ships no compiled `BlobWriter` for Python 3.14 and conversion fails with
`RuntimeError: BlobWriter not loaded`. MLX runs fine on 3.14, so the two
runtimes live in separate venvs.

`MLComputePlan.load_from_path` also needs a compiled `.mlmodelc`, not an
`.mlpackage` - given the package it aborts the process at the C++ level rather
than raising. The compiled artifact lives in a temp directory owned by the
`MLModel`, so that reference must stay alive while the plan is read.
