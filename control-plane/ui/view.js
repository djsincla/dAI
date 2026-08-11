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
  // No render. The work kind exists in the schema and the scheduler understands
  // it, but no agent implements it and none advertises it, so listing it here
  // told a reader the fleet could do something it cannot. The fleet view has to
  // agree with what the machines actually offer.
  return runsGpu(node) ? ['embed', 'generate'] : ['embed']
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

/**
 * What a model's distribution looks like across the fleet.
 *
 * Two numbers that were briefly computed over different sets of machines and
 * disagreed with each other on screen: one counted every node row the database
 * had ever held, including retired ones, and the other counted only active
 * machines. The catalogue said one node held the 32B while the placement list
 * underneath it showed nobody did.
 *
 * States, in the order they matter to somebody looking:
 *   `drift`     some machines want it and do not have it, which is the only
 *               state that calls for action
 *   `complete`  every machine that should have it does
 *   `unused`    on machines, assigned nowhere, which is what hand-staging
 *               leaves behind and what nothing could show before
 *   `idle`      registered, assigned nowhere, on nothing
 */
export function distributionOf(model) {
  const holding = model.nodesHolding ?? 0
  const wanting = model.nodesWanting ?? 0
  const assigned = (model.assignedPools ?? []).length > 0

  if (wanting > 0) {
    return {
      state: 'drift',
      label: `${wanting} machine${wanting === 1 ? '' : 's'} missing it`,
      holding, wanting,
    }
  }
  if (assigned) return { state: 'complete', label: `on all ${holding}`, holding, wanting }
  if (holding > 0) {
    // Weights nobody asked for. Worth naming rather than showing as fine: it is
    // how every model on this fleet arrived, and it means the catalogue is
    // describing something no policy would reproduce.
    return { state: 'unused', label: `on ${holding}, assigned to no pool`, holding, wanting }
  }
  return { state: 'idle', label: 'registered only', holding, wanting }
}

/** Bytes as something a person reads, without pretending to precision. */
export function humanBytes(n) {
  const bytes = Number(n)
  if (!Number.isFinite(bytes) || bytes < 0) return '—'
  if (bytes < 1e6) return `${Math.round(bytes / 1e3)} kB`
  if (bytes < 1e9) return `${Math.round(bytes / 1e6)} MB`
  return `${(bytes / 1e9).toFixed(1)} GB`
}

/**
 * What one machine's copy of a model is doing.
 *
 * `held` is on disk and `loaded` is in memory, and conflating them is what made
 * a machine with eighteen gigabytes of weights report holding nothing. A node
 * that holds every model it was given and has none loaded is the normal resting
 * state of a healthy machine, not a problem.
 */
export function copyState(placement) {
  if (!placement.held && placement.wanted) return { state: 'missing', label: 'missing' }
  if (!placement.held) return { state: 'absent', label: '—' }
  if (placement.loaded) return { state: 'loaded', label: 'loaded' }
  if (!placement.wanted) return { state: 'stray', label: 'on disk, unassigned' }
  return { state: 'stored', label: 'on disk' }
}

/**
 * How many machines could actually hold a model.
 *
 * The question anybody asks before adding one, and the reason a size in
 * gigabytes is not a useful answer on its own: this fleet spans a 48GB M4 Pro
 * and a 64GB M2 Max, and a 70B model is above the ceiling on both. Offering it
 * without saying so invites a forty gigabyte download that can never be loaded.
 *
 * The ceiling is half of unified memory, from E2, and not Metal's own limit:
 * Metal caps itself near 81%, and taking that much would leave the person at
 * the machine with what is left, which is the opposite of the arrangement.
 */
export function machinesThatCouldHold(sizeBytes, nodes) {
  const gb = Number(sizeBytes) / 1e9
  if (!Number.isFinite(gb) || gb <= 0) return { fits: nodes.length, total: nodes.length }
  const fits = nodes.filter((n) => {
    const memory = Number(n.memoryGb ?? n.memory_gb ?? 0)
    return memory > 0 && memory / 2 >= gb
  }).length
  return { fits, total: nodes.length }
}

/**
 * What importing a candidate would cost.
 *
 * `local` is a copy on this machine. `remote` crosses the building's uplink,
 * which is the thing this product exists to avoid doing casually, so it is
 * named rather than implied by a missing word.
 */
