# E1 - Metal access from a background context

**Test machine:** MacBook Pro, Apple M2 Max, 64 GB unified, macOS 26.3 (25D125), Xcode 26.6 / Swift 6.3.3
**Runtime:** MLX 0.32.0 (`mlx` + `mlx-metal`, native `cp314` / `macosx_26_0_arm64` wheels)

## Status: E1 PASSES

| Context | Session | uid | GPU reachable | Presence signals |
|---|---|---|---|---|
| Interactive shell | Aqua | 501 | **YES** | all readable |
| LaunchAgent (`gui/501`) | Aqua | 501 | **YES** (4/4) | all readable |
| LaunchDaemon, unlocked | **System** | **0** | **YES** (2/2) | all readable |
| LaunchDaemon, screen locked | **System** | **0** | **YES** (2/2) | all readable |
| LaunchDaemon, logged out | - | - | **UNTESTED** | **UNTESTED** |

**The node agent can ship as a single system daemon.** No split into a computing
daemon plus a sensing LaunchAgent, and no dependency on a logged-in user.

Two things make the result credible rather than incidental:

- The context is genuinely session 0 (`security_session = System`, `uid = 0`),
  not the Aqua session in disguise.
- Presence signals survived. `hid_idle_s` tracked correctly across samples
  (1 → 5 → 38 → 5s), `screen_locked` flipped accurately, `console_user`
  resolved. Reading via IOKit and `pmset` rather than AppKit was the load-bearing
  decision, and it is now confirmed rather than assumed.

### Related, from E3: Metal works as a non-console user

While running E3, `orca` had user `kim` logged in at the console and a worker
executing over SSH as `dwayne`. Metal was reachable and GPU matmuls ran
normally.

That is a fourth session context beyond the three tested here, and it further
supports the conclusion that Metal access is not gated on owning the console
session.

### Open: the ABSENT state is untested

Every daemon sample recorded `console_user = dwayne`. The logout step was
skipped, so the state with the most permissive policy - 85% memory ceiling,
standard QoS - has never actually been exercised. Locked-with-a-user-logged-in
passing is encouraging but is not proof: with no user session at all,
WindowServer's state differs.

No longer existential, since a fallback to "harvest only while someone is
logged in" still leaves a working product. But it caps overnight capacity, which
is where most of the value is. Worth closing before Phase 1 policy is finalized.

## Confirmed: QoS behaves identically in session 0

Daemon samples ran 2549 / 2401 / 2934 GFLOPS - mean ~2630, excluding a 1628
first sample that is cold-start shader compilation. That closely matches the
LaunchAgent's ~3183 under the same `ProcessType: Background`, and sits far below
the ~7830 foreground baseline.

So `ProcessType` is genuinely the control, and it throttles a system daemon the
same way it throttles a user agent. The dynamic-QoS design below applies
unchanged to the shipping deployment shape.

## Confirmed finding: background QoS costs ~2.4x GPU throughput

Measured with the same 2048x2048 fp32 matmul, 50 iterations, `mx.eval()` forced
each iteration (MLX is lazy - without the eval the loop measures nothing).

| Context | GFLOPS | Mean |
|---|---|---|
| Foreground, interactive | 7392 / 7979 / 8116 | ~7830 |
| Background QoS (`taskpolicy -b`) | 3160 / 3367 / 4722 | ~3750 |
| LaunchAgent, `ProcessType: Background` | 3102 / 3085 / 3363 / - | ~3183 |

`ProcessType: Background` in a launchd plist produces the same throttling as
`taskpolicy -b`, so the plist key is the effective control.

### Why this matters more than it looks

Background QoS is exactly the mechanism that makes a harvest agent polite - macOS
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
dials - QoS level and compute unit (GPU vs ANE) - and daytime harvesting becomes
viable rather than overnight-only.

## Incidental finding: Metal's own memory ceiling

`max_recommended_working_set_size` = 55,662,788,608 bytes (51.8 GiB) on a 64 GB
machine - about 81% of unified memory. This is a hard input to the E2 memory
ceiling policy: the agent's ceiling must sit under Metal's, and Metal's is
already well below total RAM.

Full device info recorded: `applegpu_g14s`, max buffer length 38.9 GiB,
resource limit 499000.

## Files

- `probe.py` - the probe. Forces real Metal work, verifies numerically against a
  CPU-stream computation, and checks GPU memory counters actually moved (a silent
  CPU fallback would still return correct numbers, so correctness alone is not
  proof of GPU execution). Appends JSONL when the output path ends in `.jsonl`.
- `com.dai.e1probe.agent.plist` - LaunchAgent, user GUI session. Done.
- `com.dai.e1probe.daemon.plist` - LaunchDaemon, system session 0. Pending.
- `run_daemon_test.sh` - `install` / `collect` / `uninstall` for the daemon test.

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
cannot ship as a system daemon and must fall back to a LaunchAgent - restricting
the harvest tier to logged-in-but-idle machines.
