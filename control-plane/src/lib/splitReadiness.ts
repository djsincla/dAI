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

function stateOf(f: RankFacts, model: string): Omit<RankReadiness,
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
  if (!dialable) {
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

  const assessed = members.map((f) => ({ facts: f, ...stateOf(f, model) }))

  // Rank 0 holds the output head and listens; everything else dials it. A
  // machine with no address cannot be dialled, so it cannot be rank 0 - the
  // same rule the router applies, so that a group reported ready here is
  // admitted there.
  const ordered = [...assessed].sort(
    (a, b) => Number(b.dialable) - Number(a.dialable))
  const canAssignRanks = ordered.length > 0 && ordered[0]!.dialable

  const ranks: RankReadiness[] = ordered.map((a, i) => ({
    hostname: a.facts.hostname,
    rank: canAssignRanks ? i : null,
    role: canAssignRanks ? (i === 0 ? 'output head' : 'feeds the next rank') : null,
    state: a.state, detail: a.detail,
    weights: a.weights, loaded: a.loaded, dialable: a.dialable,
  }))

  const present = members.length
  if (present < machines) {
    return {
      state: 'blocked', model, machines, present, ranks,
      detail: `needs ${machines} machines and has ${present}; a split is admitted `
        + 'all at once or not at all',
    }
  }
  if (!canAssignRanks) {
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
