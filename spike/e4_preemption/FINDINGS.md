# E4 - Preemption economics

**Test machine:** MacBook Pro, Apple M2 Max, 64 GB unified, macOS 26.3
**Runtime:** MLX 0.32.0 / mlx-lm 0.31.3, 4-bit quantized models
**Device read rate:** 4.44 GB/s measured uncached on real safetensors

## Result

| Model | Disk | Resident | Load warm | Load cold~ | Release | tok/s | Min unit @10% |
|---|---|---|---|---|---|---|---|
| Qwen2.5-0.5B-4bit | 0.27 GB | 0.26 GB | 0.386 s | 0.44 s | 0.017 s | 394.9 | 4.0 s |
| Llama-3.2-3B-4bit | 1.70 GB | 1.68 GB | 0.812 s | 1.02 s | 0.019 s | 153.2 | 9.2 s |
| Qwen2.5-7B-4bit | 4.00 GB | 3.99 GB | 0.692 s | 1.23 s | 0.022 s | 77.5 | 11.1 s |
| Qwen2.5-14B-4bit | 7.75 GB | 7.74 GB | 1.359 s | 2.80 s | 0.028 s | 38.8 | 25.2 s |

Cold load is warm load plus the measured uncached read of that model's own
weight files. Minimum unit is `D >= L(1-t)/t` at `t = 10%`, on the cold basis.

## The plan's central assumption was wrong, in our favour

The plan asserted model load would be "30-60s" and concluded: *"If you preempt on
user activity you throw that away. This single constraint dictates your
work-unit sizing."*

It is **1.4 s warm and 2.8 s cold for a 14B model** - roughly 20x cheaper than
assumed. Extrapolating to a 70B 4-bit (~40 GB) gives ~9 s of device read plus
~7 s of parse and allocate, so ~16 s cold and a ~2.5 minute minimum work unit.
Still entirely tractable.

The reason is unified memory. On a discrete-GPU machine, loading weights means
reading from disk *and then* transferring host→device across PCIe. On Apple
Silicon that second step does not exist - weights land directly in memory the GPU
already addresses. The architectural property that makes contention hard (shared
memory, shared bandwidth) is the same one that makes preemption cheap.

### What this changes

- **Work units are seconds-to-minutes, not the ~10 minutes the plan targeted.**
  The E4 gate condition ("under ~10 minutes") is met with an order of magnitude
  to spare.
- **Preemption is cheap, so the agent should yield aggressively.** The design
  tension of "hold on a bit longer because reloading is expensive" mostly
  dissolves. Yield instantly; the reload costs seconds.
- **The harvest tier no longer needs long guaranteed-idle windows.** Machines
  with frequent short interruptions remain useful, which widens the addressable
  fleet considerably.
- **Release is effectively free** at 17-28 ms in-process, so keeping a worker
  alive across a yield is viable and killing the process is not required.

## The bottleneck moved to presence detection

With release at ~20 ms and reload at ~1-3 s, the dominant term in end-to-end
yield latency is now **how often presence is sampled**. `presence.py` polls at
2 s by default, so up to 2 s of work continues after a user touches the keyboard
- roughly 100x the cost of the memory release it triggers.

That inverts the optimization target. The thing to tune is the presence polling
interval, not the release path. Sub-second polling is cheap (the signals are
`ioreg` and `pmset` reads) and should be the default in `ACTIVE`-adjacent states.

## Caveats

- Load times are *warm-process* numbers: the Python interpreter and MLX are
  already imported. A cold agent process pays interpreter and framework startup
  on top, unmeasured here. The shipping `mlx-swift` agent avoids most of it.
- Only up to 14B was measured. The 70B figure above is an extrapolation from the
  measured read rate and load scaling, not a measurement.
- Load time did not scale cleanly with size - 7B loaded faster warm (0.692 s)
  than 3B (0.812 s), suggesting parallel file reads and run-to-run variance
  dominate at these small durations. The cold estimates are monotonic and are
  the safer basis for planning.
- Generation throughput scales roughly inversely with model size
  (394.9 → 153.2 → 77.5 → 38.8 tok/s), consistent with being memory-bandwidth
  bound.

## Measurement traps this avoids

Three attempts produced confidently optimistic numbers before the fourth worked:

1. **`lazy=True`** in `mlx_lm.load` defers weight materialization to first use
   and reports a fraction of the real load time. `lazy=False` plus an explicit
   `mx.eval(model.parameters())` is required.
2. **Reading back a just-written file** measures the page cache, not the device
   (9.83 GB/s on hardware that does ~4.4).
3. **`F_NOCACHE` on a file of zeros** measures nothing at all - APFS stores it
   sparsely, so the read never reaches the device and the number went *up* to
   15.35 GB/s.

The working approach reads each model's real safetensors with `F_NOCACHE`: real
data, real layout, real sizes.
