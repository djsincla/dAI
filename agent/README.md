# dai-agent

The node agent, in Swift. Replaces the Python agent in `../spike/harvest/`,
which remains the working reference until this reaches parity.

## Why Swift and not Node or Python

Asked and answered with data in `../docs/CONTROL_PLANE.md`. The short version:
MLX from Node is viable via community bindings, but **Core ML from Node is not**,
and the agent does not merely need inference, it needs `MLComputePlan` to verify
that work actually landed on the ANE. E2 and E5 together make ANE work the only
thing three of five presence states permit, so an agent that cannot drive Core ML
cannot do daytime work at all.

Swift also ships as one signed binary with no runtime to install across a fleet,
which is what a Python environment on every Mac was always going to cost.

## What is here

| | |
|---|---|
| `Presence.swift` | Signals, classification, policy table, hysteresis. Pure. |
| `SignalSource.swift` | The real machine, via IOKit and power management. |
| `ANERuntime.swift` | Core ML pinned to the ANE, with `MLComputePlan` verification. |
| `QoS.swift` | Runtime QoS via `setpriority(PRIO_DARWIN_PROCESS)`. |
| `PresenceTests.swift` | 20 cases, ported from the Python suite. |

```
$ dai-agent verify-ane ane_embed.mlpackage
loaded in 1.82s
  NeuralEngine    34 ops  (100%)
ANE share: 100% of 34 compute ops
VERDICT: ANE-resident. Safe to run while someone is using the machine.
```

Placement verification is the safety property and the reason this is Swift.
Core ML treats `.cpuAndNeuralEngine` as a preference and falls back to CPU
silently, so a worker that believed it was on the ANE while running on the CPU
would disturb the very user it exists to avoid, with every log looking fine.

`MLComputePlan` requires macOS 14.4, which sets this package's floor. Making the
check conditional on availability was the alternative and is worse: an agent
that silently skips verification is the failure mode verification exists for.

The policy core is deliberately free of MLX and Core ML. Every policy bug found
in the Python agent reproduced from a recorded signal struct with no hardware
involved, and keeping that seam is what makes these tests runnable anywhere.

## Native where Python shelled out

The Python agent ran six subprocesses per sample (`ioreg`, `pmset` x3, `stat`)
costing ~116ms, which turned out to be four times the cost of the ANE work it
was guarding. Here those are calls:

| Signal | Python | Swift |
|---|---|---|
| HID idle | `ioreg -c IOHIDSystem` | `IORegistryEntryCreateCFProperty` |
| Screen locked | `ioreg -n Root` | `IORegistryGetRootEntry` |
| AC power | `pmset -g batt` | `IOPSCopyPowerSourcesInfo` |
| Thermal | `pmset -g therm` | `ProcessInfo.thermalState` |
| Sleep assertions | `pmset -g assertions` | `IOPMCopyAssertionsByProcess` |

Verified against the Python agent on the same machine at the same moment:
252.9s vs 253.0s idle, same lock state, same console user, same classification.

## Running

```bash
swift build
swift run dai-agent      # prints what this machine currently looks like
swift test
```

## Not yet ported

- MLX runtime for `generate` work (mlx-swift is a dependency already)
- Core ML runtime and `MLComputePlan` placement verification for `embed`
- Control plane client: enrollment, mTLS, heartbeat, work leasing, reverse channel
- QoS switching via `setpriority(PRIO_DARWIN_PROCESS)`
- launchd daemon packaging and notarisation

Until those land, `../spike/harvest/harvest_worker.py` is the agent that works.
