/**
 * Which nodes a pool is made of.
 *
 * The `membership` column has existed since the first migration and nothing has
 * ever read it. Work was dispatched on kind alone, so a job submitted to one
 * pool ran anywhere that would take it - pool targeting was recorded at
 * submission and silently ignored at dispatch. With one pool that is invisible.
 * With two it is the failure the whole tier split exists to prevent: gang work
 * landing on a machine that yields the moment somebody touches the keyboard
 * takes the entire job down with it, and every other node's model load is
 * wasted with it.
 *
 * The rule is deliberately asymmetric, because the risk is:
 *
 * **A cluster pool admits only cluster nodes.** Never preemptible is a property
 * the work depends on, and a harvest node cannot promise it at any memory
 * ceiling or QoS.
 *
 * **A harvest pool admits any node.** A dedicated box is strictly more reliable
 * than a workstation, so barring it would idle hardware for symmetry's sake.
 * Harvest work is independent units that survive preemption by construction; it
 * does not care that its node happens to be reliable.
 *
 * Everything else is an explicit narrowing an operator writes down.
 */

/** Extra constraints on top of the tier rule. Absent means unconstrained. */
export interface PoolMembership {
  /** Unified memory floor, in GB. The capability constraint that matters most. */
  minMemoryGb?: number
  /** Exact chip names, e.g. "Apple M4 Pro". */
  chips?: string[]
  /** Named machines, for a pool that is a list rather than a query. */
  hostnames?: string[]
  /**
   * Machines put here by hand, by id.
   *
   * By id rather than hostname because a hostname is not stable: a machine on
   * this fleet enrolled as its own IPv6 address this morning and was renamed
   * afterwards, and a group that had been holding it by name would have
   * silently emptied itself.
   *
   * Its presence makes the pool a list rather than a rule, and the two cannot
   * be mixed: a pool that is both would answer "who is in this group" with
   * something nobody can predict from looking at it.
   */
  nodeIds?: string[]
}

/** Whether a pool is a hand-picked list or a rule that machines match. */
export function poolMode(pool: PoolSpec): 'list' | 'rule' {
  return (pool.membership?.nodeIds?.length ?? 0) > 0 ? 'list' : 'rule'
}

export interface PoolSpec {
  id: string
  tier: string
  membership: PoolMembership | null
  /**
   * Whether this group asserts anything.
   *
   * Optional here only because several callers read pools from SQL that never
   * selected the column. It is treated as enabled when absent, which is the
   * behaviour before disabling existed - and the reason to be careful: three
   * separate faults this month came from a stood-down group still deciding
   * something, and every one of them was a call site that had the field in the
   * database and dropped it on the way here. If you are writing the query, select
   * it.
   */
  enabled?: boolean
}

export interface NodeFacts {
  id?: string
  tier: string
  hostname: string
  chip: string | null
  memory_gb: string | number | null
}

/**
 * Why this node is not in this pool, or null if it is.
 *
 * Returns the reason rather than a boolean because "no work available" and "no
 * pool will have this machine" look identical from a node that is polling
 * forever, and telling them apart by hand meant reading the scheduler.
 */
export function whyNotInPool(node: NodeFacts, pool: PoolSpec): string | null {
  if (pool.tier === 'cluster' && node.tier !== 'cluster') {
    return `pool is cluster tier and this node is ${node.tier}`
  }
  const m = pool.membership ?? {}

  // A hand-picked list answers on its own. Machines are in it because somebody
  // put them there, and applying a memory floor on top would quietly drop one
  // out of a group it was visibly dragged into.
  if (poolMode(pool) === 'list') {
    return m.nodeIds!.includes(node.id ?? '') ? null : 'not in this group'
  }

  if (m.hostnames && !m.hostnames.includes(node.hostname)) {
    return `not among the pool's named hosts`
  }
  if (m.chips && (node.chip === null || !m.chips.includes(node.chip))) {
    return `chip ${node.chip ?? 'unknown'} is not in the pool`
  }
  if (m.minMemoryGb !== undefined) {
    // A node whose memory was never probed fails the floor rather than passing
    // it. Guessing upward here would put work on a machine that cannot hold it.
    const gb = node.memory_gb === null ? null : Number(node.memory_gb)
    if (gb === null || Number.isNaN(gb) || gb < m.minMemoryGb) {
      return `${gb ?? 'unknown'}GB is below the pool's ${m.minMemoryGb}GB floor`
    }
  }
  return null
}

