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
   * none of them.
   *
   * Required, and it was optional. Optional meant a construction site that
   * forgot the field got "enabled" by default, silently, with nothing to
   * compile against - and two of them did forget. A disabled group went on
   * counting toward one-group-per-tier, so changing a group's model was refused
   * for conflicting with a group that had been stood down precisely to stop it
   * conflicting. The refusal named a rule nobody could satisfy without deleting
   * something they meant to keep.
   *
   * The original reasoning was that absent should mean enabled so callers not
   * yet taught about disabling would behave as they always had. They did not:
   * they behaved as though nothing was ever disabled, which is a different
   * thing and was wrong from the moment the feature landed. A required field
   * turns that into a compile error at every site at once.
   */
  enabled: boolean

  /**
   * How long a machine in this group holds a model after the last request.
   *
   * Null means the fleet default. Only meaningful for harvest: a cluster group
   * is dedicated and loaded, and is not sent a window at all.
   */
  idleUnloadSeconds?: number | null
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
  return effectiveServing(node, groups).model
}

/**
 * What a machine should serve, and whether to hold it in memory.
 *
 * The two answers come from the same decision and used to be one, which left
 * every machine loading lazily - correct for harvest and wrong for a cluster.
 *
 * **Harvest is lazy.** The weights are on disk and the model loads when a
 * request arrives. These are workstations somebody is sitting at, and holding
 * gigabytes for a request that may not come today is the behaviour the whole
 * presence policy exists to avoid.
 *
 * **A cluster is warm.** A cluster group exists because a model is large, often
 * too large for one machine, and a caller addressing that socket is asking for
 * the thing that takes longest to start. Worse, a split cannot begin until every
 * rank has built its share, so a cold gang pays the slowest machine's load
 * before the first token - and pays it again every time the group falls idle.
 * The operator already accepted the cost by standing the group up: it takes
 * those machines out of harvesting for as long as it stands, so the memory is
 * spoken for whether or not it holds anything.
 *
 * **A cluster group that names no model is dynamic.** It serves whichever of
 * the models staged to it a caller asks for, loading at dispatch. Same tier,
 * because a tier encodes preemptibility and this one is preempted exactly as
 * little as any other cluster group: it differs only in whether the model was
 * named ahead of the request or left to the caller. It is warm in the sense
 * that matters - it keeps what it built rather than rebuilding per request -
 * but there is nothing to warm before the first one arrives.
 *
 * The node is told the intent and not the tier. It never learns which groups it
 * belongs to - that is deliberate, so a credential on a workstation does not
 * carry the shape of the fleet - and "hold this loaded" is an instruction it can
 * follow without knowing why.
 */
/**
 * How long a machine holds a model when nothing is being asked of it.
 *
 * Five minutes, and the number matters more than the knob because most fleets
 * will never change it. It is not really a setting about weights: unloading
 * clears the prompt cache with them, and that is the expensive half - releasing
 * too eagerly once turned a 0.5 s warm request into 37.5 s. Read it as how long
 * to keep a conversation warm, and five minutes covers an agentic client whose
 * turns are seconds apart with room to spare.
 */
export const DEFAULT_IDLE_UNLOAD_SECONDS = 300

export function effectiveServing(
  node: NodeFacts, groups: Group[], machinesFor?: (modelId: string) => number,
): {
  model: string | null; keepLoaded: boolean; machines: number
  idleUnloadSeconds: number | null
  /** The group that decided all of it, so a caller can ask about its members. */
  groupId: string | null
} {
  // A cluster group that has named no model survives this filter, because it
  // has still claimed the machine. "Serve whichever staged model is asked for"
  // is a decision an operator made, and dropping it here would leave the
  // machine believing it belongs to nothing: lazy, idle-released on the harvest
  // schedule, and letting go of the split share it had just built. Everything
  // else about a dynamic group follows from surviving this line.
  //
  // An unpinned harvest group is genuinely nothing and is still dropped.
  const mine = (poolsFor(node, active(groups)) as Group[])
    .filter((g) => g.servingModelId !== null || g.tier === 'cluster')
  // Cluster preempts harvest where a machine is in both. A split rank cannot be
  // preempted and harvest membership is the promise that a machine can be taken
  // away; only one of those survives contact with one machine.
  const winner = mine.find((g) => g.tier === 'cluster') ?? mine[0]
  const model = winner?.servingModelId ?? null

  // Pinned to one model, rather than serving whatever it has been staged with.
  // The distinction is not the tier: both are cluster groups, dedicated and
  // never preempted, and they differ only in whether an operator named the
  // model ahead of the request or left it to the caller.
  const dedicated = winner?.tier === 'cluster' && winner.servingModelId !== null

  return {
    model,
    // True for either kind of cluster group, which makes this the one thing
    // that tells a machine it is in one. A dynamic group names no model and no
    // standing split, so without this the agent could not tell "nothing stands
    // here any more" from "something may be asked for at any moment" - and it
    // would release a built share on the next heartbeat.
    keepLoaded: winner?.tier === 'cluster',
    // How many machines the model was declared to need.
    //
    // The node cannot work this out and must not guess: warming a model that
    // runs across machines by loading the whole thing is the failure this
    // exists to stop - 18.4 GB held on every machine to serve 9.45 GB of it,
    // and the warm copy never used, because the split path builds its own
    // reduced model from the same weights.
    machines: model ? Math.max(1, machinesFor?.(model) ?? 1) : 1,
    // Null for a group pinned to a model, which is dedicated and loaded and has
    // no idle window. Sending it one that is merely very long invites somebody
    // to set it short, and a split that unloads between requests is a split
    // that rebuilds its share every time.
    //
    // An unpinned cluster group is the opposite case and needs one. It holds
    // whatever it was last asked for, so without a window the first caller's
    // model is pinned in memory for as long as the group stands - chosen by
    // whoever asked first rather than by an operator, and never released.
    idleUnloadSeconds: winner === undefined || dedicated
      ? null
      : winner.idleUnloadSeconds ?? DEFAULT_IDLE_UNLOAD_SECONDS,
    groupId: winner?.id ?? null,
  }
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
