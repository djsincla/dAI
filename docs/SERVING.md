# Interactive serving: design note

The question: can the control plane act as a load balancer, pushing OpenAI-style
single requests to available nodes, with a default model kept resident so there
is no load on the request path?

Short answer: yes for the mechanics, and they are worth building. But there is a
constraint underneath that no amount of engineering removes, and it decides what
this can be.

## The constraint

**GPU work is forbidden while a user is present.** E2 swept QoS against duty
cycle and every configuration was perceptible; the gentlest tested (background
QoS, 25% duty) still cost 46% of viewport p95. GPU harvesting therefore runs
only in LOCKED and ABSENT.

Interactive serving is wanted during working hours. Harvest nodes can only do
GPU work outside working hours. **The window where you want to serve and the
window where harvest nodes can serve are close to disjoint.**

That is not a gap to engineer around. It is the premise of the whole project:
the machines are usable precisely because their owners are not being disturbed.

So the design has to answer "where does a request actually go" honestly:

| Time | Harvest tier | Cluster tier |
|---|---|---|
| Working hours | ANE only (small fixed models) | Full service |
| Locked, evenings, overnight | Full service | Full service |

## What follows from that

**The cluster tier is the home for interactive serving.** Dedicated, pinned,
never preempted, model resident. `spike/cluster/serve.py` already does this.

**The harvest tier contributes to serving out of hours**, which is real capacity
but not what a chat endpoint is usually for. Its daytime contribution is batch
and ANE work, which is what it is good at.

**The ANE is the only daytime path on a machine in use**, and it is limited to
fixed models compiled through Core ML: embeddings, classification, transcription.
Not general chat. Worth building for what it is rather than pretending it
generalises.

## Push without reachability: the reverse channel

E3 chose pull dispatch because harvested machines come and go, and a scheduler
that must reach *into* them needs credentials and reachability it will not
reliably have. That reasoning still holds, and a naive push model would break it.

The standard resolution is a **reverse channel**: the node dials out and holds
the connection open; the control plane pushes down it. Outbound from the node's
perspective, so no inbound firewall rules, no per-node addressing, no NAT
traversal. Push from the scheduler's perspective, so a request can be routed to
a chosen node in milliseconds rather than waiting for the next poll.

    node ---- long-lived outbound connection ----> control plane
         <--- "handle this request now" ---------

This is how CI runners have always worked, and it preserves the property that
made pull the right choice while removing the latency that made it wrong for
serving.

Batch dispatch should stay pull. It is self-balancing, tolerant of nodes coming
and going, and has no latency requirement. Two mechanisms for two jobs.

## Model residency, and the default model

A single OpenAI request assumes a model is already loaded, which is the right
instinct: E4 measured 1-3s to load, and adding that to every request is not
serviceable.

**Track residency per node.** The heartbeat already carries capability profiles;
it should also carry which model hashes are currently resident. Routing then
prefers a node that already holds the model, which turns model load from a
per-request cost into a per-node one.

**A default model is worth keeping warm, but only where policy allows it.** On a
harvest node that means LOCKED and ABSENT. Holding a model resident consumes
`mem_frac` of the machine's working set even when idle, and on someone's
workstation that is memory taken from them for nothing. E4 makes dropping it
cheap: 20ms to release, 1-3s to reload.

So residency follows presence, exactly like everything else:

| State | Default model |
|---|---|
| ACTIVE, PASSIVE, IDLE | Released. ANE model may stay, it costs the user nothing |
| LOCKED, ABSENT | Held warm, ready to serve |

## Routing

With residency tracked and a reverse channel available, the router picks a node
by, in order:

1. **Eligibility.** Does its presence state permit this kind of work right now?
   Applied server-side as well as on the node, because a buggy or compromised
   agent must not be able to talk the scheduler into disturbing someone.
2. **Residency.** Does it already hold this model? Prefer strongly; the
   alternative is 1-3s of load on the request path.
3. **Measured throughput for this workload class.** Not the chip. E3 found the
   same two machines differing 7.5% on a 1.5B model and 26.3% on a 7B, and the
   newer machine is the slower one.
4. **Current in-flight count.** Least-loaded among equals.

No candidate means the request queues or fails fast with a reason, rather than
hanging. "No node may run GPU work right now because everyone is at their desk"
is a legitimate and expected answer during working hours, and the API should say
so plainly rather than timing out.

## The unresolved question: preemption mid-request

If a user returns while their machine is serving a request, the agent must
yield. For batch this is solved: yield between items, hand back the remainder.
A single request has no such seam.

Three options, none free:

- **Finish the request, then yield.** Bounded by `max_tokens / tok/s`, so under
  a second for a short completion and possibly a minute for a long one. It is a
  small, brief violation of the promise that the machine yields immediately.
- **Abandon and retry elsewhere.** Keeps the promise exactly, costs the work done
  so far and adds latency the client sees.
- **Cap `max_tokens` on harvest nodes** so the first option's worst case stays
  small, and take the second only when it exceeds the cap.

The third is probably right, and it should be a policy field with a measured
default rather than a guess. Worth noting the cluster tier does not have this
problem at all, since it is never preempted, which is another reason interactive
serving belongs there.

## Recommendation

1. **Reverse channel** for push dispatch, keeping pull for batch.
2. **Model residency in the heartbeat**, and routing that prefers it.
3. **Default model held warm in LOCKED and ABSENT only**, released when a user
   returns, since E4 makes reload cheap.
4. **An OpenAI endpoint on the control plane** that routes across tiers: cluster
   pool first, eligible harvest nodes second, explicit refusal with a reason
   third.
5. **A yield cap on harvest nodes**, so a request in flight cannot delay a yield
   by more than a bounded and measured amount.

And stated plainly in whatever this becomes: during working hours a harvest
fleet serves ANE work and batch. Interactive GPU serving in those hours needs
the cluster tier. That is a property of respecting the machine's owner, not a
limitation to be worked around.
