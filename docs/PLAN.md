# dAI - Distributed AI on Harvested Apple Silicon

## Context

Idle Apple Silicon workstations represent large amounts of sunk, unused compute. The premise, borrowed directly from the second-GPU render farm: hardware that's already bought and idle 16 hours a day can be centrally scheduled to do useful AI work at a marginal cost of roughly electricity - and, critically, without data ever leaving the building.

The analogy breaks in one important place. The render farm worked because of *physical* isolation: a dedicated card the artist's session literally could not touch. Apple Silicon has unified memory - GPU, CPU, and ANE share one memory pool and one bandwidth budget with the artist's interactive work. Isolation must be **policy-enforced, not hardware-enforced**, which is a much weaker guarantee. Socially there's about one strike: one artist noticing their machine got slow will kill the program.

**The positioning is sovereignty and sunk cost, not price-performance.** Per-token, harvested Macs lose to both cloud APIs and rented GPUs; that argument is unwinnable. The winning arguments are that the marginal cost is electricity and that the data never leaves the premises.

**Target for this phase:** own fleet first. 2–5 Macs available. Deliverable is a validation spike with a decision gate, followed by the architecture it would justify.

---

## The core architectural decision: two tiers

Both desired workloads are wanted, but they cannot share nodes.

A split-model job spanning N machines is **gang-scheduled** - all N run in lockstep, and if any one yields because someone touched a keyboard, the whole job dies and every node's model load is wasted. Preemption is the entire premise of harvesting and the fatal flaw for split-model work.

That yields two tiers, not two features:

| | **Harvest tier** | **Cluster tier** |
|---|---|---|
| Hardware | Artist workstations | Dedicated boxes, racked |
| Preemptible | Yes, instantly | Never |
| Network | Whatever the building has | Thunderbolt 5 / 10GbE+, same switch |
| Scheduling | Independent work units | Gang, topology-aware |
| Workload | **B** - batch inference, embeddings, evals, LoRA sweeps | **A** - serving models too large for one box |
| Capacity | Swells overnight | Flat, reliable |

This also places NVIDIA DGX Spark correctly: it's a dedicated appliance, so it lands in the **cluster tier**, where there are few nodes and a second runtime (CUDA alongside Metal/MLX) is affordable. The harvest fleet stays homogeneous.

**Build order: harvest tier (B) first.** Roughly 80% of the work is shared - node agent, enrollment, capability probe, policy engine, model cache, job queue, observability. B exercises all of it under forgiving conditions on hardware already on hand.

**The one thing that must exist from day one:** the tier concept in the data model. Retrofitting "some nodes are never preemptible" into a scheduler built entirely around preemption is painful. Everything else about the cluster tier can wait.

---

## Runtime

Two different choices, deliberately.

**Phase 0 spike → Ollama.** MIT licensed (no ambiguity about org-wide deployment), runs natively as a headless background service, trivially scriptable across a handful of Macs. It produces E1–E4 numbers fastest and is disposable. Do not optimize the runtime before knowing the fleet concept works.

**Phase 1 product → MLX, via `mlx-swift`.** MLX is Apple's own framework (Apple ML Research, open source, built around unified memory) - this *is* the Apple-native path. The harvest agent needs two things a general-purpose inference server cannot give: a **hard memory ceiling** and **sub-second preemption**. Owning the process means preempt is a process kill and the ceiling is agent-enforced. General-purpose servers are designed to keep models *warm for a user* - the opposite requirement.

Use the **Swift bindings specifically**, so the node agent ships as a single signed binary with the runtime embedded. No Python environment to maintain across a fleet of Macs, no version drift, and much simpler notarization and MDM packaging.

**Core ML as a second, narrow runtime - the ANE angle.** Core ML is the *only* path to the Neural Engine, and the ANE is **separate silicon from the GPU**. An artist's Blender viewport, Resolve timeline, or Xcode build doesn't touch it. That makes ANE work the closest thing Apple Silicon offers to the original second-GPU isolation.

Limits: unified memory bandwidth is still shared, ANE is fp16/int8-oriented, and models must be compiled through Core ML - so it only suits fixed, small models. But that is exactly Tier 1 use cases #1 and #2 (embeddings, Whisper), and `whisper.cpp` already ships a Core ML encoder path for precisely this reason.