export function importCost(candidate) {
  if (candidate.registered) return { state: 'registered', label: 'already in the catalogue' }
  return candidate.source === 'local'
    ? { state: 'local', label: 'on this machine, copy only' }
    : { state: 'remote', label: 'downloads from the internet' }
}

/**
 * What needs somebody's attention, in the order it needs it.
 *
 * The fleet view showed five tables of equal weight and left the reader to work
 * out whether anything was wrong. That is tolerable at four machines and
 * useless at forty, and it is the wrong division of labour either way: the
 * control plane already knows what is out of place and was making a person
 * re-derive it by eye.
 *
 * Three levels, and the ordering between them is the point:
 *   `decide`  waiting on a human, and nothing else moves until they act
 *   `warn`    the fleet is not in the state somebody asked for
 *   `ok`      said out loud, because an empty list reads as broken
 */
/**
 * How long a machine may go quiet before it counts as gone.
 *
 * Two minutes, matching the window the scheduler already uses to decide whether
 * a node can be given work. Two different answers to "is this machine here"
 * would put the fleet view and the router in visible disagreement, with the
 * page insisting a machine is fine while nothing is ever dispatched to it.
 */
export const STALE_AFTER_MS = 2 * 60 * 1000

/**
 * Whether a machine has stopped reporting.
 *
 * A node that never reported at all is not stale, it is new: saying "stopped
 * reporting" about a machine that has not started yet sends somebody to check
 * a network that is fine.
 */
export function isStale(node, now = Date.now()) {
  if (node.state !== 'active') return false
  if (!node.lastHeartbeat) return false
  const seen = Date.parse(node.lastHeartbeat)
  return Number.isFinite(seen) && now - seen > STALE_AFTER_MS
}

/** The nodes, with the freshness judgement applied once. */
export function withFreshness(nodes, now = Date.now()) {
  return nodes.map((n) => ({ ...n, stale: isStale(n, now) }))
}

export function attentionItems({ nodes = [], models = [], jobs = [], pending = 0 } = {}) {
  const items = []

  if (pending > 0) {
    items.push({
      level: 'decide', key: 'pending-nodes',
      text: `${pending} machine${pending === 1 ? '' : 's'} waiting to be approved`,
      detail: 'A machine that enrolled and has not been let in does nothing until it is.',
      view: 'machines',
    })
  }

  // Drift, per model, because "3 machines missing something" is not actionable
  // and "3 machines missing the 32B" is.
  for (const m of models) {
    const wanting = m.nodesWanting ?? 0
    if (wanting > 0) {
      items.push({
        level: 'warn', key: `drift:${m.id}`,
        text: `${m.id} is missing on ${wanting} machine${wanting === 1 ? '' : 's'}`,
        detail: 'They will fetch it when nobody is at the machine.',
        view: 'models',
      })
    }
  }

  const offline = nodes.filter((n) => n.state === 'active' && n.stale)
  if (offline.length > 0) {
    items.push({
      level: 'warn', key: 'offline',
      text: `${offline.length} machine${offline.length === 1 ? '' : 's'} stopped reporting`,
      detail: offline.map((n) => n.hostname).join(', '),
      view: 'machines',
    })
  }

  // Owner pauses are not a fault and must never be presented as one. Shown
  // because an operator looking at reduced capacity deserves to know why, and
  // levelled as information because there is nothing for them to do about it.
  const paused = nodes.filter((n) => n.userPaused)
  if (paused.length > 0) {
    items.push({
      level: 'ok', key: 'owner-paused',
      text: `${paused.length} machine${paused.length === 1 ? '' : 's'} paused by their owner`,
      detail: 'Not a fault, and not yours to lift.',
      view: 'machines',
    })
  }

  const failed = jobs.filter((j) => (j.counts?.failed ?? 0) > 0)
  if (failed.length > 0) {
    items.push({
      level: 'warn', key: 'failed-work',
      text: `${failed.length} job${failed.length === 1 ? '' : 's'} with failed units`,
      detail: 'A unit that fails on every machine is a bad payload, not bad luck.',
      view: 'work',
    })
  }

  const serving = nodes.filter((n) => (n.models ?? []).length > 0).length
  if (nodes.length > 0 && serving === 0) {
    items.push({
      level: 'warn', key: 'nothing-served',
      text: 'No machine is holding a model',
      detail: 'The fleet can harvest but cannot answer a request.',
      view: 'models',
    })
  }

  if (items.every((i) => i.level === 'ok')) {
    items.unshift({
      level: 'ok', key: 'all-well',
      text: nodes.length === 0
        ? 'No machines enrolled yet'
        : `${nodes.length} machine${nodes.length === 1 ? '' : 's'} online, nothing needs attention`,
      detail: nodes.length === 0 ? 'Enrol one, then approve it here.' : null,
    })
  }

  const rank = { decide: 0, warn: 1, ok: 2 }
  return items.sort((a, b) => rank[a.level] - rank[b.level])
}

