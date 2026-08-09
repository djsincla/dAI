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
| `MLXRuntime.swift` | `generate` work via mlx-swift, with eager release. |
| `Worker.swift` | The loop: lease, per-item yield, partial results, duty cycling. |
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

## Control plane

```
$ dai-agent enroll https://control:8443 <join-token> server-ca.pem 300
nodeId e85f508d-...
state   pending
Approved. Identity written to ~/.dai/identity

$ dai-agent status https://control:8443
authenticated by client certificate
served policy states: ABSENT, ACTIVE, IDLE, LOCKED, PASSIVE
  ACTIVE   gpu=false ane=true  qos=background duty=0.00 mem=0.00
  LOCKED   gpu=true  ane=true  qos=standard   duty=1.00 mem=0.70
heartbeat sent: ACTIVE
```

The key is generated here and never sent. Policy is merged rather than adopted,
taking the stricter of the served and local tables per field: the server knows
fleet-wide intent and may be newer, the agent knows the machine and is what will
actually disturb its owner.

The bootstrap bundle is three things, not two: URL, join token, and the **server**
CA. A node must verify the control plane before it has an identity of its own.
The server CA is distinct from the node CA that signs agent identities, and
pinning the wrong one fails every connection with an error that reads like a
network problem.

## Why the client key is the awkward part

The agent authenticates with a certificate, and getting a `SecIdentity` out of
the PEM files enrollment produces is the one place this fought back. Worth
recording, because the symptom pointed nowhere near the cause:

| | |
|---|---|
| `curl` with the same PEM files | 0.00s |
| Swift, server trust only, no client cert | 0.01s |
| Swift, presenting the client identity | **61s timeout** |

Not the network, the server, the delegate or the certificate. `SecPKCS12Import`
imports the key under an ACL that asks the user to authorise each process that
signs with it, and the handshake blocks on that prompt. Interactively it looks
like a hang; the request is simply waiting for a click. Python's
`ssl.load_cert_chain` reads PEM directly and never involves the keychain, which
is why the Python agent never hit this.

Naming the process as a trusted application at import makes signing silent, and
that is what the code does now - but it is a stopgap, not a fix. The trust binds
to this binary, so a rebuild prompts again, and under `launchd` there is no user
to prompt: the daemon would stall exactly as the first measurement did.

**Which makes Secure Enclave generation load-bearing rather than a hardening
nicety.** A key generated in the Enclave has no ACL to negotiate, cannot be
copied off disk, and removes the dependency on whichever `openssl` the system
ships. It needs the control plane CA to sign EC P-256 CSRs, which node-forge
cannot do, so the server-side issuer moves at the same time.

`dai-agent timing <url>` reports per-phase latency and is what located this.

## Not yet ported

- **Secure Enclave key generation**, which is now both the security gap and the
  blocker above.
- Reverse channel for interactive requests
- launchd daemon packaging and notarisation
- A `render` runtime

Until those land, `../spike/harvest/harvest_worker.py` is the agent that works.
