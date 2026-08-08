# dAI Control Plane - specification

Everything here is grounded in the Phase 0 spike (`spike/*/FINDINGS.md`). Where a
design choice exists only because a measurement forced it, the measurement is
cited - those are the parts not to "simplify" later.

## 1. What runs where

The split is not a preference. **Node agents cannot be containerised.** Docker on
macOS runs a Linux VM with no Metal, no ANE, and no IOKit, which makes every
mechanism the spike depends on unreachable: GPU execution, `MLComputePlan` ANE
placement verification, `HIDIdleTime`, `pmset` assertions, and `ProcessType` QoS.

| | Node agent | Control plane |
|---|---|---|
| Host | macOS, native | Linux, containerised |
| Language | Swift + `mlx-swift` | TypeScript (Node) |
| Delivery | signed binary, MDM or join token | container image |
| Identity | client certificate | user session |
| Depends on | Metal, ANE, IOKit, launchd | Postgres, object store |

TypeScript for the control plane because the UI is the dominant surface - fleet
views, pool management, RBAC screens, activity logs - and shared types across the
API boundary is a real saving. The scheduler is I/O-bound (lease units, collect
results), not CPU-bound, so the runtime suits it. Go would be the alternative if
a single static binary mattered more than UI velocity.

## 2. Data model

### Node

| Field | Notes |
|---|---|
| `id`, `name`, `hostname` | |
| `chip`, `memory_gb`, `os_version` | from enrollment probe |
| `metal_working_set_gb` | E1: Metal self-caps at ~81% of unified memory. Ceilings are fractions of *this*, never of installed RAM |
| `tier` | `harvest` \| `cluster` |
| `state` | `pending` \| `active` \| `cordoned` \| `offline` |
| `owner_user_id` | drives the un-overridable pause right (§4) |
| `cert_fingerprint`, `enrolled_at` | |
| `presence_state`, `last_heartbeat` | reported by the agent |
| `capability_profiles` | **map of workload class → measured throughput**, not a scalar |

`capability_profiles` is a map because E3 measured the same two machines
differing **7.5% on a 1.5B model and 26.3% on a 7B** - relative capability moved
3.5x from model size alone, and neither figure matched the 47% their memory
bandwidth ratio predicted. A single stored capability number misallocates by
20-40% depending on workload. It is also why chip generation and core count must
never be used to rank nodes: the newer M4 Pro is the *slower* machine here.

Profiles are derived from completed work, never declared.

### Pool

| Field | Harvest | Cluster |
|---|---|---|
| `tier` | `harvest` | `cluster` |
| `membership` | tag query (`chip=m-series AND mem>=32`) | explicit pinned list |
| `schedule` | `independent-units` | `gang` |
| `preempt` | `on-user-activity` | `never` |
| `topology` | - | required interconnect + measured admission (§6) |
| `priority`, `limits` | ✓ | ✓ |

The two tiers are not configurations of one thing. E6 measured the same code
swinging **0.95 scaling efficiency for independent units against 1.4% of a single
machine for tensor-parallel**, on the same network - a ~70x swing from workload
shape. Harvest is interconnect-insensitive; cluster is interconnect-defined.

### Job and WorkUnit

| WorkUnit field | Notes |
|---|---|
| `job_id`, `kind` | `kind` is negotiated, see §5 |
| `payload`, `result` | |
| `state` | `pending` \| `leased` \| `done` \| `failed` |
| `lease_node_id`, `lease_expires_at` | **required** - see below |
| `attempts` | |

**Leases must expire.** The spike coordinator holds in-flight units in memory
with no timeout, so a node that vanishes strands its units permanently - which
happened during cluster testing when `orca` dropped off the network mid-run.
Production requires a lease TTL with automatic requeue.

### Policy

The per-presence-state table, attachable to a pool with per-node override. Values
are E2 measurements, not estimates:

| State | GPU | ANE | QoS | duty_max | mem_frac |
|---|---|---|---|---|---|
| ACTIVE | ✗ | ✓ | background | 0.00 | 0.00 |
| PASSIVE | ✗ | ✓ | background | 0.00 | 0.15 |
| IDLE | ✗ | ✓ | background | 0.00 | 0.35 |
| LOCKED | ✓ | ✓ | standard | 1.00 | 0.70 |
| ABSENT | ✓ | ✓ | standard | 1.00 | 0.85 |

