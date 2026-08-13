import type { Db } from './db.js'
import { POLICY, type PresenceState, type WorkKind } from './policy.js'
import { membersOf, poolsFor } from './pools.js'

/**
 * Node selection for interactive requests.
 *
 * Batch dispatch is pull-based and self-balancing: fast nodes ask for work
 * sooner, so no routing decision is needed. A synchronous request cannot wait
 * for a poll, so something has to choose, and this is that something.
 *
 * The order below is not arbitrary. Eligibility first because it is a
 * correctness property rather than a preference; residency second because
 * loading a model costs 1-3s (E4) and putting that on the request path is the
 * difference between a service and a curiosity; measured throughput third
 * because it is the only honest capability signal; load last, to break ties.
 */

export interface Candidate {
  id: string
  hostname: string
  /// Which group this machine belongs to at the tier the work needs. A gang
  /// runs inside one group: the machines have to agree about what they serve,
  /// and that agreement is a property of the group rather than of the fleet.
  group_id?: string | null
  /// Cluster nodes are never preempted, so they are not presence-gated.
  tier?: 'harvest' | 'cluster'
  presence_state: PresenceState | null
  resident_models: Record<string, number>
  capability_profiles: Record<string, number>
  in_flight: number
}

export type RefusalReason =
  | 'no-nodes'
  | 'all-in-use'
  | 'no-capacity-for-kind'
  | 'node-unreachable'
  | 'gang-short'
  | 'gang-not-cluster'

export interface Refusal {
  refused: RefusalReason
  detail: string
}

const GPU_KINDS: WorkKind[] = ['generate', 'render']

function permits(state: PresenceState | null, kind: WorkKind): boolean {
  // Unknown presence fails closed. A node that has not reported recently is not
  // assumed idle: guessing wrong here means degrading a machine someone is
  // using, and that is the failure the whole policy exists to avoid.
  const p = POLICY[state ?? 'ACTIVE']
  if (!p) return false
  if (GPU_KINDS.includes(kind)) return p.gpu && p.dutyMax > 0
  return p.ane
}

/**
 * Pick a node, or explain why none was picked.
 *
 * Refusing with a reason is a feature, not a fallback. "Every machine is in use
 * right now" is the expected answer during working hours, and a client is far
 * better served by hearing it immediately than by a request that hangs until it
 * times out.
 */
export function selectNode(
  candidates: Candidate[],
  kind: WorkKind,
  modelHash: string | null,
): Candidate | Refusal {
  if (candidates.length === 0) {
    return { refused: 'no-nodes', detail: 'no active nodes are connected' }
  }

  // Cluster nodes are not presence-gated.
  //
  // The gate exists to keep work off a machine somebody is using, and a cluster
  // node is a dedicated box with nobody at it: its whole definition is that it
  // is never preempted. Applying presence there would make an interactive
  // session depend on whether anyone had touched a keyboard attached to a
  // server, which is not a question with a useful answer.
  //
  // This is also the only way interactive serving works at all. A conversation
  // needs a model that is still resident a minute from now, and the harvest
  // tier cannot promise that by design.
  const eligible = candidates.filter(
    (c) => c.tier === 'cluster' || permits(c.presence_state, kind))
  if (eligible.length === 0) {
    const anyPresent = candidates.some((c) => c.presence_state !== null)
    return GPU_KINDS.includes(kind)
      ? {
          refused: 'all-in-use',
          detail: anyPresent
            ? 'every node has a user present; GPU work runs only when a machine ' +
              'is locked or logged out. Interactive serving needs a cluster-tier ' +
              'node, which is never preempted.'
            : 'no node has reported presence recently',
        }
      : { refused: 'no-capacity-for-kind', detail: `no node can currently run ${kind}` }
  }

  // Residency is a strong preference rather than a filter: a node without the
  // model is still better than refusing, it just pays the load once.
  const resident = modelHash
    ? eligible.filter((c) => modelHash in (c.resident_models ?? {}))
    : eligible
  const pool = resident.length > 0 ? resident : eligible

  return [...pool].sort((a, b) => {
    if (a.in_flight !== b.in_flight) return a.in_flight - b.in_flight
    const key = modelHash ?? kind
    const ra = a.capability_profiles?.[key] ?? 0
    const rb = b.capability_profiles?.[key] ?? 0
    // Measured throughput for this workload class, never the chip: the same two
    // machines differed 7.5% on a 1.5B model and 26.3% on a 7B, and the newer
    // one is the slower.
    return rb - ra
  })[0]!
}

/**
 * Pick a whole gang, or explain why there is not one.
 *
 * A split model runs across N machines in lockstep. Every rank has to be
 * admitted together or none of them: half a pipeline is not a slower answer, it
 * is a request that hangs while holding memory on machines that could have been
 * doing something else.
 *
 * Three conditions, and each rules out a way this goes wrong quietly:
 *
 * **Cluster tier only.** Never-preempted is what the work depends on. A harvest
 * node cannot promise it at any memory ceiling or QoS, and one rank yielding
 * because somebody touched a keyboard takes the whole job down and wastes every
 * other machine's model load.
 *
 * **One group.** Machines in a group agree about what they serve; machines in
 * different groups do not. A gang assembled across groups could be handed ranks
 * of models that are not the same model.
 *
 * **All of them, or none.** Returning what is available and letting the caller
 * cope is the shape that produces a half-started pipeline.
 *
 * On failure the caller releases every member. That is the decision taken
 * deliberately over holding the survivors or resuming elsewhere: resuming needs
 * the lost rank's KV cache, which is not transferable, and holding costs memory
 * on a machine doing nothing while betting the peer returns. On a tier defined
 * as never-preempted this should be rare, and building machinery for a case the
 * tier exists to prevent would be admitting the tier does not work.
 */
