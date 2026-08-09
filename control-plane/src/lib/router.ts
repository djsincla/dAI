import type { Db } from './db.js'
import { POLICY, type PresenceState, type WorkKind } from './policy.js'

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

export function isRefusal(x: Candidate | Refusal): x is Refusal {
  return 'refused' in x
}

/** Nodes that could plausibly take an interactive request right now. */
export async function candidatesFor(db: Db, inFlight: Map<string, number>): Promise<Candidate[]> {
  const { rows } = await db.query(
    `SELECT id, hostname, tier, presence_state, resident_models, capability_profiles
       FROM nodes
      WHERE state = 'active'
        AND NOT user_paused
        AND (paused_until IS NULL OR paused_until < now())
        AND last_heartbeat > now() - interval '2 minutes'`,
  )
  return (rows as any[]).map((n) => ({
    id: n.id,
    hostname: n.hostname,
    tier: n.tier as 'harvest' | 'cluster',
    presence_state: n.presence_state,
    resident_models: n.resident_models ?? {},
    capability_profiles: n.capability_profiles ?? {},
    in_flight: inFlight.get(n.id) ?? 0,
  }))
}