Two constraints the UI must encode, because both are counter-intuitive enough
that someone will otherwise "fix" them:

- **`mem_frac` is not a politeness dial.** E2 measured a 32 GB load disturbing a
  viewport *less* than an 8 GB one at identical duty. Footprint governs what
  fits; occupancy governs disturbance. The editor should not present it as a
  gentleness slider.
- **ANE work is exempt from QoS and duty throttling.** E5 measured it as
  indistinguishable from no load, and background QoS costs ~26x on bursty work.
  Throttling it buys politeness that is already free - that bug cost 50x
  throughput in the worker before it was caught.

## 3. Identity

**Two separate systems. Do not merge them.**

- **Nodes** authenticate with client certificates issued at enrollment approval.
  An enrolled Mac is not a user and has no role.
- **Humans** authenticate with sessions (OIDC against the existing IdP where one
  exists; local accounts otherwise).

Enrollment never auto-trusts a token bearer. A joining node lands in `pending`
with its hardware fingerprint; an admin promotes it, and only then is a
certificate issued.

## 4. Authorization

Pool-scoped role bindings: `(group, role, pool)`.

| Role | Permissions |
|---|---|
| `viewer` | Read fleet state, job status, own machine's activity log |
| `operator` | Submit/cancel jobs, drain and cordon nodes, set pool priority |
| `admin` | Enroll/remove nodes, edit policy, manage role bindings |

```
(vfx-artists,      viewer,   overnight-harvest)
(render-wranglers, operator, overnight-harvest)
(ml-team,          admin,    serve-cluster-a)
```

### The owner right sits outside RBAC

**A machine's owner can always pause it, and no role can override that.** Not a
permission - a hard-coded property of `Node.owner_user_id`. The moment an
operator can force work onto someone's Mac, the agent is malware in that
person's mental model, and the plan's one-strike social constraint is lost.

The same applies to the agent's local menu bar control: it must work with the
control plane unreachable.

### Activity log is owner-readable by default

Every node's activity log - what ran, when, how much memory, when it yielded -
is readable by its owner regardless of role bindings. Without it, every unrelated
slowdown gets blamed on the agent and there is no way to disprove it.

## 4a. Node security

### Threat model

| Threat | Consequence | Control |
|---|---|---|
| Rogue node joins the fleet | Sees work sent to it; data exfiltration | Enrollment approval, per-node certificate |
| Node certificate copied to another machine | Impersonation, work redirected | Secure Enclave key binding, short-lived certs |
| **Rogue control plane** | **Arbitrary work dispatched to every Mac in the building** | **mTLS both directions, pinned CA** |
| Work or results tampered in transit | Corrupted output, poisoned capability data | TLS, signed work units |

The third row is the one that matters most and it is the one certificates alone
do not solve. A node that authenticates *itself* but does not verify *the server*
will accept work from anything that can reach it on the network. Since a work
unit tells a node what to execute, that is remote code execution across the
fleet. **Authentication has to be mutual, and the node has to pin the CA.**

### Certificates

- Issued at enrollment **approval**, never on token presentation. A joining node
  lands in `pending` with its hardware fingerprint and receives nothing until an
  admin promotes it.
- **Private keys generated on-device and stored in the Secure Enclave**, marked
  non-exportable. A certificate copied off the disk is then useless without the
  hardware that holds the key, which is what turns "stole a file" into "stole the
  machine".
- **Short-lived, automatically rotated.** Long-lived credentials on laptops that
  leave the building are the wrong default. Rotation failure should degrade to
  "stops getting work", not "keeps working forever".
- **Revocation is immediate and checked on every lease**, not cached. A stolen
  laptop must stop receiving work the moment it is reported, and node identity is
  cheap to check because the agent is already talking to the control plane.

### Work units must not be able to carry code

This is the containment that matters if the control plane is ever compromised. A
work unit references a model by **content hash** from a signed catalogue and
carries **data only**. It cannot name an interpreter, a path, or a shell command.