/**
 * How far an import has got.
 *
 * Files rather than bytes for the fraction, because file sizes in a model are
 * wildly uneven: four shards and seven small files means a byte count sits at
 * 99% while three quick files remain, and a progress bar that stalls near the
 * end reads as a hang. Bytes are still reported, as the number that says
 * whether anything is moving at all.
 */
export function importProgress(row) {
  if (row.state === 'failed') {
    return { state: 'failed', percent: 0, label: row.error ?? 'failed' }
  }
  const total = row.filesTotal ?? 0
  const done = row.filesDone ?? 0
  if (row.state === 'done') return { state: 'done', percent: 100, label: 'imported' }
  // Before the file list has been walked there is no denominator, and showing
  // 0% then would understate an import that is working.
  if (total === 0) return { state: 'running', percent: null, label: 'reading the directory' }
  return {
    state: 'running',
    percent: Math.round((done / total) * 100),
    label: `hashing and copying, ${done} of ${total} files`,
  }
}

/**
 * Whether a row matches what somebody typed.
 *
 * Every term has to match somewhere, which makes "orca 32b" mean what a person
 * means by it. Matching any term instead would make each extra word widen the
 * result set, so refining a search would return more rows than starting it.
 */
export function matchesQuery(row, query, fields) {
  const terms = String(query ?? '').toLowerCase().split(/\s+/).filter(Boolean)
  if (terms.length === 0) return true
  const hay = fields
    .map((f) => (typeof f === 'function' ? f(row) : row[f]))
    .filter((v) => v !== null && v !== undefined)
    .join(' ')
    .toLowerCase()
  return terms.every((t) => hay.includes(t))
}

/**
 * Sort rows by a named column.
 *
 * Missing values go last in both directions, rather than sorting as empty
 * string or zero. A machine whose memory was never probed belongs at the bottom
 * of a list ordered by memory, not at the top of it looking like the smallest
 * one in the fleet.
 *
 * Sorting a copy, because the caller's array is the render cache's input and
 * reordering it in place would make the cache compare unequal every time.
 */
export function sortRows(rows, key, dir, accessors) {
  const get = accessors?.[key]
  if (!get) return rows
  const sign = dir === 'desc' ? -1 : 1

  return [...rows].sort((a, b) => {
    const av = get(a)
    const bv = get(b)
    const aMissing = av === null || av === undefined || av === ''
    const bMissing = bv === null || bv === undefined || bv === ''
    if (aMissing || bMissing) return aMissing && bMissing ? 0 : aMissing ? 1 : -1
    if (typeof av === 'number' && typeof bv === 'number') return (av - bv) * sign
    return String(av).localeCompare(String(bv), undefined, { numeric: true }) * sign
  })
}

/** The next sort state when a header is clicked. */
export function nextSort(current, key) {
  if (current?.key !== key) return { key, dir: 'asc' }
  // Third click clears it, so there is a way back to the order the server
  // returned rather than only two orders somebody chose between.
  return current.dir === 'asc' ? { key, dir: 'desc' } : null
}

/* ------------------------------------------------------- capacity timeline */

/** The range the capacity graph can be dragged between. */
export const MIN_WINDOW_S = 10 * 60
export const MAX_WINDOW_S = 72 * 60 * 60

/**
 * How far the timeline moves for a drag.
 *
 * Logarithmic, so a drag across the full width covers the whole range once
 * rather than spending most of its travel in the last few hours. Linear would
 * make the difference between ten minutes and an hour occupy a pixel, which is
 * the part somebody dragging is usually trying to reach.
 *
 * Right widens the window and left narrows it: dragging right pulls more of the
 * past into view, the same direction the data comes from.
 */
