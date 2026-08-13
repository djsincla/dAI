import { poolsFor, type NodeFacts } from './pools.js'
import type { Group } from './groupRules.js'

/**
 * A machine holding part of a split model is not available to its harvest group.
 *
 * This is the two-tier decision arriving at its conclusion rather than a new
 * rule. A gang-scheduled pipeline cannot be preempted: if one rank yields
 * because somebody touched a keyboard, the whole job dies and every other
 * machine's model load is wasted. Harvest membership means precisely that the
 * machine may be taken away. No machine can promise both.
 *
 * It is also why the same-model gate does not apply here. A harvest group cannot
 * serve half a model, so there is nothing for the two groups to agree about, and
 * suspension is the only coherent state.
 *
 * Suspended rather than removed: the machine returns to its harvest group when
 * the cluster group stops serving a split model. Taking it out would lose the
 * operator's intent, and they would have to remember to put it back.
 */

export interface Suspension {
  nodeId: string
  hostname: string
  /** The model whose ranks this machine is holding part of. */
  modelId: string
  /** How many machines that model runs across. Always more than one. */
  machines: number
  /** The cluster group that is serving it. */
  by: { id: string; name: string }
  /** The harvest groups this machine is therefore not available to. */
  from: { id: string; name: string }[]
}

/**
 * How many machines a model runs across, as the catalogue records it.
 *
 * Passed in rather than looked up, so the rule is a function of its arguments
 * and can be tested without a database. One is not split.
 */
export type MachineCount = (modelId: string) => number

/**
 * Why this machine is suspended from harvesting, or null if it is not.
 *
 * Reads from what is *assigned*, not from what is running. A gang that formed a
 * second after a harvest unit was leased is a gang that dies, so the moment that
 * matters is when the operator says a cluster group will serve a split model -
 * not when the first request for it arrives.
 */
export function suspensionFor(node: NodeFacts, groups: Group[],
                              machinesFor: MachineCount): Suspension | null {
  const mine = poolsFor(node, groups) as Group[]
  const cluster = mine.find(
    (g) => g.tier === 'cluster' && g.servingModelId !== null
      && machinesFor(g.servingModelId) > 1)
  if (!cluster) return null

  const harvest = mine.filter((g) => g.tier === 'harvest')
  // Suspended even when it is in no harvest group. Nothing changes for the
  // machine, but the fleet still says what it is doing, and a machine added to
  // a harvest group tomorrow is already accounted for.
  return {
    nodeId: node.id ?? '',
    hostname: node.hostname,
    modelId: cluster.servingModelId!,
    machines: machinesFor(cluster.servingModelId!),
    by: { id: cluster.id, name: cluster.name },
    from: harvest.map((g) => ({ id: g.id, name: g.name })),
  }
}

/** Every machine currently suspended, for a fleet view that has to say so. */
export function suspensions(nodes: NodeFacts[], groups: Group[],
                            machinesFor: MachineCount): Suspension[] {
  return nodes
    .map((n) => suspensionFor(n, groups, machinesFor))
    .filter((s): s is Suspension => s !== null)
}

/**
 * What assigning this model to this group will cost, said before it is done.
 *
 * The operator is trading harvest capacity for a model that would not otherwise
 * run at all, which is a decision rather than a side effect. An N-way split
 * takes N workstations out of harvesting, and the sentence has to arrive before
 * the assignment rather than as an explanation of why the fleet got quieter.
 *
 * Empty string when nothing is suspended, so a caller can test it as a message
 * rather than reasoning about the shape.
 */
export function costOfServing(modelId: string, machines: number,
                              members: NodeFacts[], groups: Group[]): string {
  if (machines <= 1) return ''
  const affected = members
    .map((n) => ({ n, harvest: (poolsFor(n, groups) as Group[]).filter((g) => g.tier === 'harvest') }))
    .filter((m) => m.harvest.length > 0)
  if (affected.length === 0) return ''

  const names = [...new Set(affected.flatMap((m) => m.harvest.map((g) => g.name)))].sort()
  const machinesWord = affected.length === 1 ? 'machine' : 'machines'
  return `serving ${modelId} here suspends ${affected.length} ${machinesWord} `
    + `from ${names.join(' and ')} until it stops: a split rank cannot be preempted, `
    + 'and harvest membership is the promise that it can be'
}
