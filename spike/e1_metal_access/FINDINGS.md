# E1 — Metal access from a background context

**Test machine:** MacBook Pro, Apple M2 Max, 64 GB unified, macOS 26.3 (25D125), Xcode 26.6 / Swift 6.3.3
**Runtime:** MLX 0.32.0 (`mlx` + `mlx-metal`, native `cp314` / `macosx_26_0_arm64` wheels)

## Status

| Context | Session | GPU reachable | Notes |
|---|---|---|---|
| Interactive shell | Aqua | **YES** | Baseline, 4 samples |
| LaunchAgent (`gui/501`) | Aqua | **YES** | 4/4 samples, exit 0 |
| LaunchDaemon (`system`) | — | **PENDING** | Needs `sudo`; see `run_daemon_test.sh` |
| LaunchDaemon, screen locked | — | **PENDING** | Same run, captured by interval sampling |
| LaunchDaemon, logged out | — | **PENDING** | Same run, optional step |

The daemon case is the actual gate. The agent result only proves the weaker
deployment shape works.

## Confirmed finding: background QoS costs ~2.4x GPU throughput

Measured with the same 2048x2048 fp32 matmul, 50 iterations, `mx.eval()` forced
each iteration (MLX is lazy — without the eval the loop measures nothing).

| Context | GFLOPS | Mean |
|---|---|---|
| Foreground, interactive | 7392 / 7979 / 8116 | ~7830 |
| Background QoS (`taskpolicy -b`) | 3160 / 3367 / 4722 | ~3750 |
| LaunchAgent, `ProcessType: Background` | 3102 / 3085 / 3363 / — | ~3183 |

`ProcessType: Background` in a launchd plist produces the same throttling as
`taskpolicy -b`, so the plist key is the effective control.

### Why this matters more than it looks

Background QoS is exactly the mechanism that makes a harvest agent polite — macOS
deprioritizes it against the artist's foreground work. But it costs ~2.4x
throughput, which is a large tax to pay overnight when nobody is at the machine.

**This should be a dynamic dial, not a static setting:**

- User present (logged in, recent input) → `Background` QoS, maximum politeness
- Machine confirmed idle (screen locked, no input for N minutes, on AC) → promote
  to `Standard`/`Adaptive` QoS for ~2.4x throughput

Naive always-Background operation leaves more than half the overnight capacity
on the table.

### Consequence for E2

E2 must measure interactive degradation at **both** QoS levels, not one. The
interesting question is no longer just "what memory ceiling is imperceptible"
but "**is Background QoS imperceptible enough to run during the working day?**"

If yes, that combines with the E5/ANE hypothesis into two independent politeness
dials — QoS level and compute unit (GPU vs ANE) — and daytime harvesting becomes
viable rather than overnight-only.

## Incidental finding: Metal's own memory ceiling

`max_recommended_working_set_size` = 55,662,788,608 bytes (51.8 GiB) on a 64 GB
machine — about 81% of unified memory. This is a hard input to the E2 memory
ceiling policy: the agent's ceiling must sit under Metal's, and Metal's is
already well below total RAM.

Full device info recorded: `applegpu_g14s`, max buffer length 38.9 GiB,
resource limit 499000.

## Files

- `probe.py` — the probe. Forces real Metal work, verifies numerically against a
  CPU-stream computation, and checks GPU memory counters actually moved (a silent
  CPU fallback would still return correct numbers, so correctness alone is not
  proof of GPU execution). Appends JSONL when the output path ends in `.jsonl`.
- `com.dai.e1probe.agent.plist` — LaunchAgent, user GUI session. Done.
- `com.dai.e1probe.daemon.plist` — LaunchDaemon, system session 0. Pending.
- `run_daemon_test.sh` — `install` / `collect` / `uninstall` for the daemon test.

## To finish E1

```bash
cd /Users/dwayne/Developer/dAI/spike/e1_metal_access
sudo ./run_daemon_test.sh install     # samples every 20s
# wait ~30s, then lock screen (Ctrl-Cmd-Q) ~60s, unlock
# optional: log out fully ~60s, log back in
./run_daemon_test.sh collect          # no sudo
sudo ./run_daemon_test.sh uninstall
```

Interpretation is built into `collect`: it groups GPU reachability by screen-lock
state and prints a verdict. A failure in any daemon state means the node agent
cannot ship as a system daemon and must fall back to a LaunchAgent — restricting
the harvest tier to logged-in-but-idle machines.
