/**
 * Whether a split group could serve a request right now, and what is missing.
 *
 * Standing a split up means enabling the group and then waiting - while ~18 GB
 * of weights reach both machines, while each builds its share, while the
 * pipeline link comes up - with nothing to look at. The first sign that it was
 * not ready came from sending a request and reading the refusal, which is a
 * diagnostic disguised as a failure and arrives minutes after the operator
 * could have acted on it.
 *
 * This asks the same questions the router asks at dispatch, before anybody
 * sends anything. Deliberately the same questions and in the same order, so a
 * group reported ready here is a group that will be admitted there; a readiness
 * view that disagrees with the router is worse than none, because it is
 * believed.
 *
 * Four facts per machine, and they fail in a fixed order. Connected, or nothing
 * else matters. Then the weights, which take longest. Then loaded, which is the
 * part a cluster group is supposed to keep warm. Then reachable for pipeline
 * traffic, which is the one that is nearly always a cable.
 */

import { assignRanks } from './splitRanks.js'

export interface RankFacts {
  nodeId: string
  hostname: string
  connected: boolean
  /** The model this machine has been told to hold, if any. */
  assigned: string | null
  /** Models whose weights are on this machine's disk. */
  onDisk: string[]
  /** Models this machine currently has built and in memory. */
  loaded: string[]
  /** Where a peer should dial it, as the machine itself declared. */
  pipelineAddress: string | null
  /** Anything the model sync reported it could not do. */
  syncFault: string | null
}

export type RankState = 'ready' | 'loading' | 'fetching' | 'unreachable' | 'faulted'

export interface RankReadiness {
  hostname: string
  /** Null until ranks can be assigned, which needs at least one dialable machine. */
  rank: number | null
  role: 'output head' | 'feeds the next rank' | null
  state: RankState
  detail: string
  weights: 'present' | 'missing'
  loaded: boolean
  dialable: boolean
}

export type GroupState = 'ready' | 'preparing' | 'blocked' | 'idle'

export interface Readiness {
  state: GroupState
  detail: string
  model: string | null
  /** How many machines the model was declared to need. */
  machines: number
  /** How many are present and could take a rank. */
  present: number
  ranks: RankReadiness[]
}

function stateOf(f: RankFacts, model: string, split: boolean): Omit<RankReadiness,
  'hostname' | 'rank' | 'role'> {
  const weights = f.onDisk.includes(model) ? 'present' : 'missing'
  const loaded = f.loaded.includes(model)
  const dialable = !!f.pipelineAddress

  // Ordered by what has to be true first. A machine that is not connected has
  // nothing else worth reporting, and listing four problems when one of them
  // causes the rest is how a readiness view stops being read.
  if (!f.connected) {
    return { state: 'unreachable', weights, loaded, dialable,
      detail: 'not connected' }
  }
  if (f.syncFault) {
    return { state: 'faulted', weights, loaded, dialable,
      detail: f.syncFault }
  }
  if (weights === 'missing') {
    return { state: 'fetching', weights, loaded, dialable,
      detail: f.assigned === model
        ? 'fetching the weights'
        : 'has not been told to hold this model yet' }
  }
  // Only when there is a peer to dial. A machine holding a whole model answers
  // on its own and needs no address; reporting it unreachable would describe a
  // link it will never use.
  if (split && !dialable) {
    // Named rather than described, because the fix is a setting and the symptom
    // is a group that will not form. The interface is usually a cable that came
    // out, and bridge0 stays up with no address when it does.
    return { state: 'unreachable', weights, loaded, dialable,
      detail: 'has not said where a peer should dial it - check the link and '
        + 'DAI_PIPELINE_INTERFACE' }
  }
  if (!loaded) {
    return { state: 'loading', weights, loaded, dialable,
      detail: 'weights are here; the model is not built yet' }
  }
  return { state: 'ready', weights, loaded, dialable, detail: 'ready' }
}

/**
 * @param enabled whether the group is standing. A disabled group is idle rather
 *   than blocked - it is asserting nothing, and reporting it as broken would
 *   describe an operator's own decision as a fault.
 */
export function splitReadiness(input: {
  enabled: boolean
  model: string | null
  machines: number
  members: RankFacts[]
}): Readiness {
  const { enabled, model, machines, members } = input

  if (!enabled || model === null) {
    return {
      state: 'idle', model, machines, present: members.length, ranks: [],
      detail: !enabled
        ? 'stood down; its machines belong to whatever else claims them'
        : 'no model assigned',
    }
  }

  const split = machines > 1
  const assessed = members.map((f) => ({ facts: f, ...stateOf(f, model, split) }))

  // The same assignment the router makes at dispatch and the heartbeat sends
  // ahead of it, from one implementation - so a group reported ready here is a
  // group admitted there, and a machine warms the share it will be asked for.
  // A peer address only matters when there is a peer.
  //
  // This view was written for splits and is used for every cluster group, so a
  // group holding a whole model - dedicated and loaded, every machine able to
  // answer alone - was run through the same rank assignment and reported
  // blocked for want of an address it would never use. With addresses it was
  // worse: it named an output head and a rank that feeds the next one, for a
  // pipeline that does not exist.
  const assigned = split
    ? assignRanks(assessed.map((a) => ({
        id: a.facts.nodeId, hostname: a.facts.hostname,
        pipelineAddress: a.facts.pipelineAddress,
      })))
    : null
  const canAssignRanks = !split || assigned !== null
  const seatFor = new Map((assigned ?? []).map((r) => [r.member.id, r]))

  // Listed in rank order when there is one, so the head reads first. Without an
  // ordering the machines are listed as they came, because inventing an order
  // for a group that cannot form implies a decision nobody made.
  // Rank order when there is one. Without a pipeline the machines are listed as
  // they came, because inventing an order implies a decision nobody made.
  const inOrder = assigned
    ? assigned.map((r) => assessed.find((a) => a.facts.nodeId === r.member.id)!)
    : assessed

  const ranks: RankReadiness[] = inOrder.map((a) => {
    const seat = seatFor.get(a.facts.nodeId)
    return {
      hostname: a.facts.hostname,
      rank: seat?.rank ?? null,
      role: seat?.role ?? null,
      state: a.state, detail: a.detail,
      weights: a.weights, loaded: a.loaded, dialable: a.dialable,
    }
  })

  const present = members.length
  if (present < machines) {
    return {
      state: 'blocked', model, machines, present, ranks,
      detail: `needs ${machines} machines and has ${present}; a split is admitted `
        + 'all at once or not at all',
    }
  }
  if (split && !canAssignRanks) {
    return {
      state: 'blocked', model, machines, present, ranks,
      detail: 'no machine has said where a peer should dial it, so no rank can '
        + 'hold the output head',
    }
  }

  const worst = ranks.filter((r) => r.state !== 'ready')
  if (worst.length === 0) {
    return {
      state: 'ready', model, machines, present, ranks,
      detail: `${machines} machines hold ${model} and can reach each other`,
    }
  }

  // Blocked is what an operator has to act on; preparing resolves on its own.
  // Saying so is the difference between waiting and going to look at a machine.
  const stuck = worst.filter((r) => r.state === 'unreachable' || r.state === 'faulted')
  return stuck.length > 0
    ? {
        state: 'blocked', model, machines, present, ranks,
        detail: stuck.map((r) => `${r.hostname}: ${r.detail}`).join('; '),
      }
    : {
        state: 'preparing', model, machines, present, ranks,
        detail: worst.map((r) => `${r.hostname}: ${r.detail}`).join('; '),
      }
}
