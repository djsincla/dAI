# Groups, and the socket a client points at

A design note. Nothing here is built yet; the pieces that already exist are
marked.

## The model

Apple Silicon workstations are pooled into **groups**. A group is either
**harvest** - machines borrowed from the people sitting at them, preempted the
moment somebody touches a keyboard - or **cluster** - dedicated machines that
are never preempted.

**A machine may be in one cluster group and one harvest group, and no more than
one of each.** It can be in both at once, or in neither.

Models are assigned to a group, and the machines in that group hold and load
them. **Each group listens on its own socket**, so a client selects the group it
is talking to by the URL it points at, and nothing else.

## What already exists

- `pools.tier IN ('harvest','cluster')`, with `schedule` and `preempt` set from
  the tier at creation: cluster gets `gang` and `never`, harvest gets
  `independent-units` and `on-user-activity`.
- `whyNotInPool` refuses a harvest node entry to a cluster group. Never
  preemptible is a property the work depends on and a workstation cannot promise
  it at any QoS.
- `pool_models` assigns models to groups; `assignedModels` gives a node the
  union across the groups it is in.
- Role bindings are already group-scoped, which is what makes the authorisation
  rule below implementable rather than new.
- The server already separates surfaces at the listener rather than only by
  path: `AGENT_PORT` runs the worker API on its own port so it can be firewalled
  independently. Per-group sockets is the same move one level down.

The code says "pool" and the interface says "group". Keep the interface word;
renaming the tables buys nothing.

## What has to be enforced

**One group of each tier per machine.** Not enforced today, and not a detail.
`poolMode` returns `rule` whenever a group pins no explicit members, so a node
currently matches *every* group whose rules it satisfies. With one group that is
invisible. With three harvest groups a machine is silently in all of them.

The constraint is what makes a socket per group coherent: if a machine could be
in two harvest groups, a request arriving on either socket could land on the
same machine, and "which group answered" stops having an answer.

## Sockets

**Built.** Allocated from a range, bound when a group is created, and shown
wherever the group is.

The port is on the group's row (`pools.serving_port`, unique), returned by
`POST /admin/v1/pools`, listed by `GET /admin/v1/pools`, printed in the toast
that confirms a group was made and on the group's card in the fleet view. The
range defaults to 8460-8499 and moves with `DAI_GROUP_PORT_RANGE=from-to`, which
is refused rather than silently defaulted if it cannot be read.

A group socket serves the OpenAI-compatible routes and nothing else. Admin
belongs in one place however the fleet is divided, and an agent talks to the
control plane rather than to a group; mounting admin on forty sockets would be
forty more doors to the same room.

**Scope comes from the port, not the request.** A request arriving on a group's
socket is answered for that group's machines only - `/v1/chat/completions`,
`/v1/models` and the LM Studio shape all narrow the same way. Nothing in the
request names a group, so nothing in it can name the wrong one, and "no capacity"
on a group's port means that group has none rather than that the fleet does. A
group whose row has been deleted narrows to nothing rather than widening back to
the fleet.

Consequences, as designed:

**Creating a group fails at bind rather than half-succeeding.** If the port is
taken by something else on the host, the row is removed and the creation is
refused with the reason. A group that existed and refused connections would be
worse, because only the refusal says so.

**Every group's listener is rebound at startup.** One that cannot be is reported
loudly rather than logged: `/monitor/v1/health` answers 503 naming the group and
the port it is not answering on. The dangerous case is a group that exists, has
models assigned, has machines holding them, and answers nothing - a control
plane that called that healthy is why nobody would notice.

**Running out of ports refuses the group.** The range is small enough to
enumerate on purpose; a fleet with more than forty groups has a naming problem
rather than a port problem. The refusal says which range is full and what to
widen.

**TLS is unaffected.** One certificate covers every port on the same host.

Still open: **deleting a group has to close its listener**, and the port should
not be reused immediately by the next group created, or a client left pointing at
the old URL silently starts talking to a different group. There is no delete
route today, so allocation takes the lowest free port; the day one is added, the
port has to be held back rather than handed straight on.

## What the interface has to show and do

**Assigning a model to a group already works.** The Models view has a
"Push to workstations" drawer that lists every group with its tier and pushes or
stops pushing per group - `PUT` and `DELETE` on
`/admin/v1/pools/{poolId}/models/{modelId}`. Its own wording is precise about
what that means: *declares that every machine in the pool should hold these
weights*. So per-group **holding** is done.

What is not done is the distinction that matters once a machine can be in two
groups: holding is not loading. See the open question at the end.

**The port has to be visible.** A socket per group is only useful if somebody
can find out which socket, so the number a group is allocated at creation has to
appear:

