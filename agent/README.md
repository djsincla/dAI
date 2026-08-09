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

## The node key lives in the Secure Enclave

The key is generated inside the Enclave and never exists outside it. On disk
there are 284 bytes the Enclave sealed to this machine: copy them to another Mac
and they are inert, so a certificate taken from a stolen laptop names a key the
thief cannot use. That is the difference between an identity and a file.

It arrived as hardening and turned out to be load-bearing. The previous scheme
imported an RSA PEM through `SecPKCS12Import`, which places the key under a
keychain ACL that asks the user to authorise every process that signs with it.
The handshake blocks on that prompt:

| | |
|---|---|
| `curl` with the same PEM files | 0.00s |
| Swift, server trust only, no client cert | 0.01s |
| Swift, presenting the imported identity | **61s timeout** |
| Swift, Enclave key | **0.03s** |

Interactively the stall is a dialog waiting to be clicked. Under `launchd` there
is nobody to click it, so the daemon would simply hang. An Enclave key has no
ACL to negotiate.

### What it cost

Three things had to move, and each is worth knowing before touching this code.

**The CA.** node-forge cannot sign elliptic-curve CSRs and the Enclave generates
nothing but P-256, so the control plane's issuer moved to WebCrypto. The
existing RSA CA still issues, with a test that signs an EC leaf under it and
runs `openssl verify -purpose sslclient`.

**The CSR builder.** Swift has no PKCS#10 encoder. CryptoKit signs and Security
parses, but nothing in the SDK produces the request between them, so `ASN1.swift`
encodes just enough DER by hand. Its tests check the bytes against `openssl`
rather than against the encoder that wrote them.

**The HTTP client.** `URLSession` can only present a client certificate as a
`SecIdentity`, which needs the key as a `SecKey`. A CryptoKit Enclave key is not
one, and making it one means putting the key in the keychain - the entitlement
this route exists to avoid. So the client is AsyncHTTPClient over NIOSSL, which
takes a signing callback and does not care where the key lives. One trap: on
macOS AsyncHTTPClient defaults to Network.framework, which rejects a client
certificate chain outright, so the BSD sockets loop has to be selected
explicitly.

`dai-agent timing <url>` reports per-phase latency, which is what found the
stall in the first place.

### Not the keychain, and why

`SecKeyCreateRandomKey` with `kSecAttrTokenIDSecureEnclave` is the more obvious
API and does not work here. It stores the key in the keychain, which refuses
with `errSecMissingEntitlement` (-34018) unless the binary carries a
`keychain-access-groups` entitlement backed by a provisioning profile; signing
one with the entitlement and no profile gets the process killed on launch.
CryptoKit hands back a sealed blob to store wherever we like and needs neither,
verified from an unsigned command line tool.

## Running as a daemon

A LaunchDaemon, not a LaunchAgent, and E1 is why. A daemon runs in session 0 as
root with nobody logged in and Metal still works: 2/2 probes passed with the
screen locked. A LaunchAgent only exists while somebody is logged in, which
would give up exactly the overnight hours the premise depends on.

```
swift build -c release
sudo packaging/install.sh --url https://control-plane:8452 \
                          --token JOIN_TOKEN \
                          --ca server-ca.crt \
                          --model mlx-community/Llama-3.2-3B-Instruct-4bit
```

Enrollment is part of installation because the two cannot be separated: the
daemon has nothing to authenticate with until an admin approves the node, and
one that starts without an identity sits in a reconnect loop that reads like a
network fault. The script is resumable - run it, approve the node, run it again.

Check a machine before installing anything, and check it as root too, since the
daemon's context is not the interactive one:

```
sudo packaging/../.build/release/dai-agent preflight
```

### The plist setting most likely to be "fixed" by someone helpful

`ProcessType` is `Standard`. `Background` looks like the polite choice and is the
wrong one: E1 measured it at 2.4x on sustained GPU work and the worker found
~26x on bursty ANE items, and launchd's `ProcessType` applies for the life of the
process. A daemon pinned to `Background` cannot promote itself when the user goes
home, which is when nearly all the capacity is. The agent sets its own QoS per
presence state instead - background the moment somebody is at the machine,
standard when they are not. Setting it in the plist takes that control away.

### Notarisation

`packaging/build-pkg.sh` produces a signed, notarised, stapled `.pkg`, which is
what MDM needs; `install.sh` is only appropriate for a machine you are sitting
at. Gatekeeper refuses an un-notarised package on every machine except the one
that built it, and quietly enough to waste a day.

It needs three credentials that are commonly confused with each other:

| | |
|---|---|
| Developer ID Application | signs the binary |
| Developer ID Installer | signs the `.pkg` |
| a `notarytool` profile | submits to Apple |

**None of these is the "Apple Development" certificate a normal Xcode setup
provides.** That one signs code for local use and Apple will not notarise
anything carrying it, so the script checks for the right identity up front
rather than failing after a release build. Stapling is not optional for this
product in particular: without it every target must reach Apple to verify, and
an air-gapped network is a realistic deployment for something sold on data never
leaving the building.

No entitlements are needed, which is a consequence of reaching the Secure
Enclave through CryptoKit rather than the keychain.

## Not yet ported

- **Secure Enclave key generation**, which is now both the security gap and the
  blocker above.
- Reverse channel for interactive requests
- launchd daemon packaging and notarisation
- A `render` runtime

Until those land, `../spike/harvest/harvest_worker.py` is the agent that works.