export function selectGang(
  candidates: Candidate[],
  kind: WorkKind,
  modelHash: string | null,
  size: number,
): Candidate[] | Refusal {
  if (size <= 1) {
    const one = selectNode(candidates, kind, modelHash)
    return isRefusal(one) ? one : [one]
  }
  if (candidates.length === 0) {
    return { refused: 'no-nodes', detail: 'no active nodes are connected' }
  }

  const cluster = candidates.filter((c) => c.tier === 'cluster')
  if (cluster.length === 0) {
    return {
      refused: 'gang-not-cluster',
      detail: `a ${size}-machine model runs only on cluster-tier machines, which are never `
        + 'preempted; no connected node is one',
    }
  }

  // Grouped, because a gang runs inside one group. Machines with no group are
  // kept apart from each other rather than pooled: two ungrouped machines have
  // not been said to agree about anything.
  const byGroup = new Map<string, Candidate[]>()
  for (const c of cluster) {
    const key = c.group_id ?? `ungrouped:${c.id}`
    byGroup.set(key, [...(byGroup.get(key) ?? []), c])
  }

  // Residency is a preference within a group, as it is for a single node: a
  // machine without the weights is still better than refusing, it just pays the
  // load once. But a gang prefers a group that can field the whole thing
  // already, because N cold loads is N times the delay rather than one.
  const ranked = [...byGroup.values()]
    .filter((members) => members.length >= size)
    .sort((a, b) => resident(b, modelHash) - resident(a, modelHash))

  const chosen = ranked[0]
  if (!chosen) {
    const largest = Math.max(0, ...[...byGroup.values()].map((m) => m.length))
    return {
      refused: 'gang-short',
      detail: `this model needs ${size} machines in one group; the largest cluster group with `
        + `connected machines has ${largest}`,
    }
  }

  // Least loaded first, then measured throughput, so a gang is assembled from
  // the machines least likely to make the rest of it wait. A pipeline runs at
  // the speed of its slowest rank.
  return [...chosen]
    .sort((a, b) => {
      if (a.in_flight !== b.in_flight) return a.in_flight - b.in_flight
      const key = modelHash ?? kind
      return (b.capability_profiles?.[key] ?? 0) - (a.capability_profiles?.[key] ?? 0)
    })
    .slice(0, size)
}

function resident(members: Candidate[], modelHash: string | null): number {
  if (!modelHash) return 0
  return members.filter((m) => modelHash in (m.resident_models ?? {})).length
}

export function isRefusal(x: Candidate | Candidate[] | Refusal): x is Refusal {
  // Arrays first: `'refused' in []` is false, but an array is never a refusal
  // and saying so explicitly is cheaper than reasoning about it later.
  return !Array.isArray(x) && 'refused' in x
}

/** Nodes that could plausibly take an interactive request right now. */
/**
 * The machines a request may land on.
 *
 * `groupId` narrows it to one group's machines, which is what a request that
 * arrived on that group's own socket is asking for. Undefined means the shared
 * serving port, where the whole fleet is in scope - the behaviour every caller
 * had before groups had sockets of their own.
 *
 * Narrowed here rather than at selection, so that "no capacity" on a group's
 * port means that group has none, and cannot accidentally mean the fleet does.
 */
export async function candidatesFor(db: Db, inFlight: Map<string, number>,
                                    groupId?: string | null): Promise<Candidate[]> {
  const { rows } = await db.query(
    `SELECT id, hostname, tier, chip, memory_gb,
            presence_state, resident_models, capability_profiles
       FROM nodes
      WHERE state = 'active'
        AND NOT user_paused
        AND (paused_until IS NULL OR paused_until < now())
        AND last_heartbeat > now() - interval '2 minutes'`,
  )
  // Which cluster group each machine is in, computed rather than stored:
  // membership is a rule, so the only way to know is to evaluate it. Only the
  // cluster group matters here - a gang runs nowhere else.
  const { rows: pools } = await db.query(
    `SELECT id, tier, membership FROM pools WHERE tier = 'cluster'`)

  // The scoping group, which may be of either tier: a harvest group has its own
  // socket too, and a request on it is asking those machines and no others. A
  // group that no longer exists narrows to nothing rather than widening to the
  // fleet.
  const scope = groupId ? await membersOf(db, groupId) : null
  if (groupId && scope === null) return []

  return (rows as any[])
    .filter((n) => scope === null || scope.has(n.id as string))
    .map((n) => ({
    id: n.id,
    hostname: n.hostname,
    tier: n.tier as 'harvest' | 'cluster',
    group_id: (poolsFor(n as never, pools as never)[0]?.id as string | undefined) ?? null,
    presence_state: n.presence_state,
    resident_models: n.resident_models ?? {},
    capability_profiles: n.capability_profiles ?? {},
    in_flight: inFlight.get(n.id) ?? 0,
  }))
}
