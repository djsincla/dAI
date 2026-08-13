# Serving a model that fits on no single machine

A plan. Step 1 is built; the rest is not.

## Where this stands

The split works and is measured. `SplitRunner` does pipeline parallelism -
layers divided, one hidden state per token across the boundary - and E7 ran a
72B across two Macs:

| Model | One machine | Split | Peak memory |
|---|---|---|---|
| 32B dense | 16.5 tok/s | 14.2 | 9.83 GB each |
| 72B dense | 7.3 tok/s | 6.3 | **21.31 GB each** |

Memory halves almost exactly. Throughput costs about 14% on the large dense
models, because with one request in flight the two machines run in sequence
rather than in parallel: the split buys capacity, not speed.

Not tensor parallelism, and that was measured too. It pays ~2 all-reduces per
layer per token, which is latency-bound, and the fleet's best link is 0.48 ms
(USB gigabit, faster than Thunderbolt's 0.85 ms for this purpose). E7's
conclusion inverts the intuition the name invites: Thunderbolt is a bandwidth
upgrade and would make tensor parallelism *slower*.

**What is missing is not the split.** It is everything that would let the fleet
start one:

- `Worker` has no reference to `SplitRunner`. The serving loop cannot start one.
- The control plane has no concept of a split model - not in `router.ts`, not in
  the serving routes, not in the schema.
- The only way to run one today is by hand, one process per machine:
  `dai-agent split <model-dir> <rank> <size> <peer>`.

`main.swift` says why, and it is the right reason:

> Wiring this into the fleet needs gang admission, which does not exist yet, and
> starting a pipeline without it would hand out work that hangs when one machine
> is missing.

## The tier split already exists for this

This is the part worth noticing before designing anything new. PLAN.md names
gang-scheduled split work as *the* reason there are two tiers at all: a job
spanning N machines dies if any one yields, and preemption is the entire premise
of harvesting.

That decision is already encoded:

- Creating a cluster pool sets `schedule = 'gang'` and `preempt = 'never'`
  automatically (`admin.ts:491`).
- `whyNotInPool` enforces the asymmetry deliberately: a cluster pool admits only
  cluster nodes, because never-preemptible is a property the work depends on and
  a harvest node cannot promise it at any memory ceiling or QoS. A harvest pool
  admits anyone, because a dedicated box is strictly more reliable.
- `router.ts` already exempts cluster nodes from presence gating, with the note
  that interactive serving needs a model still resident a minute from now, which
  the harvest tier cannot promise by design.

So `schedule = 'gang'` is written on every cluster pool and read by nothing. The
data model anticipated this work; the scheduler never caught up.

**Today there is no cluster pool at all.** The only pool is `overnight-harvest`,
harvest tier, and both machines are `tier = cluster`. That works - harvest pools
admit any node - but it means nothing in the fleet is currently gang-scheduled
or protected from preemption, including the interactive serving that `router.ts`
says belongs on cluster nodes.

## What has to be built

In dependency order. The UI is last and smallest, which is the opposite of where
the question usually starts.

### 1. Gang admission

`selectNode` returns one candidate or a refusal. It needs to be able to return a
*group*, reserved together or not at all.

**Decided: when a rank is lost, fail the request, release every member, and say
so loudly.**

The alternatives were considered and rejected. Holding the survivors and betting
the peer returns costs memory on machines doing nothing, for a bet nothing
bounds. Resuming on a replacement needs the lost rank's KV cache, which is not
transferable today and probably never worth making so.

The argument for failing is not that it is easy. It is that on a tier whose
definition is `preempt = 'never'`, this should not happen - and building recovery
machinery for it would be admitting the tier does not work. If ranks are being
lost, the answer is to find out why, which requires the failure to be loud rather
than absorbed.

Loud means: the request fails with a reason naming the machine that went, the
event is recorded against every member rather than only the one that failed, and
the fleet view shows a gang that broke rather than a request that was slow. A
silently retried gang failure is how a cluster tier quietly becomes a harvest
tier with extra steps.

**Built** (`selectGang` in `router.ts`): every rank is admitted together or none
is, only from cluster-tier machines, and only from within one group - machines in
a group have agreed what they serve, machines in different groups have not.
Ungrouped machines are not pooled with each other, because two machines nobody
put together have not been declared to agree either. A group already holding the
weights is preferred over one that would cold-load, since N cold loads is N times
the delay rather than one.

### 2. Residency as a set

`stored_models` maps a model to one machine, and `holdsModel` compares one
node's reported size against the catalogue's. A split model is held by a *pair*,
and the question becomes "does this pair hold it between them, with the right
ranks on the right machines".

That is a schema change and a change to every count that reads residency -
`nodesHolding`, `nodesWanting`, the placement view, the serving catalogue. Each
of those has already been wrong once today in the simpler single-machine case.

### 3. A model that declares its shape

The catalogue records size and context length. A split model needs to say what
it requires: how many machines, and how much memory each. Then the fleet can
answer which pairs could host it, and refuse the pairs that cannot, before
anybody assigns it anywhere.

This is also what makes the assignment gesture meaningful: assigning a
two-machine model to a pool with one eligible node should fail at assignment
time with a reason, not at dispatch with a hang.

### 4. `Worker` starting a `SplitRunner`

From a lease, rather than from a person at a terminal. This is where
`PipelineChannel` is finally used by something other than a test - it already
has TLS, SNI handling for IP literals, ordered frame delivery and a bounded
handshake, all of which exist because the by-hand path needed them.

The one open question here is who dials whom. Today the higher rank connects to
the lower, which the control plane would have to arrange: both machines need to
learn their rank, their peer's address, and the model, from the same dispatch.

### 5. The UI

By this point it is mostly display, and the gesture already exists. Assigning a
model to a pool is `PUT /admin/v1/pools/{poolId}/models/{modelId}`. A split
model is the same action against a cluster pool, with the control plane choosing
a pair that satisfies the model's declared shape.

The fleet view changes more than the assignment view: a split model is one row
spanning two machines, not two independent copies, and "which pair is holding
this" is a question the current layout has no place for.

## The smaller thing worth doing first

Create a cluster pool and move interactive serving to it.

That needs none of the above. It gives the fleet a never-preempted home for
serving, which `router.ts` already says is where serving belongs, and it makes
`schedule = 'gang'` real on at least one row before anything depends on it. It
also surfaces the question of which machines are genuinely dedicated - rotorua
is `tiers = ['cluster']`, orca is `['harvest', 'cluster']`, and that difference
is currently invisible in every view.
