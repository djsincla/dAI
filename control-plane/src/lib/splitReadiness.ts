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

/**
 * A model a group was staged with, and whether it could actually run.
 *
 * Only meaningful for a group that names no model of its own. It serves
 * whichever of these a caller asks for, so "is this group ready" is not one
 * question any more - the machines can be up and reachable while half the
 * staged models are still arriving, and an operator needs to see which.
 */
export interface StagedModel {
  modelId: string
  /** How many machines it was declared to need. */
  machines: number
  /** How many of this group's machines hold the weights. */
  held: number
  /** Whether a request for it would be served rather than refused. */
  ready: boolean
}

export interface Readiness {
  state: GroupState
  detail: string
  /**
   * The model this group is pinned to, or null when it serves whatever it was
   * staged with. Null no longer means "nothing is set up here": see `staged`.
   */
  model: string | null
  /** How many machines the model was declared to need. */
  machines: number
  /** How many are present and could take a rank. */
  present: number
  ranks: RankReadiness[]
  /**
   * What an unpinned group can be asked for. Empty for a pinned group, which
   * asserts one model and reports it in `model`.
   */
  staged: StagedModel[]
  /**
   * Whether the group is standing.
   *
   * `idle` covers two states that read the same and mean opposite things: a
   * group an operator stood down, and a standing group nobody has staged
   * anything to. The first is a decision and the second is a thing to go and
   * do, and a console cannot tell them apart from the state alone.
   */
  standing: boolean
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
 * Whether a group that names no model could serve what it holds.
 *
 * The pinned view asks whether one model is built and warm. This asks a
 * different question, and the difference that matters is `loaded`: a dynamic
 * group deliberately warms nothing, so a machine holding weights with nothing
 * built is ready rather than still preparing. Running these facts through the
 * pinned assessment would report a working group as perpetually loading.
 */
function dynamicReadiness(
  members: RankFacts[], staged: { modelId: string; machines: number }[],
): Readiness {
  const present = members.length

  if (staged.length === 0) {
    return {
      state: 'idle', model: null, machines: 1, present, ranks: [], staged: [], standing: true,
      detail: 'serves whichever model it is staged with, and nothing has been '
        + 'staged yet - push a model to this group to give it something to load',
    }
  }

  // What each staged model would find if it were asked for this instant, which
  // is the question an operator actually has. Held by fewer machines than it
  // needs is a request that will be refused, and saying so here is the whole
  // point of the view.
  const held: StagedModel[] = staged
    .map((s) => {
      const holders = members.filter((f) => f.onDisk.includes(s.modelId)).length
      return {
        modelId: s.modelId, machines: s.machines, held: holders,
        ready: holders >= s.machines && present >= s.machines,
      }
    })
    .sort((a, b) => a.modelId.localeCompare(b.modelId))

  // The widest thing it could be asked for. A group of two staged with a
  // three-machine model can never serve that one, and `present < machines` is
  // where that gets said.
  const widest = held.reduce((n, s) => Math.max(n, s.machines), 1)
  const split = widest > 1

  const assessed = members.map((f) => {
    const anyHeld = staged.some((s) => f.onDisk.includes(s.modelId))
    const anyLoaded = staged.some((s) => f.loaded.includes(s.modelId))
    const dialable = !!f.pipelineAddress
    const base = {
      weights: (anyHeld ? 'present' : 'missing') as 'present' | 'missing',
      loaded: anyLoaded, dialable,
    }
    // Same order as the pinned path, and for the same reason: one problem
    // causes the rest, and listing four is how a readiness view stops being
    // read.
    if (!f.connected) {
      return { facts: f, ...base, state: 'unreachable' as RankState, detail: 'not connected' }
    }
    if (f.syncFault) {
      return { facts: f, ...base, state: 'faulted' as RankState, detail: f.syncFault }
    }
    if (split && !dialable) {
      return { facts: f, ...base, state: 'unreachable' as RankState,
        detail: 'has not said where a peer should dial it - check the link and '
          + 'DAI_PIPELINE_INTERFACE' }
    }
    if (!anyHeld) {
      return { facts: f, ...base, state: 'fetching' as RankState,
        detail: 'holds none of the staged models yet' }
    }
    // Holding weights and building nothing is the intended resting state here,
    // not a stage on the way to somewhere.
    return { facts: f, ...base, state: 'ready' as RankState,
      detail: anyLoaded ? 'ready, holding what it last served' : 'ready to load on request' }
  })

  // Ranks come from addresses, not from the model, so they can be assigned
  // before anybody has asked for anything - which is exactly the state a
  // dynamic group sits in.
  const assigned = split
    ? assignRanks(assessed.map((a) => ({
        id: a.facts.nodeId, hostname: a.facts.hostname,
        pipelineAddress: a.facts.pipelineAddress,
      })))
    : null
  const seatFor = new Map((assigned ?? []).map((r) => [r.member.id, r]))
  const inOrder = assigned
    ? assigned.map((r) => assessed.find((a) => a.facts.nodeId === r.member.id)!)
    : assessed

  const ranks: RankReadiness[] = inOrder.map((a) => {
    const seat = seatFor.get(a.facts.nodeId)
    return {
      hostname: a.facts.hostname, rank: seat?.rank ?? null, role: seat?.role ?? null,
      state: a.state, detail: a.detail,
      weights: a.weights, loaded: a.loaded, dialable: a.dialable,
    }
  })

  const base = { model: null, machines: widest, present, ranks, staged: held, standing: true }

  if (present < widest) {
    return { ...base, state: 'blocked',
      detail: `the widest staged model needs ${widest} machines and this group has `
        + `${present}; a split is admitted all at once or not at all` }
  }
  if (split && assigned === null) {
    return { ...base, state: 'blocked',
      detail: 'no machine has said where a peer should dial it, so no rank can '
        + 'hold the output head' }
  }
  const stuck = ranks.filter((r) => r.state === 'unreachable' || r.state === 'faulted')
  if (stuck.length > 0) {
    return { ...base, state: 'blocked',
      detail: stuck.map((r) => `${r.hostname}: ${r.detail}`).join('; ') }
  }

  const servable = held.filter((s) => s.ready)
  if (servable.length === 0) {
    return { ...base, state: 'preparing',
      detail: `staged with ${held.length} model${held.length === 1 ? '' : 's'}, none of `
        + 'them on enough machines yet' }
  }
  const waiting = held.length - servable.length
  return { ...base, state: 'ready',
    detail: `ready to load any of ${servable.length} staged model`
      + `${servable.length === 1 ? '' : 's'} on request`
      + (waiting > 0 ? `; ${waiting} still arriving` : '')
      + '. The first request for a model it is not already holding pays the build.' }
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
  /**
   * What the group was staged with, when it names no model of its own. Ignored
   * for a pinned group, which asserts one model and is judged against it.
   */
  staged?: { modelId: string; machines: number }[]
}): Readiness {
  const { enabled, model, machines, members } = input

  if (!enabled) {
    return {
      state: 'idle', model, machines, present: members.length, ranks: [], staged: [], standing: false,
      detail: 'stood down; its machines belong to whatever else claims them',
    }
  }

  // A group naming no model used to be reported as idle - "no model assigned",
  // which read as a group nobody had finished setting up. It is now a group
  // that serves whichever staged model is asked for, and that is a different
  // question with a different answer: not "are the shares built" but "what
  // could be asked for, and would it be served".
  if (model === null) return dynamicReadiness(members, input.staged ?? [])

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
      state: 'blocked', model, machines, present, ranks, staged: [], standing: true,
      detail: `needs ${machines} machines and has ${present}; a split is admitted `
        + 'all at once or not at all',
    }
  }
  if (split && !canAssignRanks) {
    return {
      state: 'blocked', model, machines, present, ranks, staged: [], standing: true,
      detail: 'no machine has said where a peer should dial it, so no rank can '
        + 'hold the output head',
    }
  }

  const worst = ranks.filter((r) => r.state !== 'ready')
  if (worst.length === 0) {
    return {
      state: 'ready', model, machines, present, ranks, staged: [], standing: true,
      detail: `${machines} machines hold ${model} and can reach each other`,
    }
  }

  // Blocked is what an operator has to act on; preparing resolves on its own.
  // Saying so is the difference between waiting and going to look at a machine.
  const stuck = worst.filter((r) => r.state === 'unreachable' || r.state === 'faulted')
  return stuck.length > 0
    ? {
        state: 'blocked', model, machines, present, ranks, staged: [], standing: true,
        detail: stuck.map((r) => `${r.hostname}: ${r.detail}`).join('; '),
      }
    : {
        state: 'preparing', model, machines, present, ranks, staged: [], standing: true,
        detail: worst.map((r) => `${r.hostname}: ${r.detail}`).join('; '),
      }
}