export function windowFromDrag(current, deltaPx, widthPx) {
  const width = Math.max(1, widthPx)
  const span = Math.log(MAX_WINDOW_S / MIN_WINDOW_S)
  const at = Math.log(clampWindow(current) / MIN_WINDOW_S)
  const moved = (deltaPx / width) * span
  return clampWindow(Math.round(MIN_WINDOW_S * Math.exp(at + moved)))
}

export function clampWindow(seconds) {
  const n = Number(seconds)
  if (!Number.isFinite(n)) return 24 * 60 * 60
  return Math.min(MAX_WINDOW_S, Math.max(MIN_WINDOW_S, Math.round(n)))
}

/**
 * How wide each bucket should be for a given window.
 *
 * Snapped to units a person recognises rather than window/N, because an axis
 * labelled in 47 second steps is harder to read than one in minutes even when
 * it is more precise. Aiming for roughly sixty buckets: enough to show shape,
 * few enough that each holds more than one heartbeat.
 */
export function bucketFor(windowSeconds) {
  const target = clampWindow(windowSeconds) / 60
  const steps = [10, 30, 60, 300, 600, 1800, 3600, 7200, 14400]
  return steps.find((s) => s >= target) ?? steps[steps.length - 1]
}

/** How to describe the window in the corner of the chart. */
export function describeWindow(seconds) {
  const s = clampWindow(seconds)
  if (s < 3600) return `last ${Math.round(s / 60)} minutes`
  // Hours up to two days, because "last 24 hours" is how people say it and
  // "last 1 days" is how nothing says it.
  if (s < 2 * 86400) {
    const h = s / 3600
    return `last ${h % 1 === 0 ? h : h.toFixed(1)} hours`
  }
  const d = s / 86400
  return `last ${d % 1 === 0 ? d : d.toFixed(1)} days`
}

/**
 * What a machine's agent version means, against what it should be.
 *
 * Three states rather than two, because "nobody is managing this" is not the
 * same as "up to date" and showing them alike is how a fleet quietly stops
 * being updated: every machine reads as fine, and nothing is.
 */
export function rolloutState(row) {
  if (row.channel === 'external') {
    return row.desired && row.upToDate === false
      ? { state: 'drift-external', label: `expected ${row.desired}` }
      : { state: 'external', label: 'managed elsewhere' }
  }
  if (!row.desired) return { state: 'unset', label: 'no version chosen' }
  if (row.upToDate) return { state: 'current', label: 'up to date' }
  return { state: 'behind', label: `should be ${row.desired}` }
}

/**
 * How an upgrade attempt ended.
 *
 * A rollback is the outcome worth seeing: it means a machine was handed a
 * binary that did not come back, decided that for itself, and put the old one
 * back. Reported as information rather than an error, because the mechanism
 * worked exactly as designed - what failed is the build.
 */
export function upgradeOutcome(row) {
  switch (row.state) {
    case 'committed': return { state: 'good', label: `upgraded to ${row.toVersion}` }
    case 'reverted': return { state: 'rolled-back', label: `rolled back to ${row.fromVersion}` }
    case 'failed': return { state: 'bad', label: `failed before restart` }
    default: return { state: 'busy', label: `upgrading to ${row.toVersion}` }
  }
}

/* ------------------------------------------------------------------ groups */

/**
 * Whether a machine belongs to a group.
 *
 * Mirrors the server's membership rule exactly, and it has to: the first
 * version only checked hand-picked lists, so the page reported both machines as
 * belonging to nothing while the scheduler was happily dispatching to them
 * through a rule-based pool. A fleet view that disagrees with the scheduler is
 * worse than no fleet view, because it is believed.
 *
 * Kept in step by a test that runs this and the server's copy over the same
 * cases. Two runtimes, no shared module, so agreement has to be checked rather
 * than assumed.
 */
