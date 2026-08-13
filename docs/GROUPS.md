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

**Allocated from a range, bound at runtime when a group is created.**

The port belongs on the group's row, is unique, and is what the fleet view shows
so somebody can point a client at it.

Consequences that have to be designed rather than discovered:

**Creating a group can now fail at bind.** The port may be taken by something
else on the host. A group that is created and then found unreachable is worse
than a creation that refused, so the bind has to succeed before the row is
committed - or the row has to be removed when it does not.

**Every group's listener has to be rebound at startup.** The ports live in the
database, so the server binds N listeners at boot rather than one. A bind that
fails then is the dangerous case: the group exists, its models are assigned, its
machines are holding them, and nothing answers. That must be loud - reported by
`/monitor/v1/health` and visible in the fleet view - and not merely logged.

The fleet has spent today finding counts that meant less than they appeared to.
A group whose socket is not listening should not read as healthy.

**Deleting a group has to close its listener**, and the port should not be
reused immediately by the next group created, or a client left pointing at the
old URL silently starts talking to a different group.

**TLS is unaffected.** One certificate covers every port on the same host.

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

## Open: what a machine in both groups serves

A machine in a harvest group and a cluster group is told to *hold* both groups'
models. It can only *serve* one: the served model is a single argument in that
machine's launchd plist.

So a node can be assigned two models and serve one, with nothing recording which
- and the fleet would have no way to answer "why is this machine not serving the
model I assigned it". Three possible answers, none obviously right:

- The cluster group's model is the one served, and the harvest group's is held
  for batch work only. Simple, and makes cluster membership mean "this is what
  you serve".
- Holding and serving become separate assignments, so a group can say "hold
  this" without saying "serve this".
- A machine may serve one model per group, on that group's socket, which is the
  most useful and needs the agent to load two models at once - a memory question
  before it is a scheduling one.

This wants deciding before the socket work, because it determines what a request
arriving on a group's socket is entitled to expect.
