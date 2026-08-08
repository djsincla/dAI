# E2 - At what settings does the interactive user notice?

**Test machine:** MacBook Pro, Apple M2 Max, 64 GB unified, macOS 26.3
**Instrument:** Blender 4.0.2 EEVEE viewport orbit, 150 frames, p95 frame time
**Load:** MLX matmul at controlled memory footprint and duty cycle
**Design:** baselines interleaved between conditions, 5 baseline samples

## Result: no GPU setting is safe while a user is present

| Condition | QoS | Duty | Mem | p95 | vs baseline |
|---|---|---|---|---|---|
| bg-duty25 | background | 0.25 | 8 GB | 25.55 ms | **+46.4%** |
| bg-duty50 | background | 0.50 | 8 GB | 33.13 ms | +89.9% |
| std-mem32 | standard | 1.00 | **32 GB** | 33.17 ms | +90.1% |
| std-duty25 | standard | 0.25 | 8 GB | 33.53 ms | +92.1% |
| std-duty50 | standard | 0.50 | 8 GB | 33.70 ms | +93.1% |
| bg-duty100 | background | 1.00 | 8 GB | 41.80 ms | +139.5% |
| std-duty100 | standard | 1.00 | 8 GB | 50.53 ms | +189.6% |

Baseline p95 samples: 17.36, 17.39, 17.45, 18.41, 24.90 ms - median 17.45.

**Every tested GPU configuration is perceptible.** The gentlest - background QoS
at 25% duty - still costs 46% of viewport p95. There is no throttle setting that
makes GPU harvesting invisible to someone using the machine.

This narrows the harvest tier sharply: **GPU work waits for LOCKED or ABSENT.**
Which in turn makes E5's result load-bearing - ANE work, measured as
indistinguishable from no load, is the *only* daytime harvesting option.

## Two independent levers, both real

**Duty cycle** is monotonic within each QoS: 25.55 → 33.13 → 41.80 ms for
background at 0.25/0.50/1.00. It is the throttle the policy engine was missing.

**QoS** is separate and additive: bg-duty25 (25.55) against std-duty25 (33.53) at
identical duty and memory.

Neither is sufficient alone, but together they define the LOCKED/ABSENT settings
and the (narrow) IDLE allowance.

## Memory is the wrong axis, and may be inverted

`std-mem32` ran **4x the memory** of `std-duty100` at identical duty and QoS, and
disturbed the viewport **less** (+90.1% vs +189.6%).

This is now the third observation pointing the same direction:

| Source | Larger footprint | Smaller footprint |
|---|---|---|
| E5 run 1 | 25 GB: +42% | 4 GB: +137% |
| E5 run 2 | 25 GB: +72% | 4 GB: +73% |
| E2 sweep | 32 GB: +90% | 8 GB: +190% |

Two of three favour "larger working sets disturb less." The claim was retracted
after E5 run 2 for lack of replication; it is no longer dismissible, though still
not established. A plausible mechanism is that a large working set is
bandwidth-bound and leaves GPU compute stalls the compositor can use, while a
cache-resident small one saturates compute continuously.

**Regardless of direction, `mem_frac` must not be used as a politeness dial.**
Footprint governs what fits. Occupancy governs disturbance.

## On the noise floor

The reported floor is 43%, but that is driven entirely by one outlier baseline
(24.90 ms) against four clustered at 17.36–18.41 - a true spread of ~6% with
occasional excursions.

The conservative 43% was used anyway, and **every condition still failed it**.
Against the tighter figure the conclusion is far stronger, so the finding does
not depend on which floor is chosen. That is the point of interleaving baselines:
E5 showed that a single leading baseline lets this variance manufacture or erase
an entire effect.

## Resulting policy

`presence/presence.py` now carries measured values rather than estimates:

| State | GPU | ANE | QoS | duty_max | mem_frac |
|---|---|---|---|---|---|
| ACTIVE | ✗ | ✓ | background | 0.00 | 0.00 |
| PASSIVE | ✗ | ✓ | background | 0.00 | 0.15 |
| IDLE | ✓ | ✓ | background | 0.25 | 0.35 |
| LOCKED | ✓ | ✓ | standard | 1.00 | 0.70 |
| ABSENT | ✓ | ✓ | standard | 1.00 | 0.85 |

IDLE permits GPU work at the gentlest measured setting only. The screen is still
on and the user may be reading rather than typing, but E4 puts yield at ~20 ms
plus the poll interval, so a return is absorbed quickly.

## Caveats

- One rep per condition. Enough to separate a 46-190% effect from a 43% floor;
  not enough to rank conditions that land within ~20% of each other.
- Synthetic matmul load, not real model inference, which has different memory
  access patterns.
- Blender viewport is the strictest instrument available here. A machine whose
  user only runs an editor and a browser would tolerate more; the policy is set
  by the worst case on purpose.
- Duty cycling is implemented by sleeping between matmuls. A real inference
  worker would throttle at work-unit boundaries instead, which is coarser.

## Supersedes

`run_e2.py` swept memory ceiling against an Xcode build with a single leading
baseline. All three choices were wrong: the wrong instrument (bandwidth
contention rather than GPU), the wrong axis (memory rather than occupancy), and
baseline discipline that E5 proved can fabricate findings. It is retained only
for the Xcode-build workload, which still needs the interleaved-baseline
treatment before its numbers mean anything.