The blast radius of a compromised control plane then becomes "runs an approved
model over attacker-supplied data" rather than "executes arbitrary code as the
logged-in user on every Mac in the building". That is a large difference and it
costs nothing to design in now, whereas retrofitting it means changing the
protocol after agents are deployed.

Models are verified by hash before load. A catalogue entry that does not match
its hash is refused, so a compromised model store cannot substitute weights.

### TLS everywhere, including locally

The agent talks to a configured endpoint over TLS from the first deployment, even
when that endpoint is on the same machine. A local deployment that starts on
plaintext HTTP grows an unauthenticated agent API that is then hard to close, and
"we will add TLS later" is how the fleet ends up with a permanently open
dispatch endpoint.

### What the owner keeps regardless

None of the above can be used to override the local pause control (§4). The
agent's menu bar stop must work with the control plane unreachable, with an
expired certificate, and against an admin who wants the machine working. A
security model that lets the fleet operator overrule the machine's owner is the
one that ends the programme.

## 5. Agent API

Separate surface from the human API: different auth (mTLS vs session), different
rate limits, different availability requirements.

**API first.** The OpenAPI document is the source of truth, not a description
written after the fact. Server handlers, the TypeScript client, and the Swift
agent client are all generated from it, and the contract tests in §8 run against
the schema. That matters more than usual here because the two ends are written in
different languages by different toolchains: the schema is the only artifact they
share, so it is the only place a mismatch can be caught before deployment.

```
POST /agent/v1/enroll                 join token  -> pending node
GET  /agent/v1/policy                 current policy for this node
POST /agent/v1/heartbeat              presence state, health, capability samples
GET  /agent/v1/work?kinds=embed,...   lease a unit of a servable kind
POST /agent/v1/work/{id}/result       completed items + unfinished remainder
```

Two protocol properties the spike proved necessary:

**Work is typed and the agent advertises what it may run right now.** Permitted
work changes with presence state: GPU work is legal only in LOCKED and ABSENT,
ANE work in all five. Without `?kinds=`, an agent fetches work it must
immediately hand back. With it, a logged-in machine drains the ANE queue while
the GPU queue waits - measured as `{generate: 100, embed: 100}` going to
`{generate: 100, embed: 0}`.

**Results carry an unfinished remainder.** A harvest agent yields *between items*,
not between units, and returns what it did not reach for requeue at the head of
the queue. Verified across a real screen lock: `YIELD -> ACTIVE; 2 done, 6
returned`. Without this a yield costs a whole batch.

## 6. Scheduling

### Harvest tier

Pull-based, and deliberately so: harvested machines come and go, and a scheduler
that must reach *into* them needs credentials and reachability it will not
reliably have.

E3 found **pull dispatch is self-balancing** - fast nodes simply ask for work
sooner - and that capability weighting is a second-order correction on top. At a
7.5% capability spread the weighting rounded to no change at all, and the
observed 324/276 split came from self-pacing. Weighting earns its keep on wide
spreads (an 8 GB node beside a 512 GB one), not on similar machines.

Residual loss is a 7-8% straggler tail from fixed batch sizing. Tapering batch
size as the queue drains would recover most of it.

### Cluster tier

Gang admission: a job runs only when **all** members are present, and any node
dropping fails the whole job. No preemption, ever.

Pools must pass measured admission before serving (`spike/cluster/admit.py`):

- **Interconnect.** Tensor parallelism all-reduces after every attention and MLP
  block - ~56 round-trips per token on a 28-layer model. Measured all-reduce
  swung 16.687 ms (WiFi) to 0.563 ms (gigabit), a 30x throughput swing. Latency,
  not bandwidth, binds at generation time.
- **Capacity.** `N x smallest_node / 1.27`. Every rank transiently holds ~1.27x
  its slice during load, and **`lazy=True` is mandatory** - eager loading peaks
  at 5.01 GB against a 3.99 GB model, so a fleet would OOM on exactly the model
  the extra machines were bought for.
