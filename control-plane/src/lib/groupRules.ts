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
}

export interface Violation {
  rule: 'one-group-per-tier' | 'groups-must-agree'
  detail: string
}

/** Which groups a machine falls into, by tier. */
export function groupsFor(node: NodeFacts, groups: Group[]): Map<string, Group[]> {
  const byTier = new Map<string, Group[]>()
  for (const g of poolsFor(node, groups) as Group[]) {
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

    // Only groups that actually name a model can disagree. A group with none is
    // not yet a claim about anything, and refusing it would make the order in
    // which an operator does two legitimate things decide whether they are
    // allowed.
    const serving = [...byTier.values()].flat()
      .filter((g) => g.servingModelId !== null)
    const distinct = new Set(serving.map((g) => g.servingModelId))
    if (distinct.size > 1) {
      const said = serving
        .map((g) => `${g.name} serves ${g.servingModelId}`)
        .join('; ')
      found.push({
        rule: 'groups-must-agree',
        detail: `${node.hostname} is in groups that disagree about what it runs: ${said}`,
      })
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
