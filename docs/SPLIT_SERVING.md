# Serving a model that fits on no single machine

**Built, and running.** A request on a group's socket is answered by two
machines holding half a model each.

    rotorua  rank 0 listening on 7710
             peer connected from 192.168.99.2
             handshake completed                     1 second
             rank 0 (layers 24..<48) finished 8 tokens in 4.4s

    orca     rank 1 connected to 192.168.99.1
             handshake completed
             rank 1 (layers 0..<24) finished 8 tokens in 4.4s

Qwen2.5-14B, 48 layers divided 24/24, one hidden state per token over a
Thunderbolt bridge, 4.5 seconds for the whole request including the model load.
The answer came back on port 8461 - the socket `split-cluster` was allocated
when it was created.

## What the split is

Pipeline parallelism: layers divided, one hidden state per token across the
boundary. E7 measured it across two Macs before any of the fleet machinery
existed:

| Model | One machine | Split | Peak memory |
|---|---|---|---|
| 32B dense | 16.5 tok/s | 14.2 | 9.83 GB each |
| 72B dense | 7.3 tok/s | 6.3 | **21.31 GB each** |

Memory halves almost exactly. Throughput costs about 14% on large dense models,
because with one request in flight the two machines run in sequence rather than
in parallel: **the split buys capacity, not speed.**

Not tensor parallelism, and that was measured too. It pays ~2 all-reduces per
layer per token, which is latency-bound, and the fleet's best link is 0.48 ms
(USB gigabit, faster than Thunderbolt's 0.85 ms for this purpose). E7's
conclusion inverts the intuition the name invites: Thunderbolt is a bandwidth
upgrade and would make tensor parallelism *slower*.

## What it took to get from that to a fleet

Every step below is built and proven on hardware.

1. **Gang admission.** `selectGang` admits every rank together or none, from
   cluster-tier machines in one group, preferring a group that already holds the
   weights. A gang that loses a rank fails the request, releases every member
   and says which machine went - and now fails as soon as the first rank reports
   rather than waiting out a machine that has gone to sleep.
2. **A model that declares its shape.** `machines` and `min_memory_gb` on the
   catalogue, checked at assignment: a two-machine model assigned to a group
   with one is refused with a sentence, not discovered at dispatch as a hang.
3. **The serving model belongs to the group.** It reaches the machine on the
   heartbeat it already sends, and the agent swaps its runtime to match. Before
   that a node ran whatever argument its daemon was started with, so a group
   could declare one model while its machines ran two others.
4. **Suspension.** A machine holding part of a split is not available to its
   harvest group while it holds it, because a gang cannot be preempted and
   harvest membership is the promise that it can be.
5. **The peer link.** mTLS between nodes, pinned to the node CA, over whatever
   link the machines share - declared by the node, because only it knows which
   of its interfaces its peers can reach.

## What the last mile actually was

Not the handshake, which was the standing theory for a day. The Secure Enclave
key works as a TLS server and the handshake takes about a second. Two other
things were making it look like a protocol failure:

**A leaked listener.** `runSplit` never closed its channel, so rank 0 held 7710
for the life of the daemon. Every attempt after the first could not bind - and
the dialer connected to the corpse of the first listener and completed a
handshake with it. A leaked listener does not merely waste a port; it answers.

**A peer that kept going away.** orca is a MacBook Pro, and a laptop sleeps on
lid close whatever power assertions are held. The Thunderbolt bridge goes
inactive when its peer sleeps, so the address the fleet had on record stopped
being reachable mid-handshake.

Both are handled rather than hidden now: the node reports having no pipeline
address the moment its link goes, a gang with nowhere to dial is refused in
milliseconds rather than attempted, a broken gang fails in seconds rather than
ten minutes, and a link that goes quiet mid-handshake says so after ten seconds
instead of two minutes.

**A split still needs both machines awake for its duration.** That is a property
of the hardware, not something the fleet can promise around.

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

## How it was built

In dependency order. Kept because the order turned out to matter: each step was
unreachable until the one before it existed.

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

Who dials whom is arranged by the control plane rather than inferred: each rank
is told whether to listen or to dial, which port, where its peer is, and which
model, all in the same dispatch. Nothing is derived from the rank number,
because that kind of implicit agreement survives right up until somebody
renumbers the ranks. A dialer with nowhere to dial is refused rather than
started.

The listening rank closes its channel when the split ends, however it ends. It
did not at first, and the consequence was worth writing down: it held the port
for the life of the daemon, the next split could not bind, and the dialer
connected to the corpse of the first listener and completed a handshake with
it.

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
