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
  // A machine holding part of a split model is not available to harvest, so it
  // is offered nothing here however healthy it looks. Showing the kinds it
  // could run would make it read as spare capacity the scheduler is failing to
  // use, which is the opposite of what is happening.
  if (node.suspended) return []
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
export function groupMismatches(pool, nodes, models, allGroups) {
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
    // Running something other than what the group serves.
    //
    // The group's serving model is a declaration, and until the machine is told
    // it stays one: a machine's model comes from the argument its daemon was
    // started with. So a group can say it serves a 14B while its two machines
    // run a 32B and a 30B, and nothing anywhere says otherwise - which is
    // exactly what this fleet was doing when somebody looked.
    // What this machine should be running, which is not always what *this*
    // group says: a cluster group overrides a harvest one where they share a
    // machine. Comparing against the group's own declaration would light up
    // every harvest group that has been legitimately overridden.
    const serves = effectiveModelFor(node, allGroups ?? [pool]) ?? pool.servingModelId
    const canServe = node.models ?? []
    if (serves && canServe.length > 0 && !canServe.includes(serves)) {
      out.push({
        nodeId: node.id, hostname: node.hostname, kind: 'wrong-model',
        reason: `${node.hostname} is running ${
          canServe.filter((m) => !m.startsWith('ane:')).map((m) => m.split('/').pop()).join(', ')
            || 'nothing'}, not this group's ${serves.split('/').pop()}`,
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
  // Two different complaints, and the label has to say which. "Cannot do what
  // this group holds" is about capability; running the wrong model is about
  // agreement, and reading the second as the first sends somebody to look at
  // memory on a machine that has plenty.
  const wrong = new Set(
    mismatches.filter((m) => m.kind === 'wrong-model').map((m) => m.hostname)).size
  const label = wrong === machines
    ? `${machines} machine${machines === 1 ? '' : 's'} not serving this group's model`
    : `${machines} machine${machines === 1 ? '' : 's'} cannot do what this group holds`
  return { level: worst, label, reasons: mismatches.map((m) => m.reason) }
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

/* -------------------------------------------------------------------- tiers */

/**
 * Which kinds of work a machine is offered for.
 *
 * Plural, and reads the old scalar too: a fleet part-way through an upgrade has
 * agents and records of both shapes, and a view that showed nothing for the old
 * ones would look like machines had lost their tier.
 */
export function tiersOf(node) {
  if (Array.isArray(node?.tiers) && node.tiers.length > 0) return node.tiers
  return [node?.tier ?? 'harvest']
}

export const TIERS = ['harvest', 'cluster']

/** A machine offered for both is worth pointing at, because of what it costs. */
export function inBothTiers(node) {
  const tiers = tiersOf(node)
  return tiers.includes('harvest') && tiers.includes('cluster')
}

/**
 * What clicking a tier on a machine does.
 *
 * Tiers used to be a panel a machine was dragged onto, which put them beside
 * groups as though the two were alternative arrangements of one fleet. They are
 * not: a machine's tier is what it may be *claimed for*, and a group is what
 * claims it - `whyNotInPool` refuses a cluster group any machine not already
 * offered for cluster. So this is a property of the machine, edited where
 * machines are listed.
 *
 * Refused rather than silently ignored when it would leave a machine offered for
 * nothing. Such a machine still runs, still heartbeats and never gets work,
 * which looks exactly like a broken agent and sends somebody to read logs.
 */
export function tierToggle(node, tier) {
  const has = tiersOf(node).includes(tier)
  const next = tiersAfter(node, tier, has ? 'remove' : 'add')
  if (!next) {
    return { refused: `${node.hostname} has to be offered for something. A machine `
      + 'offered for nothing still runs and still reports in, but never gets work.' }
  }
  return { action: has ? 'remove' : 'add', next }
}

/**
 * What to ask before putting this machine in this group, or null to just do it.
 *
 * The same condition `whyNotInPool` applies, asked one step earlier. The server
 * already refuses this with a 409; without asking here the console simply
 * reported the refusal and stopped, and the operator had to go and grant the
 * tier somewhere else and come back. The precondition is real - it should be a
 * sentence at the moment it matters, not a separate screen.
 *
 * A console that disagreed with the scheduler would be worse than none, so the
 * rule is asserted against `whyNotInPool` itself rather than described twice.
 */
export function needsTierFor(node, pool) {
  if (pool?.tier !== 'cluster') return null
  if (tiersOf(node).includes('cluster')) return null
  return {
    tier: 'cluster',
    next: tiersAfter(node, 'cluster', 'add'),
    question: `${node.hostname} is not offered for cluster work, and `
      + `${pool.name} is a cluster group.\n\nOffer it for cluster as well? `
      + `${describeTier('cluster')}.`,
  }
}

/**
 * Machines in a group that are also someone's workstation.
 *
 * Carried over from the tier panel, which is the only place this was said. A
 * cluster group is never preempted, so a request can land on one of these while
 * its owner is using it - which is a consequence of how the group was built and
 * belongs on the group, not on a list of tiers.
 */
export function bothTiersNote(members) {
  const shared = (members ?? []).filter(inBothTiers)
  if (shared.length === 0) return null
  return {
    count: shared.length,
    hostnames: shared.map((n) => n.hostname),
    label: `${shared.length} also harvest`,
    detail: 'These machines belong to people. An interactive request can land on '
      + 'one while its owner is using it.',
  }
}

/**
 * What a tier means, in the terms the person changing it needs.
 *
 * The cluster line states a consequence rather than a definition. Putting a
 * workstation in the cluster tier means an interactive request can land on it
 * while its owner is using it, and somebody dragging a machine there is
 * entitled to know that before they let go.
 */
export function describeTier(tier) {
  return tier === 'cluster'
    ? 'never preempted; presence does not gate serving, so a request can land '
      + 'here while somebody is using the machine'
    : 'borrowed while nobody is using it, and given back the moment they return'
}

/**
 * The tiers a machine would have after a change, or null if the change is
 * refused.
 *
 * Adding is what a drag means here: a machine dropped on the cluster tier is
 * offered for cluster work *as well*, not moved. That is the difference from
 * groups, where a drag moves a machine between them.
 *
 * Removing the last tier is refused rather than applied. A machine offered for
 * nothing still runs, still heartbeats and never receives work, which looks
 * exactly like a broken agent.
 */
export function tiersAfter(node, tier, action) {
  const current = new Set(tiersOf(node))
  if (action === 'add') {
    if (current.has(tier)) return null
    current.add(tier)
  } else {
    if (!current.has(tier)) return null
    current.delete(tier)
    if (current.size === 0) return null
  }
  return TIERS.filter((t) => current.has(t))
}

/* ------------------------------------------------------------- api explorer */

/**
 * The contract, as something a page can draw and call.
 *
 * The console has always linked to a rendered copy of the OpenAPI document,
 * which is good for reading and useless for finding out what an endpoint
 * actually returns on this fleet. Answering that meant leaving the console,
 * finding a token, and writing a curl line - so in practice nobody did, and the
 * API stayed a document rather than something operators used.
 *
 * These functions turn the document into operations a view can list, expand and
 * send, and they live here rather than in the page because every one of them is
 * a judgement worth checking: which surface an endpoint belongs to, whether the
 * browser can call it at all, and what a starting request body should look like.
 */

/** Every operation in the document, flattened and ordered for a person. */
export function operationsFrom(spec) {
  const METHODS = ['get', 'post', 'put', 'patch', 'delete']
  const out = []
  for (const [path, item] of Object.entries(spec?.paths ?? {})) {
    for (const method of METHODS) {
      const op = item?.[method]
      if (!op) continue
      const params = [...(item.parameters ?? []), ...(op.parameters ?? [])]
      out.push({
        id: `${method}:${path}`,
        method: method.toUpperCase(),
        path,
        surface: surfaceOf(path),
        tag: op.tags?.[0] ?? surfaceOf(path),
        summary: op.summary ?? '',
        description: op.description ?? '',
        params: params.map((p) => ({
          name: p.name, in: p.in, required: !!p.required,
          description: p.description ?? '',
        })),
        requestBody: op.requestBody?.content?.['application/json']?.schema ?? null,
        bodyRequired: !!op.requestBody?.required,
        responses: Object.keys(op.responses ?? {}).sort(),
      })
    }
  }
  return out
}

/**
 * Which surface an endpoint belongs to, which decides whether this page can
 * call it at all.
 *
 * The agent surface is mutually authenticated with a node's client certificate.
 * A browser has no such certificate and never will, so those operations are
 * listed and not sendable - shown rather than hidden, because "why can I not
 * call this" is a question the page should answer rather than avoid.
 */
export function surfaceOf(path) {
  if (path.startsWith('/agent/')) return 'agent'
  if (path.startsWith('/admin/')) return 'admin'
  if (path.startsWith('/monitor/')) return 'monitor'
  if (path.startsWith('/v1/') || path.startsWith('/serving/')) return 'serving'
  return 'other'
}

/** Whether the console's own session can send this. */
export function callableHere(op) {
  return op.surface === 'admin' || op.surface === 'monitor'
}

export function whyNotCallable(op) {
  if (op.surface === 'agent') {
    return 'mutually authenticated with a node certificate, which a browser does not have'
  }
  if (op.surface === 'serving') {
    return 'served on the inference surface, which takes an API key rather than a session'
  }
  return 'not reachable from this page'
}

/**
 * Whether sending this can change something.
 *
 * Used to put a confirmation in front of the ones that can. An explorer exists
 * to be clicked on by somebody finding out what an endpoint does, and the
 * endpoint they are most curious about is the one that revokes a machine.
 */
export function isReadOnly(op) {
  return op.method === 'GET' || op.method === 'HEAD'
}

/** Operations grouped under their tag, each group sorted by path then method. */
export function groupOperations(ops) {
  const byTag = new Map()
  for (const op of ops) {
    if (!byTag.has(op.tag)) byTag.set(op.tag, [])
    byTag.get(op.tag).push(op)
  }
  const order = ['admin', 'agent', 'monitor', 'serving']
  return [...byTag.entries()]
    .map(([tag, operations]) => ({
      tag,
      operations: operations.sort((a, b) =>
        a.path.localeCompare(b.path) || a.method.localeCompare(b.method)),
    }))
    .sort((a, b) => {
      const ai = order.indexOf(a.tag), bi = order.indexOf(b.tag)
      return (ai === -1 ? order.length : ai) - (bi === -1 ? order.length : bi)
        || a.tag.localeCompare(b.tag)
    })
}

/** Free-text search over the things somebody would actually type. */
export function matchesOperation(op, query) {
  const q = (query ?? '').trim().toLowerCase()
  if (!q) return true
  return [op.path, op.method, op.summary, op.tag].join(' ').toLowerCase().includes(q)
}

/**
 * Follow a `$ref` to the schema it names.
 *
 * Only local refs, which is all this document has. A remote one would be a
 * network fetch from a page rendering a contract, and the contract is supposed
 * to be self-contained.
 */
export function resolveRef(spec, schema, seen = new Set()) {
  let node = schema
  while (node && typeof node.$ref === 'string') {
    if (seen.has(node.$ref)) return null
    seen.add(node.$ref)
    if (!node.$ref.startsWith('#/')) return null
    node = node.$ref.slice(2).split('/').reduce((o, k) => o?.[k], spec)
  }
  return node ?? null
}

/**
 * A request body to start from, built from the schema.
 *
 * A blank box is a worse starting point than a wrong one: it makes the reader
 * go and find the schema themselves, which is the errand this page exists to
 * remove. Required properties are filled first and always present, so what
 * appears is a request that has a chance of being accepted rather than an
 * inventory of every optional field.
 */
export function bodySkeleton(spec, schema, depth = 0) {
  const node = resolveRef(spec, schema)
  if (!node || depth > 4) return null
  if (node.example !== undefined) return node.example
  if (node.default !== undefined) return node.default
  if (Array.isArray(node.enum) && node.enum.length) return node.enum[0]

  switch (node.type) {
    case 'object': {
      const out = {}
      const required = new Set(node.required ?? [])
      const props = Object.entries(node.properties ?? {})
      // Required first, then the rest, so the shape reads as the minimum
      // request with the options after it.
      for (const [name, sub] of props.filter(([n]) => required.has(n))) {
        out[name] = bodySkeleton(spec, sub, depth + 1)
      }
      for (const [name, sub] of props.filter(([n]) => !required.has(n))) {
        out[name] = bodySkeleton(spec, sub, depth + 1)
      }
      return out
    }
    case 'array':
      return node.items ? [bodySkeleton(spec, node.items, depth + 1)] : []
    case 'integer':
    case 'number':
      return 0
    case 'boolean':
      return false
    case 'string':
      return node.format === 'date-time' ? new Date(0).toISOString()
        : node.format === 'uuid' ? '00000000-0000-0000-0000-000000000000' : ''
    default:
      return null
  }
}

/**
 * The URL to send, with path parameters substituted and query parameters
 * appended.
 *
 * Returns an error rather than a half-built URL when a required path parameter
 * is missing. Sending `/admin/v1/nodes//approve` produces a 404 that reads like
 * the endpoint does not exist, and the reader concludes the wrong thing about
 * the API rather than about their own empty box.
 */
export function buildUrl(op, values = {}) {
  const missing = []
  let path = op.path
  for (const p of op.params.filter((p) => p.in === 'path')) {
    const v = (values[p.name] ?? '').trim()
    if (!v) { missing.push(p.name); continue }
    path = path.replace(`{${p.name}}`, encodeURIComponent(v))
  }
  if (missing.length) return { error: `needs ${missing.join(', ')}` }

  const query = new URLSearchParams()
  for (const p of op.params.filter((p) => p.in === 'query')) {
    const v = (values[p.name] ?? '').trim()
    if (v) query.set(p.name, v)
  }
  const qs = query.toString()
  return { url: qs ? `${path}?${qs}` : path }
}

/** Pretty JSON when it is JSON, and the raw text when it is not. */
export function formatResponse(text, contentType = '') {
  if (!text) return ''
  if (!contentType.includes('json')) return text
  try {
    return JSON.stringify(JSON.parse(text), null, 2)
  } catch {
    // A body that claims to be JSON and is not is worth seeing exactly as it
    // arrived, because that mismatch is itself the finding.
    return text
  }
}

/**
 * The size of a response body.
 *
 * Not `humanBytes`, which rounds to kilobytes because it measures model files
 * and a real one should never read as "0 kB". A response body is routinely two
 * hundred bytes, and rounding that to zero says the endpoint returned nothing
 * when it returned the answer.
 */
export function responseSize(bytes) {
  if (!Number.isFinite(bytes) || bytes < 0) return '-'
  if (bytes < 1000) return `${bytes} B`
  if (bytes < 1e6) return `${(bytes / 1e3).toFixed(1)} kB`
  return `${(bytes / 1e6).toFixed(1)} MB`
}

/** How a status code should read at a glance. */
export function statusTone(status) {
  if (status >= 200 && status < 300) return 'good'
  if (status >= 400 && status < 500) return 'warn'
  if (status >= 500) return 'bad'
  return 'flat'
}

/**
 * Where a node's certificate stands, and whether asking for a new one is worth
 * offering.
 *
 * The renewal control cannot be a plain button. A node's key lives in the
 * Secure Enclave and signs only inside the launchd daemon, so the request rides
 * the heartbeat the node already sends: nothing happens the moment it is
 * pressed, and a node that is asleep acts on it when it next reports in. That
 * makes two states worth distinguishing from "no".
 *
 * **Already asked.** The flag is set and cleared by the node, not by a timer,
 * so a second press changes nothing. Showing when it was asked says the request
 * is standing rather than lost, which is the difference between waiting and
 * pressing the button again every time the drawer is opened.
 *
 * **Expired.** An expired certificate cannot authenticate, so the node cannot
 * heartbeat, so it can never be told to renew. Offering the control there is
 * offering something that provably will not work - that machine needs
 * re-enrolling, and saying so is the only useful answer.
 */
export function certificateStanding(node, now = Date.now()) {
  const at = node.certNotAfter ? Date.parse(node.certNotAfter) : NaN
  const known = Number.isFinite(at)
  const days = known ? Math.floor((at - now) / 86_400_000) : null
  const expired = known && at <= now
  const asked = node.renewRequestedAt ?? null
  return {
    days,
    expired,
    asked,
    // Warned rather than merely counted: renewal happens on its own at two
    // thirds of life, so a certificate inside a week of expiry means the
    // automatic path has not run and somebody should look.
    state: !known ? 'unknown' : expired ? 'expired' : days < 7 ? 'expiring' : 'valid',
    canAsk: !asked && !expired,
    detail: !known ? 'expiry unknown'
      : expired ? 'expired; this machine has to be re-enrolled'
        : `${days} days`,
  }
}

/**
 * Why a machine is idle, when the reason is not idleness.
 *
 * A machine holding part of a split model looks exactly like a quiet one: it is
 * active, unpaused, healthy, and taking no work. The difference is that it is
 * doing precisely what it was told to, and there is nothing to fix - so the
 * fleet view has to say which, or an operator spends the evening looking for a
 * fault that does not exist.
 *
 * Returns null for every machine that is genuinely just idle, which is nearly
 * all of them.
 */
export function suspensionNote(node) {
  const s = node.suspended
  if (!s) return null
  const model = String(s.modelId).split('/').pop()
  const from = (s.from ?? []).length > 0
    ? ` (not available to ${s.from.join(' or ')})`
    : ''
  return `holding part of ${model} across ${s.machines} machines for ${s.by}${from}`
}

/**
 * What a machine should be running, given every group it is in.
 *
 * The browser's copy of the rule the control plane applies: a cluster group
 * overrides a harvest one where they share a machine, because only one of the
 * two promises survives on a single box and it is not the preemptible one.
 *
 * Duplicated deliberately rather than fetched. The fleet view has to be able to
 * say "this machine is running the wrong thing" without a round trip per row,
 * and the alternative - trusting a field the server computed - hides exactly the
 * disagreement this is here to show.
 */
export function effectiveModelFor(node, groups) {
  const mine = (groups ?? []).filter((g) => matchesGroup(node, g) && g.servingModelId)
  const cluster = mine.find((g) => g.tier === 'cluster')
  return (cluster ?? mine[0])?.servingModelId ?? null
}

/**
 * How wide a model is, for a list where every other row is one machine.
 *
 * A repository path says nothing about this. `Qwen2.5-14B-Instruct-4bit` looks
 * like every other model and is not: serving it engages two machines at once,
 * needs a group set up for it, and takes those machines out of harvesting while
 * it stands.
 *
 * Empty for the ordinary case, so a listing is not decorated with "1 machine"
 * on every row - the whole point is that the split ones stand out.
 */
export function splitNote(machines) {
  const n = Math.max(1, Math.trunc(Number(machines) || 1))
  return n > 1 ? `${n} machines` : ''
}

/**
 * What a model's own figure means, which is not what a group's means.
 *
 * `models.machines` is the fewest machines the weights can run on. It used to
 * be the deployment as well, so serving a model wide in one group made it wide
 * for every caller, and the catalogue read "2 machines" for an 8.3 GB model that
 * fits on either machine alone. Saying "needs" is the difference between a
 * requirement and a decision.
 */
export function minimumNote(machines) {
  const n = Math.max(1, Math.trunc(Number(machines) || 1))
  return n > 1 ? `needs ${n} machines` : ''
}

/**
 * How wide a group actually runs what it serves.
 *
 * The group's choice where it has made one, the model's minimum otherwise.
 * Shown only when it is more than one machine, because "across 1 machine" is
 * what everything does and says nothing.
 */
export function deploymentNote(pool, model) {
  const wants = pool?.servingMachines
  const minimum = Math.max(1, Math.trunc(Number(model?.machines) || 1))
  const n = wants === null || wants === undefined
    ? minimum
    : Math.max(minimum, Math.trunc(Number(wants) || 1))
  return n > 1 ? `across ${n} machines` : ''
}

/* -------------------------------------------------------------- readiness */

/**
 * How a split group's readiness reads on its card.
 *
 * The distinction the whole strip exists to draw is **preparing** against
 * **blocked**. Preparing resolves on its own and the operator waits; blocked
 * needs somebody to go and look at a machine. Reporting both as "not ready"
 * turns a two-minute wait and a fault into the same sentence, which is how an
 * operator learns to ignore the line.
 */
export function readinessSummary(r) {
  if (!r) return { level: 'unknown', label: 'unknown', detail: '' }
  switch (r.state) {
    case 'ready':
      return { level: 'good', label: 'ready', detail: r.detail }
    case 'preparing':
      // Named for what it is doing rather than what it lacks. "Missing weights"
      // reads as a fault; "fetching" reads as progress, and it is progress.
      return { level: 'busy', label: 'preparing', detail: r.detail }
    case 'blocked':
      return { level: 'bad', label: 'needs attention', detail: r.detail }
    default:
      // Idle covers two states that mean opposite things. A group an operator
      // stood down is a decision; a standing group nobody has staged anything
      // to is a thing to go and do, and calling it "stood down" would describe
      // it as already handled.
      return r.standing
        ? { level: 'idle', label: 'nothing staged', detail: r.detail }
        : { level: 'idle', label: 'stood down', detail: r.detail }
  }
}

/**
 * What a group serves, as a phrase rather than a model id or a blank.
 *
 * A cluster group with no model used to render as an empty cell, which read as
 * "not set up yet". It is now a group that serves whichever staged model is
 * asked for, and that is a thing it does rather than a thing missing from it.
 */
export function servingLine(pool) {
  if (pool?.servingModelId) {
    return { pinned: true, label: String(pool.servingModelId).split('/').pop(),
             title: pool.servingModelId }
  }
  if (pool?.tier === 'cluster') {
    return { pinned: false, label: 'whatever is staged',
             title: 'Serves whichever staged model a caller asks for, loading it at '
               + 'dispatch. The first request for a model it is not already holding '
               + 'pays the build.' }
  }
  return { pinned: false, label: '-', title: 'No model assigned' }
}

/**
 * The staged models on the readiness strip, worst first.
 *
 * A staged model on fewer machines than it needs is a request that will be
 * refused, so it is the line an operator has to act on and belongs at the top.
 */
export function stagedLines(r) {
  return [...(r?.staged ?? [])]
    .sort((a, b) => (a.ready === b.ready ? a.modelId.localeCompare(b.modelId)
                                         : (a.ready ? 1 : -1)))
    .map((s) => ({
      label: String(s.modelId).split('/').pop(),
      modelId: s.modelId,
      ready: s.ready,
      note: s.ready
        ? (s.machines > 1 ? `ready across ${s.machines} machines` : 'ready')
        : `on ${s.held} of the ${s.machines} machines it needs`,
    }))
}

/**
 * What unpinning a group does, said before it is done.
 *
 * The reassurance matters as much as the warning. An operator reads "unpin" as
 * "throw the setup away", and the expensive part - the weights - is exactly
 * what stays.
 */
export function unpinConsequences(pool, staged) {
  const held = staged ?? []
  const out = [
    { level: 'note',
      text: `keeps every model already pushed to ${pool?.name ?? 'this group'}; `
        + 'nothing is fetched again and nothing is deleted' },
  ]
  if (held.length === 0) {
    out.push({ level: 'blocked',
      text: 'nothing has been staged to this group yet, so it would have nothing '
        + 'to serve - push a model to it first' })
  } else {
    out.push({ level: 'note',
      text: `it will answer for any of ${held.length} staged model`
        + `${held.length === 1 ? '' : 's'}` })
  }
  // The sharp edge, where the choice is made rather than where it is felt.
  out.push({ level: 'cost',
    text: 'the first request for a model it is not already holding pays the build '
      + '- around a minute for a 32B across two machines - so this suits several '
      + 'models used in turn rather than two callers wanting different ones at once' })
  return out
}

/**
 * One machine's line in the strip.
 *
 * Rank is shown only once ranks can be assigned, which needs a machine that can
 * be dialled. Showing "rank 0" for a group that cannot form would name a role
 * nobody is holding.
 */
export function rankLine(rank) {
  const where = rank.rank === null ? '' : `rank ${rank.rank}`
  const role = rank.role === 'output head' ? ' · head' : ''
  const marks = [
    rank.weights === 'present' ? 'weights' : 'no weights',
    rank.loaded ? 'loaded' : 'not loaded',
    rank.dialable ? 'dialable' : 'no address',
  ]
  return { hostname: rank.hostname, where: where + role, state: rank.state,
           marks, detail: rank.detail }
}

/**
 * Whether the strip is worth polling again.
 *
 * A group that is preparing will change on its own; one that is ready or
 * blocked will not, and polling it forever is a request every few seconds for
 * an answer nobody is waiting on.
 */
export function shouldKeepWatching(r) {
  return r?.state === 'preparing'
}

/* ------------------------------------------------------- serving a model */

/**
 * Which models a group could be told to serve.
 *
 * Everything the fleet knows about, not only what these machines already hold:
 * telling a group to serve something is also telling it to fetch it, and
 * offering only what is already here would make the console unable to express
 * the ordinary case of deploying something new.
 *
 * Embedding models are excluded. They answer a different endpoint and a group
 * cannot serve one as its model, so listing them offers a choice that produces
 * a confusing failure rather than an error.
 */
export function servableChoices(models) {
  return (models ?? [])
    .filter((m) => !String(m.id ?? '').startsWith('ane:'))
    .map((m) => ({
      id: m.id,
      label: String(m.id).split('/').pop(),
      sizeBytes: m.sizeBytes ?? 0,
      machines: Math.max(1, Number(m.machines ?? 1)),
    }))
    .sort((a, b) => a.label.localeCompare(b.label))
}

/**
 * What serving this model at this width will do, said before it is done.
 *
 * Two facts an operator needs and one warning they cannot otherwise discover.
 * `machines` is a column on the model rather than on the assignment, so setting
 * a width here sets it everywhere - a second cluster group serving the same
 * model gets the same division, and its machines rebuild. That is not something
 * to find out afterwards.
 */
export function serveConsequences(choice, machinesWanted, groupSize, otherGroups) {
  const out = []
  const machines = Math.max(1, Number(machinesWanted ?? 1))

  if (machines > 1) {
    out.push({ level: 'cost',
      text: `takes ${machines} machines out of harvesting for as long as it stands` })
  }
  if (groupSize && machines > groupSize) {
    out.push({ level: 'blocked',
      text: `this group has ${groupSize} machine${groupSize === 1 ? '' : 's'} and `
        + `${machines} are needed` })
  }
  // Only worth saying when it is actually about to change something else.
  const elsewhere = (otherGroups ?? []).filter((g) => g.servingModelId === choice?.id)
  if (elsewhere.length > 0 && choice && machines !== choice.machines) {
    out.push({ level: 'warn',
      text: `${choice.label} is also served by `
        + elsewhere.map((g) => g.name).join(', ')
        + `, and the width belongs to the model - they will run it across `
        + `${machines} too, and rebuild` })
  }
  return out
}

/**
 * The address a caller should point at this group.
 *
 * The catalogue says which model ids run across machines; nothing says which
 * port reaches which group. With one group that is obvious and with several it
 * is the only question, and an operator who has to look a port up in a database
 * is one who will point an application at the wrong group's machines.
 */
export function groupAddress(pool, origin) {
  if (!pool?.servingPort) return null
  const host = (() => {
    try { return new URL(origin).hostname } catch { return 'localhost' }
  })()
  return `https://${host}:${pool.servingPort}`
}

/**
 * How long a join token has left, in the coarsest unit that is still true.
 *
 * Hours up to two days and days beyond that, because the decision a token's
 * expiry informs is "will this still work when I get to that machine", and an
 * answer to the minute invites reading it as a countdown.
 *
 * An expired token is called expired rather than shown as a negative interval.
 * It is still listed, because it is still a row somebody may want to revoke and
 * tidy away, but it can no longer let a machine in.
 */
export function expiresIn(iso, now = Date.now()) {
  if (!iso) return 'never'
  const at = new Date(iso).getTime()
  if (!Number.isFinite(at)) return 'unknown'
  const ms = at - now
  if (ms <= 0) return 'expired'
  const hours = Math.round(ms / 3_600_000)
  if (hours < 1) return 'under an hour'
  return hours < 48 ? `in ${hours}h` : `in ${Math.round(hours / 24)}d`
}

/**
 * Whether an idle-unload window means anything for this group.
 *
 * A cluster group with a model pinned to it is never sent one: dedicated means
 * loaded, and a window would describe a release that never happens. An
 * *unpinned* cluster group does need one, because it holds whatever it was last
 * asked for, and without a window the first caller's model stays in memory for
 * as long as the group stands - chosen by whoever asked first rather than by an
 * operator.
 *
 * Returned as a reason rather than a boolean so the control can say why it is
 * absent instead of simply not being there.
 */
export function idleWindowApplies(pool) {
  if (!pool) return { applies: false, why: 'no group' }
  if (pool.tier === 'cluster' && pool.servingModelId) {
    return {
      applies: false,
      why: 'a cluster group pinned to a model holds it loaded; there is nothing '
         + 'to release',
    }
  }
  return { applies: true, why: '' }
}

/**
 * How a knob's current value reads when nobody has set one.
 *
 * "Not set" and "set to the same number as the default" are different facts: the
 * first follows the fleet if the fleet changes, the second does not.
 */
export function knobLabel(value, fallback, unit) {
  return value === null || value === undefined
    ? `fleet default (${fallback}${unit})`
    : `${value}${unit}`
}
