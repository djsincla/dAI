import { poolsFor, type NodeFacts, type PoolSpec } from './pools.js'

/**
 * The two rules that hold a fleet of groups together.
 *
 * A group is a set of machines and the model they serve. Two rules make that
 * sentence mean something, and both are about what a single machine can promise
 * at once:
 *
 * **A machine is in at most one group per tier.** Membership is a rule rather
 * than a list, so without this a node silently joins every group whose rules it
 * matches. With one group that is invisible; with three harvest groups a machine
 * is in all of them, and "which group answered" has no answer - which matters
 * most once each group has its own socket, because a request arriving on either
 * of two sockets could land on the same machine.
 *
 * **Two groups sharing a machine serve the same model.** A machine loads one
 * model. If its cluster group and its harvest group disagree, nothing decides
 * which wins, and the fleet cannot answer why a machine is not serving what it
 * was assigned. Holding many models stays unconstrained; only serving is.
 *
 * Both are checked before a write and refused with the machine named, because
 * the alternative is an operator discovering the coupling later, from a
 * behaviour rather than a message.
 */

export interface Group extends PoolSpec {
  name: string
  /** The one model this group's machines run. Null until somebody says. */
  servingModelId: string | null
  /**
   * Whether this group asserts anything at all.
   *
   * A disabled group keeps its machines, its model and its socket, and acts on
   * none of them. Absent means enabled, so a caller that has not been taught
   * about this yet behaves as it always did.
   */
  enabled?: boolean
}

/** Groups that are asserting something. The rest are configuration at rest. */
export function active(groups: Group[]): Group[] {
  return groups.filter((g) => g.enabled !== false)
}

export interface Violation {
  rule: 'one-group-per-tier' | 'groups-must-agree'
  detail: string
}

/** Which groups a machine falls into, by tier. */
export function groupsFor(node: NodeFacts, groups: Group[]): Map<string, Group[]> {
  const byTier = new Map<string, Group[]>()
  // Disabled groups are not claims, so a machine in one and one other is not a
  // machine in two: standing a group down has to actually free its machines,
  // including from the rule that says how many groups they may be in.
  for (const g of poolsFor(node, active(groups)) as Group[]) {
    byTier.set(g.tier, [...(byTier.get(g.tier) ?? []), g])
  }
  return byTier
}

/**
 * Whether a fleet of groups is coherent, given the machines in it.
 *
 * Takes the whole picture rather than a diff, so a caller checks the state it
 * intends to create and gets back every reason it cannot exist. Checking a
 * change instead would need each caller to know which rules its particular
 * change could break, which is how one of them ends up not knowing.
 */
export function violations(nodes: NodeFacts[], groups: Group[]): Violation[] {
  const found: Violation[] = []

  for (const node of nodes) {
    const byTier = groupsFor(node, groups)

    for (const [tier, matched] of byTier) {
      if (matched.length > 1) {
        found.push({
          rule: 'one-group-per-tier',
          detail: `${node.hostname} is in ${matched.length} ${tier} groups `
            + `(${matched.map((g) => g.name).join(', ')}); a machine may be in one of each tier`,
        })
      }
    }

    // Disagreement between tiers is resolved rather than refused: the cluster
    // group wins and the harvest group follows. See `effectiveModel`.
    //
    // What remains a violation is disagreement that nothing can resolve - two
    // groups of the *same* tier naming different models. One-group-per-tier
    // already makes that impossible, so this is the check that would catch it
    // if that rule were ever relaxed, rather than a case anybody meets today.
    for (const [tier, matched] of byTier) {
      const serving = matched.filter((g) => g.servingModelId !== null)
      const distinct = new Set(serving.map((g) => g.servingModelId))
      if (distinct.size > 1) {
        found.push({
          rule: 'groups-must-agree',
          detail: `${node.hostname} is in ${tier} groups that disagree about what it runs: `
            + serving.map((g) => `${g.name} serves ${g.servingModelId}`).join('; '),
        })
      }
    }
  }

  // One machine can produce the same complaint from two directions, and a list
  // that says it twice reads as two problems.
  const seen = new Set<string>()
  return found.filter((v) => {
    const key = `${v.rule}:${v.detail}`
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

/**
 * The transitive consequence, for an operator about to be surprised by it.
 *
 * Groups that share a machine must agree, so agreement spreads: a cluster group
 * touching two harvest groups forces those two to agree with each other, though
 * they share no machine and nobody said so. Invisible with two machines and a
 * web with twenty, so it can be asked for rather than discovered.
 */
export function coupledWith(group: Group, nodes: NodeFacts[], groups: Group[]): Group[] {
  const byId = new Map(groups.map((g) => [g.id, g]))
  const reached = new Set([group.id])
  let growing = true

  while (growing) {
    growing = false
    for (const node of nodes) {
      const mine = poolsFor(node, groups) as Group[]
      if (!mine.some((g) => reached.has(g.id))) continue
      for (const g of mine) {
        if (!reached.has(g.id)) { reached.add(g.id); growing = true }
      }
    }
  }

  reached.delete(group.id)
  return [...reached].map((id) => byId.get(id)!).filter(Boolean)
}

/**
 * What a machine actually runs, when its groups say different things.
 *
 * **A cluster group overrides a harvest one where they share a machine.**
 *
 * The two tiers are not equal claims. A cluster group promises never to be
 * preempted and is the only place a split model can run; a harvest group
 * promises the opposite - that the machine may be taken away the moment
 * somebody touches a keyboard. When both want the same machine to run something,
 * only one of those promises can be kept, and it is not the harvest one.
 *
 * This replaces refusing the pair outright. Refusal made the order an operator
 * did two legitimate things in decide whether they were allowed to, and left a
 * fleet where assigning a model to a cluster group failed because a harvest
 * group had been given a different one weeks earlier by somebody else.
 *
 * Null when no group this machine is in has named a model, which is not the
 * same as "serve nothing": nobody has said.
 */
export function effectiveModel(node: NodeFacts, groups: Group[]): string | null {
  const mine = (poolsFor(node, active(groups)) as Group[])
    .filter((g) => g.servingModelId !== null)
  const cluster = mine.find((g) => g.tier === 'cluster')
  return (cluster ?? mine[0])?.servingModelId ?? null
}

/**
 * Which groups are having their model overridden on which machines.
 *
 * Not a fault - it is the rule working - but it has to be visible. A harvest
 * group whose machines are all running a cluster group's model is a group whose
 * own declaration means nothing at the moment, and an operator reading that
 * group's model would otherwise be reading something untrue.
 */
export function overrides(nodes: NodeFacts[], groups: Group[]): {
  hostname: string; harvest: string; runs: string; insteadOf: string; by: string
}[] {
  const out = []
  for (const node of nodes) {
    const mine = poolsFor(node, active(groups)) as Group[]
    const cluster = mine.find((g) => g.tier === 'cluster' && g.servingModelId !== null)
    if (!cluster) continue
    for (const h of mine.filter((g) => g.tier === 'harvest'
                                  && g.servingModelId !== null
                                  && g.servingModelId !== cluster.servingModelId)) {
      out.push({
        hostname: node.hostname, harvest: h.name, runs: cluster.servingModelId!,
        insteadOf: h.servingModelId!, by: cluster.name,
      })
    }
  }
  return out
}