- **Projected throughput uses a 0.37 realisation factor.** The comm-only ceiling
  predicted 31.72 tok/s where reality delivered 11.69. Admitting on the raw
  ceiling would promise 2.7x what the pool serves.

**Admission must also refuse a model that fits on one node.** Sharding costs 6.6x
throughput (11.69 vs 77.46 tok/s) to save 43% of per-node memory. The tier exists
to run models larger than any single machine - that is its benefit, and outside
that case it is strictly worse than not splitting.

## 7. UI

Fleet view columns that carry information, from the spike:

| Column | Why |
|---|---|
| Unified memory | The binding capability constraint; belongs beside the name |
| Headroom | What is takeable *now* under policy - not total RAM |
| Presence state | ACTIVE/PASSIVE/IDLE/LOCKED/ABSENT |
| Idle pattern | 24h availability histogram: "can I schedule 8 hours here?" |
| Yields / 7d | Reliability signal, and early warning a policy is too aggressive |

Headline graph: **aggregate eligible capacity over 24 hours**, split by GPU and
ANE. The overnight swell as machines lock is the value proposition made visible -
and the ANE band showing daytime capacity is what E5 bought.

Policy editing shows blast radius before saving: *"41 of 63 machines eligible,
2.9 TB aggregate."*

## 8. Testing

Non-negotiable, and the spike says why: **six separate measurements failed
optimistically before being caught** - `lazy=True` hiding load cost, page cache
faking disk speed, vsync faking frame times, a single baseline manufacturing a
finding that had to be retracted, background QoS measured on the wrong workload
shape, and a microbenchmark ceiling 2.7x above reality. Every one looked
plausible and every one flattered the system. Assume that rate continues.

### The policy core is pure, and must stay that way

`signals -> state -> policy` is already three pure functions
(`read_signals`, `classify`, `effective_policy`). That is the highest-value
seam in the system: every policy bug found in the spike was reproducible from a
recorded signal dictionary alone, with no hardware involved.

Keep hardware behind narrow interfaces so tests inject fixtures:

| Interface | Real | Test double |
|---|---|---|
| `SignalSource` | `ioreg` / `pmset` / `stat` | recorded JSON fixtures |
| `Runtime` | MLX or Core ML | deterministic stub |
| `Clock` | monotonic | controllable, for hysteresis |

### Every bug found becomes a regression test

These are the cases, drawn from real captures:

| Test | Guards |
|---|---|
| `sharingd` holds a permanent Handoff assertion | Machine must not be pinned in PASSIVE forever |
| `caffeinate` holds `PreventUserIdleSystemSleep` | Must **not** block GPU work - sleep assertions are not a contention signal |
| Safari/`coreaudiod` system assertions | Same; these are permanent on a normal machine |
| Video call holds `PreventUserIdleDisplaySleep` | Must classify PASSIVE - a real human is watching |
| `hid_idle_s` unreadable (returns `None`) | Must fail closed to ACTIVE, never to ABSENT |
| ANE work under any state | Must never be QoS-throttled or duty-limited |
| GPU work in ACTIVE/PASSIVE/IDLE | Must be refused at every duty and QoS |
| Idle for 89s, then 91s, then 301s | Promotion requires sustained condition; demotion is immediate |

That last one is the hysteresis invariant and deserves property-based coverage:
**for any signal sequence, a transition toward ACTIVE applies on the first
sample, and a transition away requires the condition to hold for
`promote_after`.** Asymmetry is the whole design, and it is easy to break while
refactoring.

### Contract tests on the agent API

The agent is Swift and the control plane TypeScript, so the protocol is the only
shared artifact. Test it from both sides against a recorded contract:

- `?kinds=` negotiation: a worker advertising only `embed` never receives
  `generate` work
- partial results: `{count: 2, unfinished: [6 items]}` requeues exactly 6, at the
  head
- lease expiry: a node that stops heartbeating has its units requeued, and a late
  result from that node is rejected rather than double-counted
- enrollment: a token bearer lands in `pending` and receives no certificate until
  approved

### Integration tests use the real control plane

No mocked coordinator in agent tests. Run the real service against a throwaway
database with a fake `SignalSource`, and drive presence transitions
deterministically. The spike's yield behaviour was only trustworthy because it
was verified against a genuine `PreventUserIdleDisplaySleep` assertion and a real
screen lock, not a stub.