**If ANE workloads prove near-invisible to the interactive user, they can run during the working day rather than only overnight - roughly doubling usable fleet capacity.** Worth testing early (E5).

**Rejected as node runtimes:**

- **LM Studio Bionic** (Element Labs, July 2026) - an *agent application* (repo-aware coding, docs, voice) sitting on the LM Studio runtime, not a fleet primitive. Also single-machine, and can offload to LM Studio Secure Cloud, which is a data-egress path that contradicts the sovereignty thesis. Worth tracking as market validation and as adjacent competition if they ever add multi-machine features.
- **LM Studio runtime** - real MLX support and an `lms` CLI, but commercial deployment terms need verification and headless operation under `launchd` with no user session is unproven (it's a desktop app). That last point makes it a poor E1 subject.
- **Apple Foundation Models** (macOS 26) - ~3B fixed model, small context, cannot load custom weights, local-process-only with no network API. Possibly registerable later as a supplementary per-node capability for cheap classification, nothing more.

`llama.cpp` remains the fallback if MLX proves limiting for a specific model family.

---

## Target use cases (harvest tier)

A workload fits harvested Macs if it has most of: item-level parallelism with no inter-node communication · latency tolerance · work units completing in minutes · a model inside the memory *ceiling* · data sensitivity that makes cloud APIs unattractive · volume high enough that API cost hurts.

The memory ceiling - roughly half of unified memory, to be confirmed by E2 - drives everything:

| Machine | Unified | ~Takeable | Largest practical model (4-bit) |
|---|---|---|---|
| M-series base | 16 GB | ~8 GB | 7–8B |
| M4 Pro | 48 GB | ~24 GB | 32B |
| M4 Max | 128 GB | ~64 GB | 70B–120B |
| M3 Ultra | 512 GB | ~256 GB | unconstrained |

Embedding models (~1 GB) fit on every machine in the fleet. That asymmetry is why they rank first.

**Tier 1 - build first**

1. **Embedding generation / RAG index builds** - best overall fit, satisfies all six criteria. Sub-2B models load in seconds so preemption is nearly free; every document is independent; every node qualifies regardless of RAM. "Reindex the corpus nightly" maps directly onto the overnight capacity swell.
2. **Media transcription and diarization (Whisper)** - MLX Whisper is well-optimized, audio chunks into clean 30s units, archives are enormous, and this content is often contractually barred from cloud APIs.
3. **Batch classification / extraction / tagging** - document triage, media metadata enrichment, ticket routing, invoice extraction. 7–32B quantized, so most of the fleet qualifies; volume is where API bills hurt.
4. **Eval harness runs** - thousands of eval prompts across model variants. Embarrassingly parallel, latency-irrelevant, API-expensive. **Best dogfood case for an own-fleet v1.**

**Tier 2 - strong, one caveat each**

5. **LoRA fine-tuning sweeps** - MLX handles LoRA well, configs are independent. *Needs step-level checkpointing and the reliably-idle subset of the fleet.*
6. **Code intelligence over a monorepo** - nightly docstring refresh, per-file summaries for code search, dead-code detection. *Quality bar is high; small models disappoint.*
7. **Image/video ML** - upscaling, denoise, roto assist, generation batches. *Diffusion model zoo is thinner on Apple Silicon than CUDA.*
8. **Synthetic data generation** - *output quality tracks model size, so Max/Ultra nodes only.*

**Anti-patterns - reject explicitly**

- **Interactive chat or copilot serving on harvested nodes.** Requires a resident model and low latency; preemption is fatal. Cluster tier only. This is the most common trap.
- Models above the ceiling on the harvest tier.
- Training from scratch - wrong interconnect and bandwidth.
- Real-time or streaming anything.

---

## Phase 0 - Validation spike (1–2 weeks)

Minimum code, maximum signal. **No agent, no control plane, no UI.** A shared work queue (SQLite or Redis), a Python worker per Mac, and SSH. The point is to answer four questions that can kill or reshape the idea.

### E1 - Metal access from a background daemon (EXISTENTIAL, do first)

Can a `launchd` daemon run MLX inference on the GPU with the screen locked and no user session? Test all three states: user logged in but idle, screen locked, user logged out entirely.

*If GPU access requires an active user session, the entire premise changes* - you'd be limited to logged-in-but-idle machines, which is a much weaker product. This is a half-day test and it gates everything else. Do not skip it or defer it.

### E2 - Contention (the political question)

Run a fixed, repeatable interactive workload - an Xcode build, a scripted Blender viewport orbit, a Resolve render - with and without background inference, sweeping the memory ceiling (25% / 50% / 75% of unified memory).

**Sweep QoS as a second axis** (see E1 finding below): measure at both `Background` and `Standard` QoS. The question is no longer only "what memory ceiling is imperceptible" but "**is Background QoS imperceptible enough to run during the working day?**" A yes roughly doubles usable fleet hours.

Measure build wall-time and frame times. **Find the ceiling at which degradation becomes perceptible.** That number becomes the default policy and is the single most important output of the spike.

### E3 - Throughput and economics

Pick one embarrassingly-parallel job on a real corpus - batch embeddings or Whisper transcription. Run on 1 Mac, then all available Macs.

Compute aggregate throughput, scaling efficiency, and cost-equivalence against both current API pricing and an hour of rented GPU. The output is a defensible number, not a vibe.

### E4 - Preemption economics

Measure model load time into unified memory by model size; yield latency from user-input detection to released memory; resume cost after yield.

Derive the **optimal work-unit duration** - long enough to amortize the load, short enough to lose little on preempt. This directly determines the work-unit protocol design.

### E5 - ANE contention vs GPU contention

Repeat E2's interactive benchmark, but with the background workload running on the **ANE via Core ML** (Whisper encoder or an embedding model) instead of the GPU via MLX.

Measure the same interactive deltas. The hypothesis is that ANE work is materially less perceptible to the user because it doesn't compete for the GPU - only for memory bandwidth.

**If confirmed, this is the highest-leverage finding in the spike:** ANE workloads could run during working hours rather than only overnight, roughly doubling usable fleet capacity and softening the political problem substantially.

### Decision gate

Proceed to Phase 1 if:
- **E1 passes** - GPU reachable with screen locked (hard gate)
- **E2** shows a usable memory ceiling with no perceptible interactive degradation
- **E3** shows aggregate throughput worth the operational cost at your fleet's realistic scale
- **E4** yields a work-unit duration under ~10 minutes
- **E5** is upside, not a gate - but a positive result should reshape Phase 1 priorities toward Core ML/ANE workloads first

E1 failing means redesign, not iterate. E2 failing at every ceiling means the harvest tier is dead and only the cluster tier survives.

---

## Phase 1 - Architecture (harvest tier)

### Node agent

`launchd` daemon, Swift throughout - macOS integration is the whole job here: IOKit for thermal and power state, `NSWorkspace` for running-app detection, `CGEventSource` idle time for user activity, and clean unified-memory accounting. With `mlx-swift` embedded, this ships as one signed binary with no Python runtime on the fleet.

Responsibilities: enrollment and cert handling; capability probe; policy evaluation and yield; work-unit execution via MLX (GPU) or Core ML (ANE); model cache management; heartbeat and telemetry.

The capability probe must record **GPU and ANE capability separately**, since E5 may make them schedulable as distinct resources with different policies - ANE work permitted during working hours, GPU work overnight only.

### Control plane

Node registry with tier and tags · job queue · capability-aware scheduler · policy engine · model store.

Scheduling must be **capability-matched, not round-robin** - an M1/8GB and an M3 Ultra/512GB are a 64× memory spread.

### Work-unit protocol

Sized from E4. Idempotent, checkpointable, retryable on a different node. No filesystem access outside a sandboxed scratch dir. Signed by the control plane.

### Enrollment

For own-fleet, **join token only** - `curl … | sh -s -- --join <token>`, landing in a pending-approval queue. Never auto-trust a node that presents a token; approval issues a signed cert.

Structure the config as a declarative profile from the start so MDM push (Jamf/Kandji/Mosyle) is a later delivery mechanism rather than a rewrite.

### Policy engine

Yield triggers (keyboard/mouse, screen unlock, named apps launching, sustained CPU/GPU load) · memory ceiling (absolute GB or % of unified memory) · time windows · power and thermal gates (AC only, skip when throttling) · grace period before resuming.

**Dynamic QoS is a first-class policy axis, not a static setting.** E1 measured `ProcessType: Background` costing ~2.4× GPU throughput (~3183 vs ~7830 GFLOPS). Background QoS is the mechanism that makes the agent polite, but paying it overnight when nobody is at the machine wastes more than half the available capacity. The agent should promote itself:

- User present (logged in, recent input) → `Background` QoS
- Confirmed idle (screen locked, no input for N minutes, on AC) → `Standard`/`Adaptive` QoS

Combined with the GPU/ANE split, that gives two independent politeness dials - QoS level and compute unit - which together decide whether daytime harvesting is viable at all.

**Memory ceilings must sit under Metal's own.** `max_recommended_working_set_size` on the 64 GB M2 Max is 51.8 GiB (~81% of unified memory), already well below total RAM. The agent's ceiling is a fraction of *that*, not of installed RAM.

Policy edits should preview their blast radius before saving: *"41 of 63 machines eligible, 2.9 TB aggregate unified memory."*

### Pools

Steal render farm vocabulary wholesale - pools, groups, priority, limits. Tags auto-derived from hardware (`mem>=64`, `chip=m-ultra`) plus manual role tags (`edit-bay`, `overnight-only`). Jobs request pools; pools are tag queries. The tier lives on the pool, and the scheduler branches on it:

```yaml
pools:
  overnight-harvest:
    tier: harvest
    members: chip=m-series AND mem>=32
    schedule: independent-units
    preempt: on-user-activity

  serve-cluster-a:          # Phase 2
    tier: cluster
    members: [studio-01..06]
    topology: thunderbolt-ring
    schedule: gang
    preempt: never
```

### Control UI

CLI first; a read-only web dashboard second. Don't over-invest before the spike lands.

Fleet view columns that do real work: **unified memory** (primary capability constraint - belongs next to the name), **headroom** (what's takeable *right now* under policy, not total RAM), **idle pattern** (24h availability histogram - answers "can I schedule 8 hours here?"), **yields/7d** (reliability signal and early warning that a policy is too aggressive).

Headline overview graph: aggregate eligible unified memory over 24 hours. The overnight swell as machines free up *is* the value proposition made visible.

### Artist-side menu bar app

Not optional, even on your own fleet - build the habit now.

1. **Pause button that always works, with no admin override.** The moment IT can force-run, you're malware in the user's mental model.
2. **Activity log** - what ran, when, how much memory, when it yielded. Without it, every unrelated slowdown gets blamed on you.
3. **Contribution counter** - cheap to build, and does most of the political work of reframing "IT took my machine" as "I contribute to the farm."

---

## Phase 2 - Cluster tier (deferred)

Adds topology discovery and verification, collective comms (ring/MPI over Thunderbolt), gang admission control, and a serving front-end. Additive, not a rewrite, provided the tier concept ships in Phase 1's data model.

**Verify before committing:** benchmark a Thunderbolt-5 ring against a single M3 Ultra/512GB for the models actually of interest. If one big box wins, the cluster tier's justification narrows to models above ~500GB - a much smaller target, and possibly a reason not to build it at all.

---

## Verification

**Phase 0** is itself the verification, and its outputs are numbers, not code:

- E1 - a table of GPU-accessible vs. not across three session states
- E2 - interactive benchmark deltas per memory ceiling, and the chosen default
- E3 - aggregate throughput, scaling efficiency across N Macs, cost-equivalence vs API and rented GPU
- E4 - model load time by size, yield latency, derived work-unit duration

**Phase 1** end-to-end: enroll 2 Macs via join token → approve both → capability probe populates their profiles → submit a batch embedding job over a real corpus → confirm work distributes by capability → sit down at one machine and type → confirm it yields within the target latency and its units re-dispatch to the other node → confirm the job completes with correct, complete output → confirm the menu bar pause button stops work immediately and the activity log reflects everything that happened.

That last sequence is the real acceptance test. If yield-and-redispatch works cleanly under a human actually using the machine, the harvest tier is real.

---

## Open questions

- Control plane language - Swift is settled for the agent, but the control plane is free. Go or Python both fine; pick for operational familiarity.
- Whether the first real corpus is documents, media, or code. This decides which Tier 1 use case drives E3, and it's the one input still missing.