export function nodeMatchesPool(node: NodeFacts, pool: PoolSpec): boolean {
  return whyNotInPool(node, pool) === null
}

/** The pools a node may take work from. */
export function poolsFor(node: NodeFacts, pools: PoolSpec[]): PoolSpec[] {
  // Stood down means claiming nothing, and that has to be true here rather than
  // at each call site. Three faults this month were one call site forgetting:
  // a disabled group blocked a model change by counting toward
  // one-group-per-tier, kept a machine holding a model nobody would route to,
  // and pinned the fleet to an agent version nobody had asked for since. Each
  // was found separately and fixed separately, which is the shape of a rule
  // living in the wrong place.
  return pools.filter((p) => p.enabled !== false && nodeMatchesPool(node, p))
}

/**
 * The machines in one group, by id.
 *
 * Membership is a rule as often as it is a list, so the only way to answer this
 * is to evaluate it - which is why this exists rather than a join. Null when
 * there is no such group, which a caller has to treat as "no machines" rather
 * than "no restriction": a request addressed to a group that has been deleted
 * must not quietly widen to the whole fleet.
 */
export async function membersOf(
  db: { query: (text: string, params?: unknown[]) => Promise<{ rows: unknown[] }> },
  groupId: string,
): Promise<Set<string> | null> {
  const { rows: pools } = await db.query(
    // A group that has been stood down has no members for this purpose: it is
    // asserting nothing, so nothing should be routed to it.
    `SELECT id, tier, membership FROM pools WHERE id = $1 AND enabled`, [groupId])
  if (pools.length === 0) return null
  const { rows: nodes } = await db.query(
    `SELECT id, hostname, tier, chip, memory_gb FROM nodes`)
  return new Set((nodes as NodeFacts[])
    .filter((n) => poolsFor(n, pools as PoolSpec[]).length > 0)
    .map((n) => n.id!))
}

/**
 * A group's name, checked.
 *
 * Names were accepted unvalidated, and one of the first groups anybody made was
 * called "Cluster" while being a harvest-tier group: preemptible, presence
 * gated, scheduled as independent units. Everything about it was the opposite
 * of what its name claimed, and reading a pool listing meant knowing to ignore
 * the name and look at the tier column.
 *
 * That is not a cosmetic problem. Tier decides whether work is preempted when
 * somebody sits down at the machine, and an operator standing up "Cluster"
 * expecting a dedicated box gets a harvest group instead.
 *
 * So a tier name is refused outright rather than warned about. There is no
 * situation where naming a group after a tier it may not be is clearer than
 * naming it after what it does.
 */
export const TIER_NAMES = ['harvest', 'cluster']

export function checkPoolName(raw: unknown): { name: string } | { error: string } {
  if (typeof raw !== 'string') return { error: 'name is required' }
  const name = raw.trim()
  if (name.length === 0) return { error: 'name cannot be empty' }
  if (name.length > 64) return { error: 'name cannot be longer than 64 characters' }
  if (TIER_NAMES.includes(name.toLowerCase())) {
    return {
      error: `"${name}" is a tier, not a group. A group named after a tier `
        + 'claims a scheduling policy it may not have: tier decides whether work '
        + 'is preempted when somebody sits down at the machine, and the two can '
        + 'disagree. Name it after what it does.',
    }
  }
  return { name }
}
