/**
 * What the fleet view says about a node or a job, as data rather than markup.
 *
 * Separated so it can be tested. The rendering that used to hold these
 * decisions was reachable only by loading a page against a live control plane,
 * so nothing checked them - and they are exactly the judgements a reader will
 * trust without checking: whether a machine counts as available, whether work
 * is real or somebody's load test, whether a pause is one an operator may lift.
 *
 * Every function here is pure. The DOM is the caller's problem.
 */

/** Presence states in which a machine will run GPU work. */
export const GPU_STATES = new Set(['LOCKED', 'ABSENT'])

/**
 * Whether a node is offering GPU work right now.
 *
 * Three things have to be true and each was wrong at some point: it has to be
 * active, its owner must not have paused it, and either it is a cluster node -
 * never preempted, so presence does not apply - or nobody is sitting at it.
 */
export function runsGpu(node) {
  if (node.state !== 'active' || node.userPaused) return false
  return node.tier === 'cluster' || GPU_STATES.has(node.presenceState)
}

/**
 * The work kinds to show against a node.
 *
 * A paused machine shows none: it is not a machine that happens to be idle, it
 * is one whose owner has said no, and listing what it could do implies
 * otherwise.
 */
export function kindsFor(node) {
  if (node.state !== 'active' || node.userPaused) return []
  return runsGpu(node) ? ['embed', 'generate', 'render'] : ['embed']
}

/**
 * What a node is serving, and whether it could answer this instant.
 *
 * `busy` rather than `idle` when a node holds a model but is not on the
 * channel: a machine reading a large prompt is occupied for minutes while being
 * entirely healthy, and reporting that as unavailable sends people looking for
 * a crash.
 */
export function servingFor(node) {
  const models = node.models ?? []
  if (models.length === 0) return { state: 'none', label: '—', models: [] }
  if (!node.serving) return { state: 'busy', label: 'busy', models }
  if (node.inFlight > 0) {
    return {
      state: 'answering',
      label: node.inFlight === 1 ? 'answering 1 request'
        : `answering ${node.inFlight} requests`,
      models,
    }
  }
  return { state: 'ready', label: 'ready', models }
}

/**
 * The pause control an operator is offered.
 *
 * None, when the machine's owner is the one who paused it. A button that must
 * either lie or fail is worse than a plain statement that this is not yours to
 * lift.
 */
export function pauseAction(node) {
  if (node.userPaused) return { kind: 'none', label: 'owner paused' }
  return node.state === 'paused'
    ? { kind: 'resume', label: 'Resume' }
    : { kind: 'pause', label: 'Pause' }
}

/**
 * Whether work was generated rather than asked for by somebody.
 *
 * Marked wherever it appears, because throughput from a load test reads as real
 * activity otherwise - and this repository generated exactly that kind of load
 * for days.
 */
export function isSynthetic(job) {
  const source = job.source ?? 'api'
  return source !== 'api' && source !== 'cli'
}

/** Progress through a job's units, as a count and a percentage. */
export function progressOf(job) {
  const c = job.counts ?? {}
  const total = (c.pending ?? 0) + (c.leased ?? 0) + (c.done ?? 0) + (c.failed ?? 0)
  return {
    done: c.done ?? 0,
    total,
    percent: total === 0 ? 0 : Math.round(((c.done ?? 0) / total) * 100),
  }
}

/**
 * Capacity a node contributes, which is not the same as the memory it has.
 *
 * A paused or inactive machine contributes nothing: counting it overstates the
 * fleet by exactly the machines whose owners have opted out, which is the
 * number most worth being honest about.
 */
export function capacityOf(node, headroomGb) {
  if (node.state !== 'active' || node.userPaused) return { gpu: 0, ane: 0 }
  const headroom = headroomGb ?? 0
  return { gpu: runsGpu(node) ? headroom : 0, ane: headroom }
}