### Benchmarks are tests

Two spike bugs were performance bugs that no correctness test would catch:
presence polling costing 4x the work it guarded, and ANE work run under
background QoS. Both are assertions about ratios, so write them as such:

- presence sampling must cost `< 10%` of a work item
- ANE throughput with a user present must be within `10%` of throughput with the
  machine locked (measured: 30.2 vs 31.1 items/s)

### Out of scope for CI

Metal execution, ANE placement, and real presence signals need Apple Silicon.
Those run on a self-hosted macOS runner against the fixture-free path, on merge
rather than per-commit. Everything above runs anywhere.

## 9. Deployment

**The control plane is platform-independent and deploys anywhere.** Browser UI,
containerised service, Postgres. Nothing in it is macOS-specific - all Apple
platform dependence lives in the node agent, which is precisely why the split
in §1 is drawn where it is.

### Now: local

Initial deployment is on `rotorua` alongside the agent. They are separate
processes with no shared state, and the control plane is I/O-bound, so it does
not meaningfully compete for the GPU it is scheduling.

```
docker compose up      # control plane + postgres
```

Two things to get right even in a local deployment, because retrofitting them is
painful:

- The agent talks to a **configured endpoint**, never `localhost`. The moment a
  second machine joins, `localhost` breaks - and the spike already hit exactly
  this when `launchd` plists carried absolute paths.
- mTLS is on from the start. A local deployment that skips certificates grows an
  unauthenticated agent API that is then hard to close.

### Later: anywhere

Same image on a Linux host, a VM, or a managed container service. The only
requirement is that agents can reach it and it can reach Postgres. Nothing about
the fleet needs to move.

## 10. Migration from the spike

`spike/e3_fleet/coordinator.py` already implements the protocol shape: typed
queues, `?kinds=` negotiation, partial results with requeue, and capability
estimates derived from completed work. The control plane reimplements that
contract with persistence, auth, and lease expiry - the wire protocol carries
over largely unchanged.

Order of work:

1. Persistence + lease expiry (the spike's fatal gap - units strand when a node
   vanishes, observed live)
2. Agent API with mTLS and the enrollment approval queue
3. Human API + RBAC
4. UI: fleet view, then pools, then policy editor
5. Cluster tier: admission gate, gang scheduling, serving front-end

## 11. Open questions

- **Node loss is tolerated rather than prevented - deliberately, for now.**
  `orca` vanished twice during this work, once asleep and once from a flat
  battery, and a gang-scheduled job dies when any member goes.

  Admission does **not** gate on AC power or disabled sleep. On laptops in active
  use that requirement would make the cluster tier unusable, and this is a
  development fleet. It is recorded here as a production consideration, not a
  current rule.

  The consequence is a design obligation, not a shrug: since node loss is not
  prevented, the gang scheduler has to **handle it cleanly** - detect a member
  going away, fail the job with a specific reason rather than hanging, release
  the pool, and requeue rather than strand. That is stricter than what the spike
  coordinator does today, where in-flight units are held in memory with no
  timeout and a vanished node's work is lost permanently. Lease expiry (§2)
  covers the harvest tier; the cluster tier needs the equivalent at job
  granularity.

  When this fleet moves to dedicated hardware, revisit: AC power and no-sleep as
  admission requirements, plus health checks that fail a pool *before* work is
  dispatched onto it.
- **Model distribution.** Every node needs weights before it can work. Not
  designed. On a large fleet this is the dominant network cost and probably wants
  peer-to-peer distribution rather than N pulls from a store.
- **Result storage.** Work units currently return small payloads; embedding jobs
  return vectors at volume and need somewhere to land.
- **Multi-tenancy beyond pools.** Whether two teams sharing a pool need quota
  isolation, or whether pool-per-team is sufficient.
- **`mem_frac` direction.** Three observations now suggest larger working sets
  disturb *less* (E5 run 1, E2 sweep) rather than more. Not established, and it
  does not change policy - but nobody should reason from footprint until it is
  settled.