export function matchesGroup(node, pool) {
  // The one rule a hand-picked list cannot override: gang work on a
  // preemptible machine dies the moment somebody touches that keyboard.
  if (pool.tier === 'cluster' && node.tier !== 'cluster') return false

  const m = pool.membership ?? {}
  if ((m.nodeIds?.length ?? 0) > 0) return m.nodeIds.includes(node.id)

  if (m.hostnames && !m.hostnames.includes(node.hostname)) return false
  if (m.chips && (!node.chip || !m.chips.includes(node.chip))) return false
  if (m.minMemoryGb !== undefined) {
    // Unprobed memory fails the floor rather than passing it. Guessing upward
    // would place work on a machine that cannot hold it.
    const gb = Number(node.memoryGb ?? node.memory_gb)
    if (!Number.isFinite(gb) || gb < m.minMemoryGb) return false
  }
  return true
}

/** Whether a group is a hand-picked list or a rule machines match. */
export function groupMode(pool) {
  return (pool.membership?.nodeIds?.length ?? 0) > 0 ? 'list' : 'rule'
}

/**
 * Machines in a group that cannot do what the group was told to do.
 *
 * A group is the unit models are pushed to, so a machine that is in one and
 * cannot hold what the group holds is not a small inconsistency: it will fetch
 * nothing, serve nothing, and look exactly like a healthy member. That is worth
 * a mark on the group rather than a discovery three weeks later.
 *
 * Two kinds, and the first is the one that matters:
 *
 * **`too-small`** the machine cannot hold a model this group is assigned, under
 * the same half-of-unified-memory ceiling everything else here uses. It will
 * never work, whatever anybody does.
 *
 * **`overridden`** the machine is in the list but fails the group's own written
 * rules. Putting it there by hand wins, deliberately, but a rule that says one
 * thing while the membership says another is worth surfacing rather than
 * leaving for somebody to find.
 */
export function groupMismatches(pool, nodes, models) {
  const members = nodes.filter((n) => matchesGroup(n, pool))
  const assigned = models.filter((m) => (m.assignedPools ?? []).includes(pool.id))
  const out = []

  for (const node of members) {
    const memory = Number(node.memoryGb ?? node.memory_gb ?? 0)
    const ceiling = memory > 0 ? memory / 2 : 0

    for (const model of assigned) {
      const needs = Number(model.sizeBytes) / 1e9
      if (ceiling > 0 && needs > ceiling) {
        out.push({
          nodeId: node.id, hostname: node.hostname, kind: 'too-small',
          reason: `${node.hostname} has ${memory}GB and cannot hold `
            + `${model.id.split('/').pop()} (${needs.toFixed(1)}GB)`,
        })
      }
    }

    const floor = pool.membership?.minMemoryGb
    if (floor !== undefined && (memory === 0 || memory < floor)) {
      out.push({
        nodeId: node.id, hostname: node.hostname, kind: 'overridden',
        reason: `${node.hostname} is below this group's own ${floor}GB floor`,
      })
    }
    const chips = pool.membership?.chips
    if (chips && node.chip && !chips.includes(node.chip)) {
      out.push({
        nodeId: node.id, hostname: node.hostname, kind: 'overridden',
        reason: `${node.hostname} is a ${node.chip}, which this group's rules exclude`,
      })
    }
  }
  return out
}

/** The mark a group carries, if any. */
export function groupWarning(mismatches) {
  if (mismatches.length === 0) return null
  const worst = mismatches.some((m) => m.kind === 'too-small') ? 'bad' : 'warn'
  const machines = new Set(mismatches.map((m) => m.hostname)).size
  return {
    level: worst,
    label: `${machines} machine${machines === 1 ? '' : 's'} cannot do what this group holds`,
    reasons: mismatches.map((m) => m.reason),
  }
}

/**
 * Machines arranged into the groups they belong to.
 *
 * A machine can be in more than one group and appears under each, because
 * hiding the second one would make a fleet view that disagrees with the
 * scheduler. Machines in no group get their own heading rather than being left
 * out: not belonging anywhere is a state worth seeing, and it is invisible if
 * the view only draws groups.
 */
export function groupMachines(nodes, pools, matcher) {
  const groups = pools.map((p) => ({
    pool: p,
    mode: groupMode(p),
    nodes: nodes.filter((n) => matcher(n, p)),
  }))
  const grouped = new Set(groups.flatMap((g) => g.nodes.map((n) => n.id)))
  return {
    groups,
    ungrouped: nodes.filter((n) => !grouped.has(n.id)),
  }
}
