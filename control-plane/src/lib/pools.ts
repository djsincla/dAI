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
  return pools.filter((p) => nodeMatchesPool(node, p))
}