- On the group itself, beside its tier. `card(g.pool.name, "<tier> tier, <mode>",
  ...)` in the groups view is where it belongs, because that is the line
  somebody reads to understand what a group is.
- At creation, in the response and in the confirmation, since the whole point of
  allocating at creation is that the operator learns it then rather than looking
  it up later.
- In the push drawer, as the URL to point a client at. Somebody assigning a
  model to a group is one step away from wanting to use it, and
  `https://host:PORT/v1` is the thing they need next.

A bound socket and an allocated-but-not-listening one must be told apart in the
interface, for the reason given above: a group whose models are assigned, whose
machines are holding them, and which nothing answers should not look like a
working group.

## The socket is routing, not permission

The rule that has to hold, stated plainly because it is easy to lose:

> The port a caller connects to selects which group serves them. It does not
> establish that they are allowed to.

Anyone who can reach one port can reach another. If group membership is enforced
only by which socket the request arrived on, a caller entitled to harvest
capacity points at the cluster socket and takes dedicated hardware. The API key
still has to be checked against the group, on every request, exactly as it is
checked today.

Role bindings are already group-scoped, so this is a lookup that exists rather
than a mechanism to invent.

## What a machine in both groups serves

**Two groups that share a machine must serve the same model.**

That removes the ambiguity rather than resolving it case by case: a machine can
only load one model, so the two groups it belongs to are not allowed to disagree
about which. What the tier distinguishes is then no longer *capability* but
*availability* - identical weights, identical answers, different promises:

| socket | promise |
|---|---|
| cluster | never preempted, no completion cap |
| harvest | may answer 503 the moment somebody touches a keyboard; `maxCompletionTokens` applies |

A caller chooses its service level by which URL it points at, which is a better
separation than the alternative where the tier accidentally decided which model
you got.

### It needs a serving model to be a thing

`pool_models` lets a group hold many models, so "the same model" has no subject
today. The gate only works if a group gains a single, distinguished **serving
model**, separate from the set it holds:

- **held**, many per group, unconstrained, assigned exactly as the push drawer
  already does
- **serving**, one per group, and the thing that must match across any two
  groups sharing a machine

That also settles the hold-versus-load distinction, and it matches the machine,
which can only serve one model whatever it is holding.

### The constraint is transitive

    machine A in cluster-1, harvest-1
    machine B in cluster-1, harvest-2

`cluster-1` must agree with `harvest-1` through A and with `harvest-2` through
B, so `harvest-1` and `harvest-2` are forced to agree with each other though they
share no machine and nobody said so.

Invisible with two machines, a web with twenty. Reject at assignment naming the
specific machine and the other group - *rotorua is also in harvest-1, which
serves Qwen3-30B* - so the coupling is seen as it is created rather than
discovered later.

What this trades away, deliberately: a machine can no longer lend batch capacity
for a small model to a harvest group while serving a large one to a cluster
group.

## A split model suspends its machines from harvesting

**Built.** A machine holding a rank of a split model is not available to its
harvest group for as long as it holds it.

This is the two-tier decision arriving at its conclusion rather than a new rule.
A gang-scheduled pipeline cannot be preempted: if one rank yields because
somebody touched a keyboard, the whole job dies and every other machine's model
load is wasted. Harvest membership means precisely that the machine may be taken
away. A machine cannot promise both.

It is also why the same-model gate does not apply here. A harvest group cannot
serve half a model, so there is nothing for the two groups to agree on, and
suspension is the only coherent state.

Read from what is assigned rather than from what is running. A gang that formed
a second after a harvest unit was leased is a gang that dies, so the moment that
matters is when an operator says a cluster group will serve a split model - not
when the first request for it arrives.

Consequences, as built:

- **Suspended, not removed.** Nothing is written to membership. The machine is
  available again the moment the group stops serving that model, and the
  operator never has to remember to put it back.
- **Only the harvest promise is withdrawn.** The cluster group's own work still
  reaches the machine: it is gang scheduled and never preempted, so it is
  coordinated with the split rather than competing with it.
- **The refusal says which.** A lease returns `holding-a-split` rather than
  `no-pool`. The machine *is* in that harvest group, and an operator sent to
  look at membership would find nothing wrong and no explanation.
- **The fleet view says so.** A suspended machine shows *suspended* in place of
  the kinds it would otherwise be offered, with what it is holding, for which
  group, and which harvest group lost it. It is active, unpaused and healthy,
  which is exactly what a merely quiet machine looks like.
- **The cost is stated at assignment.** Assigning a split model to a cluster
  group is refused with `confirm_required` and a sentence naming the machines
  and the groups losing them, until it is repeated with `confirm: true`. The
  operator is trading harvest capacity for a model that would not otherwise run
  at all, which is a decision rather than a side effect - and it is the same
  shape this codebase already uses for the other change that means more than it
  looks like.
