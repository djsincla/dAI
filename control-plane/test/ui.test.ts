import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { whyNotInPool } from '../src/lib/pools.js'
import {
  bodySkeleton, buildUrl, callableHere, formatResponse, groupOperations,
  groupAddress, isReadOnly, matchesOperation, operationsFrom, rankLine,
  readinessSummary, resolveRef, responseSize, servableChoices, serveConsequences,
  shouldKeepWatching, statusTone, surfaceOf,
  servingLine, stagedLines, unpinConsequences,
} from '../ui/view.js'
import {
  TIERS, describeTier, inBothTiers, tiersAfter, tiersOf,
  tierToggle, needsTierFor, bothTiersNote,
  attentionItems, capacityOf, copyState, distributionOf, humanBytes, importCost,
  bucketFor, certificateStanding, clampWindow, effectiveModelFor, groupMismatches,
  splitNote, suspensionNote, describeWindow, groupMachines,
  groupMode, groupWarning, importProgress, isStale, isSynthetic, kindsFor,
  expiresIn, idleWindowApplies, knobLabel,
  machinesThatCouldHold, matchesQuery, MAX_WINDOW_S, MIN_WINDOW_S, nextSort,
  pauseAction, progressOf, runsGpu, servingFor, sortRows, windowFromDrag,
  withFreshness,
} from '../ui/view.js'

/**
 * The judgements the fleet view makes on a reader's behalf.
 *
 * These were previously reachable only by loading a page against a live control
 * plane, so nothing checked them - and they are exactly the claims somebody
 * will trust without checking: whether a machine is available, whether work is
 * real or a load test, whether a pause is one they may lift. A fleet view that
 * is confidently wrong is worse than no fleet view.
 */
describe('what the fleet view says about a node', () => {
  const node = (over: Record<string, unknown> = {}) => ({
    id: 'n1', hostname: 'rotorua', state: 'active', tier: 'harvest',
    presenceState: 'ACTIVE', userPaused: false, models: [], serving: false,
    inFlight: 0, ...over,
  }) as any

  it('withholds GPU work while somebody is at the machine', () => {
    expect(runsGpu(node({ presenceState: 'ACTIVE' }))).toBe(false)
    expect(kindsFor(node({ presenceState: 'ACTIVE' }))).toEqual(['embed'])
  })

  it('offers GPU work once the machine is locked', () => {
    expect(runsGpu(node({ presenceState: 'LOCKED' }))).toBe(true)
    expect(kindsFor(node({ presenceState: 'LOCKED' }))).toContain('generate')
  })

  it('does not advertise a kind of work no machine can do', () => {
    // `render` exists in the schema and the scheduler understands it, but no
    // agent implements it and none offers it. Listing it here told a reader the
    // fleet could do something it cannot, and the fleet view has to agree with
    // what the machines actually advertise.
    expect(kindsFor(node({ presenceState: 'LOCKED' }))).not.toContain('render')
    expect(kindsFor(node({ presenceState: 'LOCKED' }))).toEqual(['embed', 'generate'])
  })

  it('does not presence-gate a cluster node', () => {
    // A dedicated box has nobody sitting at it, and gating it on presence would
    // make an interactive session depend on whether a keyboard attached to a
    // server had been touched.
    expect(runsGpu(node({ tier: 'cluster', presenceState: 'ACTIVE' }))).toBe(true)
  })

  it('shows no work at all for a machine its owner paused', () => {
    // Not a machine that happens to be idle. Listing what it could do implies
    // the pause is advisory.
    expect(kindsFor(node({ presenceState: 'LOCKED', userPaused: true }))).toEqual([])
    expect(runsGpu(node({ presenceState: 'LOCKED', userPaused: true }))).toBe(false)
  })

  it('offers an operator no way to lift the owner\'s pause', () => {
    // A control that must either lie or fail is worse than a plain statement.
    expect(pauseAction(node({ userPaused: true })).kind).toBe('none')
    expect(pauseAction(node({ state: 'paused' })).kind).toBe('resume')
    expect(pauseAction(node()).kind).toBe('pause')
  })

  it('counts no capacity for a paused or inactive machine', () => {
    // Counting them overstates the fleet by exactly the machines whose owners
    // have opted out.
    expect(capacityOf(node({ userPaused: true }), 30)).toEqual({ gpu: 0, ane: 0 })
    expect(capacityOf(node({ state: 'offline' }), 30)).toEqual({ gpu: 0, ane: 0 })
    expect(capacityOf(node({ presenceState: 'LOCKED' }), 30)).toEqual({ gpu: 30, ane: 30 })
    // ANE work runs in every state, so a machine in use still contributes.
    expect(capacityOf(node({ presenceState: 'ACTIVE' }), 30)).toEqual({ gpu: 0, ane: 30 })
  })
})

describe('what the fleet view says about serving', () => {
  const node = (over: Record<string, unknown> = {}) => ({
    state: 'active', tier: 'cluster', presenceState: 'ACTIVE', userPaused: false,
    models: ['mlx-community/Qwen2.5-Coder-32B-Instruct-4bit'], serving: true,
    inFlight: 0, ...over,
  }) as any

  it('says busy, not gone, while a node is mid-request', () => {
    // A node reading a large prompt is off the channel for minutes while being
    // entirely healthy. Reporting that as unavailable sent somebody looking for
    // a crash that had not happened.
    expect(servingFor(node({ serving: false })).state).toBe('busy')
  })

  it('says how many requests are in flight', () => {
    expect(servingFor(node({ inFlight: 1 })).label).toBe('answering 1 request')
    expect(servingFor(node({ inFlight: 3 })).label).toBe('answering 3 requests')
  })

  it('says nothing for a node serving no models', () => {
    expect(servingFor(node({ models: [] })).state).toBe('none')
  })

  it('is ready when it holds a model and is on the channel', () => {
    expect(servingFor(node()).state).toBe('ready')
  })
})

describe('what the fleet view says about work', () => {
  it('marks work that was generated rather than asked for', () => {
    // This repository produced exactly this kind of load for days; unmarked, its
    // throughput reads as the studio's real activity.
    expect(isSynthetic({ source: 'test-harness' } as any)).toBe(true)
    expect(isSynthetic({ source: 'demo-seed' } as any)).toBe(true)
    expect(isSynthetic({ source: 'api' } as any)).toBe(false)
    expect(isSynthetic({ source: 'cli' } as any)).toBe(false)
    // Absent means ordinary traffic, not synthetic.
    expect(isSynthetic({} as any)).toBe(false)
  })

  it('reports progress without dividing by zero', () => {
    expect(progressOf({ counts: { pending: 3, leased: 1, done: 6, failed: 0 } } as any))
      .toEqual({ done: 6, total: 10, percent: 60 })
    expect(progressOf({ counts: {} } as any)).toEqual({ done: 0, total: 0, percent: 0 })
    expect(progressOf({} as any)).toEqual({ done: 0, total: 0, percent: 0 })
  })
})

describe('what the fleet view says about a model', () => {
  const model = (over: Record<string, unknown> = {}) => ({
    id: 'mlx-community/Qwen2.5-Coder-32B-Instruct-4bit',
    sizeBytes: 18441439373, nodesHolding: 0, nodesWanting: 0, assignedPools: [], ...over,
  }) as any

  it('leads with the machines that are missing it', () => {
    // The only state that calls for action, so it must not be buried behind a
    // count of the machines that are fine.
    const d = distributionOf(model({ nodesHolding: 1, nodesWanting: 3, assignedPools: ['p'] }))
    expect(d.state).toBe('drift')
    expect(d.label).toBe('3 machines missing it')
  })

  it('says complete only when nothing is missing', () => {
    expect(distributionOf(model({ nodesHolding: 4, assignedPools: ['p'] })).state)
      .toBe('complete')
  })

  it('names weights that are on machines but assigned to nothing', () => {
    // How every model on this fleet arrived: staged by hand, described by no
    // policy. A view that showed this as healthy would hide the fact that
    // nothing would reproduce it on a new machine.
    expect(distributionOf(model({ nodesHolding: 2 })).state).toBe('unused')
  })

  it('distinguishes registered-only from present', () => {
    expect(distributionOf(model()).state).toBe('idle')
  })

  it('counts a singular machine as one machine', () => {
    expect(distributionOf(model({ nodesWanting: 1, assignedPools: ['p'] })).label)
      .toBe('1 machine missing it')
  })

  it('reads sizes the way a person would', () => {
    expect(humanBytes(18441439373)).toBe('18.4 GB')
    expect(humanBytes(867)).toBe('1 kB')
    expect(humanBytes(undefined as never)).toBe('—')
  })
})

describe('what the fleet view says about one machine\'s copy', () => {
  it('separates on disk from loaded', () => {
    // The distinction the catalogue was briefly missing. A machine holding
    // weights with none loaded is a healthy idle node, not an empty one.
    expect(copyState({ wanted: true, held: true, loaded: false }).state).toBe('stored')
    expect(copyState({ wanted: true, held: true, loaded: true }).state).toBe('loaded')
  })

  it('calls out a machine that should have it and does not', () => {
    expect(copyState({ wanted: true, held: false, loaded: false }).state).toBe('missing')
  })

  it('marks weights nobody assigned to this machine', () => {
    expect(copyState({ wanted: false, held: true, loaded: false }).state).toBe('stray')
  })

  it('says nothing about a machine that was never meant to have it', () => {
    expect(copyState({ wanted: false, held: false, loaded: false }).label).toBe('—')
  })
})

describe('what the fleet view says about adding a model', () => {
  const fleet = [{ memoryGb: 48 }, { memoryGb: 64 }, { memoryGb: 16 }] as any[]

  it('counts machines by the policy ceiling, not by installed memory', () => {
    // Half of unified memory, from E2. Counting installed RAM would say every
    // machine fits a 32GB model and leave the person at the keyboard with
    // nothing, which is the opposite of the arrangement.
    expect(machinesThatCouldHold(18.4e9, fleet)).toEqual({ fits: 2, total: 3 })
    expect(machinesThatCouldHold(4.3e9, fleet)).toEqual({ fits: 3, total: 3 })
  })

  it('says plainly when nothing in the fleet can hold it', () => {
    // A 70B is above the ceiling on every machine here. Offering it without
    // saying so invites a forty gigabyte download that can never be loaded.
    expect(machinesThatCouldHold(40e9, fleet).fits).toBe(0)
  })

  it('does not exclude a machine whose memory was never probed', () => {
    expect(machinesThatCouldHold(1e9, [{ memoryGb: null }] as any).fits).toBe(0)
  })

  it('names a download as a download', () => {
    // The distinction the whole chooser exists to make. A fleet whose premise
    // is that data does not leave the building should not have weights arriving
    // from outside it without the word appearing on screen.
    expect(importCost({ source: 'remote', registered: false }).state).toBe('remote')
    expect(importCost({ source: 'local', registered: false }).state).toBe('local')
    expect(importCost({ source: 'local', registered: true }).state).toBe('registered')
  })
})

describe('what the fleet view says needs attention', () => {
  const node = (over: Record<string, unknown> = {}) => ({
    hostname: 'rotorua', state: 'active', models: ['m'], ...over,
  }) as any

  it('puts a decision waiting on a human above everything else', () => {
    // A machine that enrolled and has not been let in does nothing at all until
    // somebody acts, so it outranks any amount of drift.
    const items = attentionItems({
      nodes: [node()], models: [{ id: 'm', nodesWanting: 5 }], pending: 2,
    })
    expect(items[0]!.level).toBe('decide')
    expect(items[0]!.text).toMatch(/2 machines waiting/)
  })

  it('names the model that is missing, not just a count', () => {
    // "3 machines missing something" is not actionable. The name is the whole
    // difference between a number and an instruction.
    const items = attentionItems({
      nodes: [node()], models: [{ id: 'mlx-community/Qwen', nodesWanting: 3 }],
    })
    expect(items.find((i) => i.key.startsWith('drift:'))?.text)
      .toBe('mlx-community/Qwen is missing on 3 machines')
  })

  it('never presents an owner pause as a fault', () => {
    // The one control with no override. Levelling it as a warning would invite
    // an operator to try to clear something that is not theirs to clear.
    const items = attentionItems({ nodes: [node({ userPaused: true })], models: [] })
    expect(items.find((i) => i.key === 'owner-paused')?.level).toBe('ok')
  })

  it('says plainly when nothing is wrong', () => {
    // An empty list reads as a broken page rather than a healthy fleet.
    const items = attentionItems({ nodes: [node()], models: [], jobs: [] })
    expect(items[0]!.key).toBe('all-well')
    expect(items[0]!.text).toMatch(/nothing needs attention/)
  })

  it('does not claim all is well while something is wrong', () => {
    const items = attentionItems({ nodes: [node()], models: [{ id: 'm', nodesWanting: 1 }] })
    expect(items.some((i) => i.key === 'all-well')).toBe(false)
  })

  it('guides a fleet that has no machines yet', () => {
    expect(attentionItems({ nodes: [], models: [] })[0]!.text).toMatch(/No machines enrolled/)
  })

  it('notices a fleet that can harvest but cannot answer', () => {
    // Serving and harvesting fail independently, and a fleet with no weights
    // anywhere looks busy while being unable to answer a single request.
    const items = attentionItems({ nodes: [node({ models: [] })], models: [] })
    expect(items.some((i) => i.key === 'nothing-served')).toBe(true)
  })

  it('reports machines that stopped reporting, by name', () => {
    const items = attentionItems({ nodes: [node({ stale: true })], models: [] })
    const offline = items.find((i) => i.key === 'offline')
    expect(offline?.level).toBe('warn')
    expect(offline?.detail).toBe('rotorua')
  })

  it('orders decisions, then problems, then everything else', () => {
    const items = attentionItems({
      nodes: [node({ userPaused: true }), node({ hostname: 'orca', stale: true })],
      models: [{ id: 'm', nodesWanting: 1 }],
      pending: 1,
    })
    expect(items.map((i) => i.level)).toEqual([...items.map((i) => i.level)].sort(
      (a, b) => ({ decide: 0, warn: 1, ok: 2 })[a]! - ({ decide: 0, warn: 1, ok: 2 })[b]!))
    expect(items[0]!.level).toBe('decide')
  })
})

describe('deciding a machine has stopped reporting', () => {
  const now = Date.parse('2026-08-10T12:00:00Z')
  const at = (secondsAgo: number) =>
    new Date(now - secondsAgo * 1000).toISOString()

  it('agrees with the window the scheduler uses', () => {
    // Two minutes, same as the router. Two different answers to "is this
    // machine here" would have the page insisting a node is fine while nothing
    // is ever dispatched to it.
    expect(isStale({ state: 'active', lastHeartbeat: at(119) }, now)).toBe(false)
    expect(isStale({ state: 'active', lastHeartbeat: at(121) }, now)).toBe(true)
  })

  it('does not call a machine that never reported stale', () => {
    // A node that has not started is new, not gone. Saying "stopped reporting"
    // about it sends somebody to check a network that is fine.
    expect(isStale({ state: 'active', lastHeartbeat: null }, now)).toBe(false)
  })

  it('says nothing about machines that are not active', () => {
    // A superseded row is a ghost from a re-enrolment and reports nothing by
    // design. Flagging it would put a permanent false alarm on the page.
    expect(isStale({ state: 'superseded', lastHeartbeat: at(9999) }, now)).toBe(false)
    expect(isStale({ state: 'pending', lastHeartbeat: null }, now)).toBe(false)
  })

  it('survives a timestamp it cannot parse', () => {
    expect(isStale({ state: 'active', lastHeartbeat: 'not a date' }, now)).toBe(false)
  })

  it('feeds the attention list, which could not see it before', () => {
    // attentionItems reads `stale` and nothing was setting it, so a machine
    // that stopped reporting raised nothing at all. The check existed and was
    // permanently false.
    const nodes = withFreshness([
      { hostname: 'orca', state: 'active', lastHeartbeat: at(600), models: ['m'] },
      { hostname: 'rotorua', state: 'active', lastHeartbeat: at(10), models: ['m'] },
    ], now)
    expect(nodes.map((n) => n.stale)).toEqual([true, false])

    const items = attentionItems({ nodes, models: [] })
    const offline = items.find((i) => i.key === 'offline')
    expect(offline?.detail).toBe('orca')
  })
})

describe('what the fleet view says about an import in flight', () => {
  it('measures progress in files, not bytes', () => {
    // File sizes in a model are wildly uneven: four shards and seven small
    // files means a byte count sits at 99% while three quick files remain, and
    // a bar that stalls near the end reads as a hang.
    expect(importProgress({ state: 'running', filesDone: 5, filesTotal: 10 }).percent).toBe(50)
  })

  it('does not claim 0% before it knows how many files there are', () => {
    // The directory walk happens first. Showing zero during it understates an
    // import that is working perfectly well.
    const p = importProgress({ state: 'running', filesDone: 0, filesTotal: 0 })
    expect(p.percent).toBeNull()
    expect(p.label).toMatch(/reading/)
  })

  it('surfaces the reason an import failed', () => {
    // A failure with no trace is indistinguishable from an import nobody
    // started, and the person who clicked the button is the last to find out.
    const p = importProgress({ state: 'failed', error: 'a.bin: expected abc, got def' })
    expect(p.state).toBe('failed')
    expect(p.label).toMatch(/expected abc/)
  })

  it('says something even when a failure carried no message', () => {
    expect(importProgress({ state: 'failed' }).label).toBe('failed')
  })

  it('reports a finished import as complete', () => {
    expect(importProgress({ state: 'done', filesDone: 9, filesTotal: 9 }).percent).toBe(100)
  })
})

describe('searching a table', () => {
  const rows = [
    { hostname: 'orca', chip: 'Apple M4 Pro', models: ['mlx-community/Qwen2.5-Coder-32B'] },
    { hostname: 'rotorua', chip: 'Apple M2 Max', models: ['mlx-community/Qwen2.5-1.5B'] },
  ]
  const fields = ['hostname', 'chip', (r: any) => r.models.join(' ')]

  it('requires every term to match, so refining narrows', () => {
    // Matching any term instead would make each extra word widen the result
    // set, and a search that returns more as you type it is not a search.
    expect(matchesQuery(rows[0], 'orca 32b', fields)).toBe(true)
    expect(matchesQuery(rows[1], 'orca 32b', fields)).toBe(false)
  })

  it('ignores case and looks in every field offered', () => {
    expect(matchesQuery(rows[1], 'M2 MAX', fields)).toBe(true)
    expect(matchesQuery(rows[1], '1.5b', fields)).toBe(true)
  })

  it('matches everything when nothing was typed', () => {
    expect(matchesQuery(rows[0], '', fields)).toBe(true)
    expect(matchesQuery(rows[0], '   ', fields)).toBe(true)
  })
})

describe('sorting a table', () => {
  const accessors = {
    hostname: (n: any) => n.hostname,
    memory: (n: any) => n.memoryGb,
  }
  const rows = [
    { hostname: 'rotorua', memoryGb: 64 },
    { hostname: 'orca', memoryGb: 48 },
    { hostname: 'unknown-box', memoryGb: null },
  ]

  it('puts values a machine never reported last, in both directions', () => {
    // A machine whose memory was never probed belongs at the bottom of a list
    // ordered by memory, not at the top looking like the smallest in the fleet.
    expect(sortRows(rows, 'memory', 'asc', accessors).map((r) => r.hostname))
      .toEqual(['orca', 'rotorua', 'unknown-box'])
    expect(sortRows(rows, 'memory', 'desc', accessors).map((r) => r.hostname))
      .toEqual(['rotorua', 'orca', 'unknown-box'])
  })

  it('sorts text naturally', () => {
    expect(sortRows(rows, 'hostname', 'asc', accessors).map((r) => r.hostname))
      .toEqual(['orca', 'rotorua', 'unknown-box'])
  })

  it('does not reorder the caller\'s array', () => {
    // The array it is given is the render cache's input, and reordering it in
    // place would make the cache compare unequal on every poll and rebuild the
    // table forever.
    const original = [...rows]
    sortRows(rows, 'hostname', 'desc', accessors)
    expect(rows).toEqual(original)
  })

  it('leaves rows alone when the column is not sortable', () => {
    expect(sortRows(rows, 'nonsense', 'asc', accessors)).toBe(rows)
  })

  it('cycles a column through ascending, descending, and off', () => {
    // The third click matters: without it there is no way back to the order the
    // server returned, only two orders somebody chose between.
    expect(nextSort(null, 'hostname')).toEqual({ key: 'hostname', dir: 'asc' })
    expect(nextSort({ key: 'hostname', dir: 'asc' }, 'hostname'))
      .toEqual({ key: 'hostname', dir: 'desc' })
    expect(nextSort({ key: 'hostname', dir: 'desc' }, 'hostname')).toBeNull()
    expect(nextSort({ key: 'hostname', dir: 'desc' }, 'memory'))
      .toEqual({ key: 'memory', dir: 'asc' })
  })
})

describe('dragging the capacity timeline', () => {
  it('covers the whole range in one drag across the chart', () => {
    // Logarithmic rather than linear. Linear would spend almost all its travel
    // in the last few hours and squeeze the difference between ten minutes and
    // an hour into a pixel, which is the part somebody dragging usually wants.
    expect(windowFromDrag(86400, 900, 900)).toBe(MAX_WINDOW_S)
    expect(windowFromDrag(86400, -900, 900)).toBe(MIN_WINDOW_S)
  })

  it('widens to the right and narrows to the left', () => {
    // Right pulls more of the past into view, the direction the data comes from.
    expect(windowFromDrag(3600, 100, 900)).toBeGreaterThan(3600)
    expect(windowFromDrag(3600, -100, 900)).toBeLessThan(3600)
  })

  it('never leaves the range somebody can ask for', () => {
    expect(clampWindow(1)).toBe(MIN_WINDOW_S)
    expect(clampWindow(99 * 86400)).toBe(MAX_WINDOW_S)
    expect(clampWindow(NaN)).toBe(86400)
    expect(windowFromDrag(MAX_WINDOW_S, 5000, 900)).toBe(MAX_WINDOW_S)
    expect(windowFromDrag(MIN_WINDOW_S, -5000, 900)).toBe(MIN_WINDOW_S)
  })

  it('buckets in units a person recognises', () => {
    // An axis in 47 second steps is harder to read than one in minutes even
    // when it is more precise.
    expect(bucketFor(600)).toBe(10)
    expect(bucketFor(3600)).toBe(60)
    expect(bucketFor(86400)).toBe(1800)
    expect(bucketFor(MAX_WINDOW_S)).toBe(7200)
  })

  it('never buckets so finely that the series is unbounded', () => {
    // Sixty-ish buckets whatever the window: the query returns one row per
    // bucket per presence state, and a ten second bucket over three days is
    // twenty-six thousand rows into a chart 900 pixels wide.
    for (const w of [600, 1800, 3600, 21600, 86400, MAX_WINDOW_S]) {
      expect(w / bucketFor(w)).toBeLessThanOrEqual(90)
    }
  })

  it('describes the window the way a person would say it', () => {
    expect(describeWindow(600)).toBe('last 10 minutes')
    expect(describeWindow(3600)).toBe('last 1 hours')
    expect(describeWindow(86400)).toBe('last 24 hours')
    expect(describeWindow(MAX_WINDOW_S)).toBe('last 3 days')
  })
})

describe('groups of machines', () => {
  const orca = { id: 'n-orca', hostname: 'orca', memoryGb: 48, chip: 'Apple M4 Pro' }
  const small = { id: 'n-air', hostname: 'air', memoryGb: 16, chip: 'Apple M2' }
  const pool = (over = {}) => ({ id: 'p1', name: 'overnight', tier: 'harvest',
    membership: {}, ...over }) as any

  it('marks a machine that cannot hold what its group holds', () => {
    // The failure a group hides: the machine is in the list, looks healthy,
    // fetches nothing and serves nothing, and reads as a working member.
    const p = pool({ membership: { nodeIds: ['n-air'] } })
    const models = [{ id: 'mlx/Qwen-32B', sizeBytes: 18.4e9, assignedPools: ['p1'] }]
    const found = groupMismatches(p, [small as never], models as never)
    expect(found).toHaveLength(1)
    expect(found[0]!.kind).toBe('too-small')
    expect(found[0]!.reason).toMatch(/16GB and cannot hold/)
  })

  it('says nothing when every machine can hold everything', () => {
    const p = pool({ membership: { nodeIds: ['n-orca'] } })
    const models = [{ id: 'mlx/Qwen-7B', sizeBytes: 4.3e9, assignedPools: ['p1'] }]
    expect(groupMismatches(p, [orca as never], models as never)).toEqual([])
    expect(groupWarning([])).toBeNull()
  })

  it('marks a hand-picked machine that the group\'s own rules exclude', () => {
    // Putting it there by hand wins, deliberately. But a rule saying one thing
    // while the membership says another is worth surfacing rather than leaving
    // for somebody to find.
    const p = pool({ membership: { nodeIds: ['n-air'], minMemoryGb: 32 } })
    const found = groupMismatches(p, [small as never], [])
    expect(found[0]!.kind).toBe('overridden')
  })

  it('treats cannot-hold as worse than rule-override', () => {
    // One will never work; the other is a deliberate exception. A single mark
    // for both would make the serious case invisible among the tolerable ones.
    expect(groupWarning([{ kind: 'overridden', hostname: 'a', reason: 'x' }] as never)!.level)
      .toBe('warn')
    expect(groupWarning([
      { kind: 'overridden', hostname: 'a', reason: 'x' },
      { kind: 'too-small', hostname: 'b', reason: 'y' },
    ] as never)!.level).toBe('bad')
  })

  it('counts machines, not complaints', () => {
    // One machine failing three models is one machine to go and look at.
    const w = groupWarning([
      { kind: 'too-small', hostname: 'air', reason: 'a' },
      { kind: 'too-small', hostname: 'air', reason: 'b' },
    ] as never)
    expect(w!.label).toMatch(/^1 machine /)
  })

  it('shows machines that belong to no group at all', () => {
    // Not belonging anywhere is a state worth seeing, and it is invisible if
    // the view only draws groups.
    const { groups, ungrouped } = groupMachines(
      [orca, small] as never, [pool()] as never,
      (n, p2) => (p2.membership.nodeIds ?? []).includes(n.id))
    expect(groups[0]!.nodes).toEqual([])
    expect(ungrouped.map((n) => n.hostname)).toEqual(['orca', 'air'])
  })

  it('lists a machine under every group it is in', () => {
    // Hiding the second would make the fleet view disagree with the scheduler,
    // which considers all of them.
    const a = pool({ id: 'a', membership: { nodeIds: ['n-orca'] } })
    const b = pool({ id: 'b', membership: { nodeIds: ['n-orca'] } })
    const { groups, ungrouped } = groupMachines(
      [orca] as never, [a, b] as never,
      (n, p2) => (p2.membership.nodeIds ?? []).includes(n.id))
    expect(groups.map((g) => g.nodes.length)).toEqual([1, 1])
    expect(ungrouped).toEqual([])
  })

  it('knows a list from a rule', () => {
    expect(groupMode(pool())).toBe('rule')
    expect(groupMode(pool({ membership: { minMemoryGb: 32 } }))).toBe('rule')
    expect(groupMode(pool({ membership: { nodeIds: ['n-1'] } }))).toBe('list')
  })
})


/**
 * The page's own markup and stylesheet, checked against each other.
 *
 * `hidden` is how every overlay in this console is put away, and it is an
 * attribute selector: the browser's `[hidden] { display: none }` loses to any
 * class rule that sets `display`. That is not a hypothetical. `.gate` and
 * `.gate-card` both set `display: grid`, so the sign-in overlay covered the
 * console permanently and rendered the sign-in form and the change-password
 * form stacked on top of each other, with no way past either.
 *
 * Nothing in a unit test of view.js could have caught that, because the bug was
 * entirely in the cascade.
 */
describe('hidden actually hides', () => {
  const css = readFileSync(join(import.meta.dirname, '../ui/app.css'), 'utf8')
  const html = readFileSync(join(import.meta.dirname, '../ui/index.html'), 'utf8')

  it('declares an override that outranks any layout rule', () => {
    // `!important` rather than a more specific selector, because the next
    // component to set `display` would otherwise bring the bug straight back.
    expect(css).toMatch(/\[hidden\]\s*\{[^}]*display:\s*none\s*!important/)
  })

  it('puts the override before the rules it has to beat', () => {
    // Equal weight is resolved by order, so an override declared at the bottom
    // of the file would still work - but one declared before everything it
    // governs cannot be undone by a later `!important` added in passing.
    const override = css.search(/\[hidden\]\s*\{[^}]*display:\s*none\s*!important/)
    const firstDisplay = css.search(/^\.[\w-]+[^{]*\{[^}]*display:/m)
    expect(override).toBeGreaterThanOrEqual(0)
    expect(override).toBeLessThan(firstDisplay)
  })

  it('covers every element the page hides', () => {
    // The elements that carry `hidden` in the markup are the ones this has to
    // hold for. Listed from the file rather than by hand so a new overlay is
    // covered the day it is added.
    const hiddenClasses = new Set<string>()
    for (const tag of html.match(/<[^>]*\bhidden\b[^>]*>/g) ?? []) {
      for (const cls of (tag.match(/class="([^"]*)"/)?.[1] ?? '').split(/\s+/)) {
        if (cls) hiddenClasses.add(cls)
      }
    }
    // The gate is the one that broke, so it must be in the set this covers.
    expect(hiddenClasses.has('gate')).toBe(true)
    expect(hiddenClasses.has('gate-card')).toBe(true)

    // Every one of them is governed by the override, whether or not its own
    // rule sets display.
    for (const cls of hiddenClasses) {
      const rule = css.match(new RegExp(`^\\.${cls}\\s*\\{[^}]*}`, 'm'))?.[0] ?? ''
      const setsDisplay = /display:/.test(rule)
      // Not an assertion that it must not set display - several legitimately
      // do - but that the override exists to beat it when it does.
      if (setsDisplay) {
        expect(css).toMatch(/\[hidden\]\s*\{[^}]*display:\s*none\s*!important/)
      }
    }
  })

  it('never asks for a colour that was never defined', () => {
    // `background: var(--ground)` where --ground does not exist is not an
    // error: the declaration is simply dropped, and the element renders
    // transparent. That is how the sign-in gate ended up as a card floating
    // over a console the reader could see and could not use, alongside a
    // `border: 1px solid var(--rule)` that drew no border either.
    //
    // A fallback is a deliberate choice and is allowed. A bare reference to
    // something undefined is a typo that renders.
    const defined = new Set([...css.matchAll(/(--[\w-]+)\s*:/g)].map(m => m[1]!))
    const dangling: string[] = []
    for (const m of css.matchAll(/var\(\s*(--[\w-]+)\s*(,)?/g)) {
      if (!defined.has(m[1]!) && !m[2]) dangling.push(m[1]!)
    }
    expect(dangling).toEqual([])
  })

  it('never leaves two gate forms visible at once', () => {
    // Both live inside #gate and only one is meant to show. The markup marks
    // the change form hidden; the stylesheet has to honour it.
    expect(html).toMatch(/id="change-form"[^>]*\bhidden\b/)
    expect(html).toMatch(/id="gate"[^>]*\bhidden\b/)
  })
})


/**
 * The API explorer, which turns the contract into something operators use.
 *
 * The console already linked to a rendered copy of the document, which is good
 * for reading and no help in answering "what does this return on my fleet".
 * Answering that meant leaving the console, finding a token and writing a curl
 * line, so nobody did.
 */
describe('reading the contract as operations', () => {
  const spec = {
    paths: {
      '/admin/v1/nodes': {
        get: { tags: ['admin'], summary: 'List machines', responses: { 200: {} } },
      },
      '/admin/v1/nodes/{nodeId}/approve': {
        post: {
          tags: ['admin'], summary: 'Approve',
          parameters: [{ name: 'nodeId', in: 'path', required: true }],
          responses: { 200: {}, 404: {} },
        },
      },
      '/agent/v1/heartbeat': {
        post: { tags: ['agent'], summary: 'Report presence', responses: { 204: {} } },
      },
      '/monitor/v1/metrics': { get: { tags: ['monitor'], summary: 'Metrics', responses: { 200: {} } } },
    },
  }

  it('flattens every method on every path', () => {
    const ops = operationsFrom(spec)
    expect(ops.map((o) => `${o.method} ${o.path}`).sort()).toEqual([
      'GET /admin/v1/nodes',
      'GET /monitor/v1/metrics',
      'POST /admin/v1/nodes/{nodeId}/approve',
      'POST /agent/v1/heartbeat',
    ])
  })

  it('carries path parameters through', () => {
    const op = operationsFrom(spec).find((o) => o.path.endsWith('/approve'))!
    expect(op.params).toEqual([
      { name: 'nodeId', in: 'path', required: true, description: '' },
    ])
  })

  it('knows which surface an endpoint belongs to', () => {
    expect(surfaceOf('/agent/v1/heartbeat')).toBe('agent')
    expect(surfaceOf('/admin/v1/nodes')).toBe('admin')
    expect(surfaceOf('/monitor/v1/metrics')).toBe('monitor')
    expect(surfaceOf('/v1/chat/completions')).toBe('serving')
  })

  it('will not offer to send what a browser cannot send', () => {
    // The agent surface is mutually authenticated with a node's client
    // certificate. A browser has none and never will, so those are listed and
    // not sendable - shown rather than hidden, because "why can I not call
    // this" is a question the page should answer rather than avoid.
    const ops = operationsFrom(spec)
    expect(callableHere(ops.find((o) => o.surface === 'admin')!)).toBe(true)
    expect(callableHere(ops.find((o) => o.surface === 'monitor')!)).toBe(true)
    expect(callableHere(ops.find((o) => o.surface === 'agent')!)).toBe(false)
  })

  it('separates the calls that only read from the ones that act', () => {
    // Decides which ones ask twice before sending. An explorer is a thing
    // people click on to find out what an endpoint does, and the endpoint they
    // are most curious about is the one that revokes a machine.
    const ops = operationsFrom(spec)
    expect(isReadOnly(ops.find((o) => o.method === 'GET')!)).toBe(true)
    expect(isReadOnly(ops.find((o) => o.method === 'POST')!)).toBe(false)
  })

  it('groups by tag with the surfaces in a useful order', () => {
    expect(groupOperations(operationsFrom(spec)).map((g) => g.tag))
      .toEqual(['admin', 'agent', 'monitor'])
  })

  it('filters on what somebody would actually type', () => {
    const op = operationsFrom(spec)[0]!
    expect(matchesOperation(op, '')).toBe(true)
    expect(matchesOperation(op, 'nodes')).toBe(true)
    expect(matchesOperation(op, 'GET')).toBe(true)
    expect(matchesOperation(op, 'machines')).toBe(true)   // the summary
    expect(matchesOperation(op, 'renderfarm')).toBe(false)
  })
})

describe('building a request', () => {
  const op = {
    id: 'post:/admin/v1/nodes/{nodeId}/approve',
    method: 'POST',
    path: '/admin/v1/nodes/{nodeId}/approve',
    params: [
      { name: 'nodeId', in: 'path', required: true },
      { name: 'reason', in: 'query', required: false },
    ],
  } as any

  it('refuses a half-built URL rather than sending one', () => {
    // `/admin/v1/nodes//approve` answers 404, and the reader concludes the
    // endpoint does not exist rather than that their box was empty.
    expect(buildUrl(op, {})).toEqual({ error: 'needs nodeId' })
  })

  it('substitutes path parameters and encodes them', () => {
    expect(buildUrl(op, { nodeId: 'a/b' }).url).toBe('/admin/v1/nodes/a%2Fb/approve')
  })

  it('appends only the query parameters that were filled in', () => {
    expect(buildUrl(op, { nodeId: 'n1' }).url).toBe('/admin/v1/nodes/n1/approve')
    expect(buildUrl(op, { nodeId: 'n1', reason: 'new mac' }).url)
      .toBe('/admin/v1/nodes/n1/approve?reason=new+mac')
  })
})

describe('starting from a request body rather than a blank box', () => {
  const spec = {
    components: {
      schemas: {
        Pool: {
          type: 'object',
          required: ['name', 'tier'],
          properties: {
            name: { type: 'string' },
            tier: { type: 'string', enum: ['harvest', 'cluster'] },
            minMemoryGb: { type: 'integer' },
            nodeIds: { type: 'array', items: { type: 'string', format: 'uuid' } },
          },
        },
        Loop: { $ref: '#/components/schemas/Loop' },
      },
    },
  }

  it('fills required fields first, so the shape reads as the minimum request', () => {
    // A blank box makes the reader go and find the schema themselves, which is
    // the errand this page exists to remove.
    const body = bodySkeleton(spec, { $ref: '#/components/schemas/Pool' })
    expect(Object.keys(body)).toEqual(['name', 'tier', 'minMemoryGb', 'nodeIds'])
    expect(body.tier).toBe('harvest')   // the first enum value, not an empty string
    expect(body.minMemoryGb).toBe(0)
    expect(body.nodeIds).toEqual(['00000000-0000-0000-0000-000000000000'])
  })

  it('prefers an example over a guess', () => {
    expect(bodySkeleton(spec, { type: 'string', example: 'orca' })).toBe('orca')
  })

  it('does not hang on a schema that refers to itself', () => {
    expect(resolveRef(spec, { $ref: '#/components/schemas/Loop' })).toBe(null)
    expect(bodySkeleton(spec, { $ref: '#/components/schemas/Loop' })).toBe(null)
  })
})

describe('showing what came back', () => {
  it('pretty-prints JSON and leaves everything else alone', () => {
    expect(formatResponse('{"a":1}', 'application/json')).toBe('{\n  "a": 1\n}')
    expect(formatResponse('# HELP up\nup 1', 'text/plain')).toBe('# HELP up\nup 1')
  })

  it('shows a body that lied about being JSON exactly as it arrived', () => {
    // That mismatch is itself the finding, so it must not be swallowed.
    expect(formatResponse('<html>500</html>', 'application/json')).toBe('<html>500</html>')
  })

  it('does not round a small body away to nothing', () => {
    // humanBytes measures model files and rounds to kilobytes, because a real
    // file should never read as "0 kB". A response body is routinely two
    // hundred bytes, and rounding that to zero says the endpoint returned
    // nothing when it returned the answer.
    expect(responseSize(212)).toBe('212 B')
    expect(responseSize(4096)).toBe('4.1 kB')
    expect(responseSize(2_500_000)).toBe('2.5 MB')
  })

  it('reads a status at a glance', () => {
    expect(statusTone(200)).toBe('good')
    expect(statusTone(403)).toBe('warn')
    expect(statusTone(500)).toBe('bad')
  })
})


/**
 * Tiers, which are what a machine is offered for rather than what it is.
 *
 * A machine may be in both, and that is a choice with a consequence: cluster
 * membership means presence does not gate serving, so an interactive request
 * can land on a machine while its owner is using it. The view exists to make
 * that visible before somebody makes it by accident.
 */
describe('what a machine is offered for', () => {
  it('reads the plural field, and the old scalar too', () => {
    // A fleet part-way through an upgrade has records of both shapes, and a
    // view that showed nothing for the old ones would look like machines had
    // lost their tier.
    expect(tiersOf({ tiers: ['harvest', 'cluster'] })).toEqual(['harvest', 'cluster'])
    expect(tiersOf({ tier: 'cluster' })).toEqual(['cluster'])
    expect(tiersOf({})).toEqual(['harvest'])
    expect(tiersOf({ tiers: [] })).toEqual(['harvest'])
  })

  it('points out the machines that are in both', () => {
    expect(inBothTiers({ tiers: ['harvest', 'cluster'] })).toBe(true)
    expect(inBothTiers({ tiers: ['cluster'] })).toBe(false)
    expect(inBothTiers({ tier: 'harvest' })).toBe(false)
  })

  it('says what the cluster tier costs, not what it is', () => {
    // Somebody dragging a machine there is entitled to know before they let go.
    expect(describeTier('cluster')).toContain('while somebody is using the machine')
    expect(describeTier('harvest')).toContain('given back')
  })

  it('adds rather than moves, which is the difference from groups', () => {
    expect(tiersAfter({ tiers: ['harvest'] }, 'cluster', 'add')).toEqual(['harvest', 'cluster'])
    expect(tiersAfter({ tier: 'cluster' }, 'harvest', 'add')).toEqual(['harvest', 'cluster'])
  })

  it('keeps the order stable so the same machine reads the same way twice', () => {
    expect(tiersAfter({ tiers: ['cluster'] }, 'harvest', 'add')).toEqual(['harvest', 'cluster'])
  })

  it('refuses to take away the last one', () => {
    // A machine offered for nothing still runs, still heartbeats and never
    // receives work, which looks exactly like a broken agent.
    expect(tiersAfter({ tiers: ['harvest'] }, 'harvest', 'remove')).toBeNull()
    expect(tiersAfter({ tiers: ['harvest', 'cluster'] }, 'cluster', 'remove'))
      .toEqual(['harvest'])
  })

  it('refuses a change that would do nothing', () => {
    expect(tiersAfter({ tiers: ['harvest'] }, 'harvest', 'add')).toBeNull()
    expect(tiersAfter({ tiers: ['harvest'] }, 'cluster', 'remove')).toBeNull()
  })
})

/**
 * The renewal control, which is the only way to get a certificate onto a node
 * that cannot be asked for one directly - the Enclave key signs inside the
 * daemon and nowhere else, so a person at the machine has no more power here
 * than a person on the other side of the fleet.
 */
describe('what the fleet view says about a certificate', () => {
  const DAY = 86_400_000
  const now = Date.parse('2026-08-13T00:00:00Z')
  const node = (over: Record<string, unknown> = {}) => ({
    id: 'n1', hostname: 'orca', certNotAfter: new Date(now + 20 * DAY).toISOString(),
    renewRequestedAt: null, ...over,
  })

  it('offers to renew a certificate with life left in it', () => {
    const c = certificateStanding(node(), now)
    expect(c.state).toBe('valid')
    expect(c.days).toBe(20)
    expect(c.canAsk).toBe(true)
  })

  it('does not offer twice while a request is outstanding', () => {
    const c = certificateStanding(
      node({ renewRequestedAt: '2026-08-13T00:00:00Z' }), now)
    expect(c.canAsk).toBe(false)
    expect(c.asked).toBe('2026-08-13T00:00:00Z')
  })

  it('warns when the automatic renewal has evidently not run', () => {
    // Renewal happens on its own at two thirds of life, so a week left means
    // something is wrong rather than that it is nearly time.
    expect(certificateStanding(node({
      certNotAfter: new Date(now + 3 * DAY).toISOString() }), now).state).toBe('expiring')
  })

  it('refuses to offer renewal to a node that can no longer heartbeat', () => {
    // An expired certificate cannot authenticate, so the request has no ride
    // home. The honest answer is re-enrolment, not a button.
    const c = certificateStanding(node({
      certNotAfter: new Date(now - DAY).toISOString() }), now)
    expect(c.expired).toBe(true)
    expect(c.canAsk).toBe(false)
    expect(c.detail).toContain('re-enrolled')
  })

  it('says so rather than guessing when the expiry is unknown', () => {
    const c = certificateStanding(node({ certNotAfter: null }), now)
    expect(c.state).toBe('unknown')
    expect(c.days).toBe(null)
    // Still offerable: not knowing when a certificate expires is a reason to
    // renew it, not a reason to withhold the only control that would.
    expect(c.canAsk).toBe(true)
  })
})

/**
 * A machine that is idle because it is holding half a model.
 *
 * It is active, unpaused, healthy and taking no work, which is what a machine
 * with nothing to do looks like. The fleet view has to tell them apart, because
 * one of them is a problem and the other is the system working.
 */
describe('what the fleet view says about a suspended machine', () => {
  const held = (over: Record<string, unknown> = {}) => ({
    id: 'n1', hostname: 'rotorua', state: 'active', tier: 'cluster',
    presenceState: 'ABSENT', userPaused: false, models: [], serving: false, inFlight: 0,
    suspended: {
      modelId: 'mlx-community/Qwen2.5-72B-Instruct-4bit', machines: 2,
      by: 'split-cluster', from: ['overnight-harvest'],
    },
    ...over,
  }) as any

  it('offers it no work, however healthy it looks', () => {
    // Locked, on power, nothing wrong with it - and still not available. Listing
    // what it could run would read as capacity the scheduler is failing to use.
    expect(kindsFor(held({ presenceState: 'LOCKED' }))).toEqual([])
  })

  it('says what it is holding, for whom, and what lost it', () => {
    const note = suspensionNote(held())
    expect(note).toContain('Qwen2.5-72B-Instruct-4bit')
    expect(note).toContain('across 2 machines')
    expect(note).toContain('split-cluster')
    // The group that gave the machine up is named, because that is the capacity
    // an operator is missing and the place they will go looking.
    expect(note).toContain('overnight-harvest')
  })

  it('still says so for a machine in no harvest group', () => {
    // Nothing is lost, so nothing is named - but the machine is still explained.
    const note = suspensionNote(held({ suspended: {
      modelId: 'big-72b', machines: 2, by: 'split-cluster', from: [] } }))
    expect(note).toContain('big-72b')
    expect(note).not.toContain('not available to')
  })

  it('says nothing about a machine that is simply idle', () => {
    expect(suspensionNote(held({ suspended: null }))).toBe(null)
  })
})

/**
 * A machine running something other than what its group serves.
 *
 * This fleet was doing exactly that and nothing said so: split-cluster declared
 * a 14B while its two machines ran a 32B and a 30B, because a machine's model
 * came from the argument its daemon was started with and nothing ever compared
 * the two.
 */
describe('what the fleet view says about the model a machine runs', () => {
  // tier 'cluster' because these machines are in both tiers, which is the
  // arrangement the override rule exists for. A cluster group will not take a
  // harvest-tier machine at all.
  const machine = (hostname: string, runs: string[]) => ({
    id: hostname, hostname, tier: 'cluster', chip: 'Apple M2 Max',
    memoryGb: 64, models: runs,
  }) as any
  const g = (name: string, tier: string, servingModelId: string | null) => ({
    id: name, name, tier, membership: {}, servingModelId,
  }) as any

  it('flags a machine that is not running its group model', () => {
    const pool = g('split-cluster', 'cluster', 'mlx/Qwen2.5-14B')
    const found = groupMismatches(
      pool, [machine('rotorua', ['mlx/Qwen3-30B'])], [], [pool])
    expect(found).toHaveLength(1)
    expect(found[0]!.kind).toBe('wrong-model')
    expect(found[0]!.reason).toContain('Qwen3-30B')
    expect(found[0]!.reason).toContain('Qwen2.5-14B')
  })

  it('says nothing when the machine is running it', () => {
    const pool = g('split-cluster', 'cluster', 'mlx/Qwen2.5-14B')
    expect(groupMismatches(pool, [machine('rotorua', ['mlx/Qwen2.5-14B', 'ane:embed'])],
                           [], [pool])).toEqual([])
  })

  it('does not blame a harvest group for being overridden', () => {
    // The cluster group wins where they share a machine, so a harvest group
    // whose machine runs the cluster group's model is not a group with a
    // problem - it is the rule working. Blaming it here would put a warning on
    // every correctly overridden group in the fleet.
    const harvest = g('overnight', 'harvest', 'mlx/Qwen3-30B')
    const cluster = g('split-cluster', 'cluster', 'mlx/Qwen2.5-14B')
    const nodes = [machine('rotorua', ['mlx/Qwen2.5-14B'])]
    expect(groupMismatches(harvest, nodes, [], [harvest, cluster])).toEqual([])
  })

  it('resolves a disagreement in the cluster group\'s favour', () => {
    const harvest = g('overnight', 'harvest', 'mlx/Qwen3-30B')
    const cluster = g('split-cluster', 'cluster', 'mlx/Qwen2.5-14B')
    expect(effectiveModelFor(machine('rotorua', []), [harvest, cluster]))
      .toBe('mlx/Qwen2.5-14B')
  })

  it('says nothing about a machine whose groups have named nothing', () => {
    expect(effectiveModelFor(machine('rotorua', []), [g('overnight', 'harvest', null)]))
      .toBe(null)
  })
})

describe('how wide a model is, said where it is named', () => {
  it('marks a model that runs across machines', () => {
    // A repository path says nothing about this, and serving it engages two
    // machines, needs a group set up for it, and takes those machines out of
    // harvesting while it stands.
    expect(splitNote(2)).toBe('2 machines')
    expect(splitNote(5)).toBe('5 machines')
  })

  it('says nothing about the ordinary case', () => {
    // The point is that split models stand out. A list decorated with
    // "1 machine" on every row hides them again.
    expect(splitNote(1)).toBe('')
    expect(splitNote(null)).toBe('')
    expect(splitNote(undefined)).toBe('')
  })
})


/**
 * The readiness strip on a cluster group's card.
 *
 * It exists because standing a split up meant waiting with nothing to look at
 * while ~18 GB reached both machines. What it has to get right is not the
 * numbers but the distinction between a wait and a fault.
 */
describe('how a split group\'s readiness reads', () => {
  it('separates a wait from a fault', () => {
    // Preparing resolves on its own; blocked needs somebody to walk to a
    // machine. One sentence for both is how the line stops being read.
    expect(readinessSummary({ state: 'preparing', detail: 'x' }).level).toBe('busy')
    expect(readinessSummary({ state: 'blocked', detail: 'x' }).level).toBe('bad')
    expect(readinessSummary({ state: 'ready', detail: 'x' }).level).toBe('good')
  })

  it('calls a stood-down group stood down, not broken', () => {
    // The operator's own decision. Describing it as a fault teaches them to
    // ignore the strip.
    expect(readinessSummary({ state: 'idle', detail: 'x' }).label).toBe('stood down')
  })

  it('survives a group it has no answer for yet', () => {
    expect(readinessSummary(undefined).level).toBe('unknown')
    expect(readinessSummary(null).label).toBe('unknown')
  })

  const rank = {
    hostname: 'orca', rank: 0, role: 'output head', state: 'ready',
    weights: 'present', loaded: true, dialable: true, detail: 'ready',
  }

  it('marks which machine holds the head', () => {
    expect(rankLine(rank).where).toBe('rank 0 \u00b7 head')
  })

  it('names a rank nobody holds as nothing at all', () => {
    // Ranks cannot be assigned until a machine can be dialled. Printing
    // "rank 0" for a group that cannot form names a role nobody is holding.
    expect(rankLine({ ...rank, rank: null, role: null, dialable: false }).where).toBe('')
  })

  it('says which of the three things is missing', () => {
    const out = rankLine({ ...rank, weights: 'missing', loaded: false })
    expect(out.marks).toContain('no weights')
    expect(out.marks).toContain('not loaded')
    expect(out.marks).toContain('dialable')
  })

  it('keeps watching only while something is changing', () => {
    // Ready and blocked are stable. Polling them forever is a request every few
    // seconds for an answer nobody is waiting on.
    expect(shouldKeepWatching({ state: 'preparing' })).toBe(true)
    expect(shouldKeepWatching({ state: 'ready' })).toBe(false)
    expect(shouldKeepWatching({ state: 'blocked' })).toBe(false)
    expect(shouldKeepWatching(undefined)).toBe(false)
  })
})


/**
 * Telling a group what to serve, from the card.
 *
 * The console could not do this at all: a group card offered a socket, stand
 * up and down, delete, and the readiness strip. Everything that assigns a model
 * was a terminal away.
 */
describe('choosing a model for a group', () => {
  const models = [
    { id: 'mlx-community/Qwen3-30B', sizeBytes: 17e9, machines: 1 },
    { id: 'mlx-community/Qwen2.5-Coder-32B', sizeBytes: 18.4e9, machines: 2 },
    { id: 'ane:embed', sizeBytes: 3e8 },
  ]

  it('offers everything the fleet knows, not only what is already here', () => {
    // Telling a group to serve something is also telling it to fetch it.
    // Offering only what a machine already holds would make the console unable
    // to express deploying something new, which is the ordinary case.
    expect(servableChoices(models).map((c) => c.label))
      .toEqual(['Qwen2.5-Coder-32B', 'Qwen3-30B'])
  })

  it('leaves out embedding models', () => {
    // They answer a different endpoint. Offering one is offering a choice that
    // produces a confusing failure rather than an error.
    expect(servableChoices(models).some((c) => c.id.startsWith('ane:'))).toBe(false)
  })

  it('survives a fleet with no models', () => {
    expect(servableChoices([])).toEqual([])
    expect(servableChoices(undefined as never)).toEqual([])
  })
})

describe('what serving it will do, said beforehand', () => {
  const split = { id: 'org/32B', label: '32B', sizeBytes: 18.4e9, machines: 2 }
  const whole = { id: 'org/30B', label: '30B', sizeBytes: 17e9, machines: 1 }

  it('names the cost of a split, which is the machines', () => {
    const out = serveConsequences(split, 2, 2, [])
    expect(out.some((c) => c.level === 'cost' && /harvesting/.test(c.text))).toBe(true)
  })

  it('says nothing about harvesting for a whole model', () => {
    // A dedicated group holding one model is not a gang and preempts nobody.
    expect(serveConsequences(whole, 1, 2, [])).toEqual([])
  })

  it('says when the group is too small before anything is written', () => {
    const out = serveConsequences(split, 3, 2, [])
    expect(out.some((c) => c.level === 'blocked' && /2 machines/.test(c.text))).toBe(true)
  })

  it('warns that the width belongs to the model, not the assignment', () => {
    // machines is a column on the model, so two cluster groups serving it
    // cannot divide it differently - and the second group's machines rebuild.
    // Not something to discover afterwards.
    const out = serveConsequences(split, 3, 4,
      [{ name: 'split-b', servingModelId: 'org/32B' }])
    expect(out.some((c) => c.level === 'warn' && /split-b/.test(c.text))).toBe(true)
  })

  it('stays quiet when nothing else serves it', () => {
    const out = serveConsequences(split, 3, 4,
      [{ name: 'split-b', servingModelId: 'org/other' }])
    expect(out.some((c) => c.level === 'warn')).toBe(false)
  })

  it('stays quiet when the width is not changing', () => {
    // Assigning a model at the width it already has changes nothing elsewhere.
    const out = serveConsequences(split, 2, 4,
      [{ name: 'split-b', servingModelId: 'org/32B' }])
    expect(out.some((c) => c.level === 'warn')).toBe(false)
  })
})

describe('the address to point an application at', () => {
  it('is the group\'s own socket, in a form somebody can paste', () => {
    expect(groupAddress({ servingPort: 8461 }, 'https://rotorua:8452/ui/'))
      .toBe('https://rotorua:8461')
  })

  it('is nothing at all for a group without one', () => {
    // Rather than a plausible-looking address that reaches the wrong group.
    expect(groupAddress({ servingPort: null }, 'https://rotorua:8452/')).toBeNull()
  })
})

/**
 * A group that serves whichever model it is staged with, in the console.
 *
 * The console read `serving_model_id` as the whole answer, so a group with none
 * rendered as a blank cell and a readiness strip saying "stood down" - both of
 * which describe a group nobody had finished setting up, rather than one doing
 * something deliberate.
 */
describe('a group with nothing pinned, on its card', () => {
  it('says what it does instead of leaving a blank', () => {
    const line = servingLine({ tier: 'cluster', servingModelId: null })
    expect(line.pinned).toBe(false)
    expect(line.label).toBe('whatever is staged')
    // The cost belongs where the operator reads about the group, not in the
    // latency of a request they have already sent.
    expect(line.title).toContain('pays the build')
  })

  it('still names the model when there is one', () => {
    const line = servingLine({ tier: 'cluster', servingModelId: 'org/Qwen-32B' })
    expect(line).toMatchObject({ pinned: true, label: 'Qwen-32B' })
  })

  it('leaves a harvest group with nothing to say', () => {
    // A harvest group cannot serve whatever it is staged with - its machines
    // are preemptible - so this phrase must not appear on one.
    expect(servingLine({ tier: 'harvest', servingModelId: null }).label).toBe('-')
  })

  it('tells a standing group with nothing staged from one stood down', () => {
    // Both arrive as `idle` and they mean opposite things: one is a decision,
    // the other is a thing to go and do.
    expect(readinessSummary({ state: 'idle', standing: true, detail: 'x' }).label)
      .toBe('nothing staged')
    expect(readinessSummary({ state: 'idle', standing: false, detail: 'x' }).label)
      .toBe('stood down')
  })
})

describe('what an unpinned group can be asked for', () => {
  const readiness = {
    state: 'ready', standing: true, model: null, staged: [
      { modelId: 'org/ready-b', machines: 2, held: 2, ready: true },
      { modelId: 'org/half-there', machines: 2, held: 1, ready: false },
      { modelId: 'org/ready-a', machines: 2, held: 2, ready: true },
    ],
  }

  it('puts what cannot be served first', () => {
    // The line somebody has to act on. Sorted below the ready ones it would be
    // read last, which is the wrong way round for the only actionable item.
    expect(stagedLines(readiness).map((s) => s.label))
      .toEqual(['half-there', 'ready-a', 'ready-b'])
  })

  it('says how far short a half-staged model is', () => {
    // "Not ready" leaves an operator to work out whether to wait or to go and
    // push it. The count says which.
    expect(stagedLines(readiness)[0]!.note).toBe('on 1 of the 2 machines it needs')
  })

  it('says nothing at all for a pinned group', () => {
    expect(stagedLines({ state: 'ready', model: 'org/x', staged: [] })).toEqual([])
  })
})

describe('what unpinning a group will do', () => {
  const pool = { name: 'pool' }
  const staged = [{ id: 'org/a' }, { id: 'org/b' }]

  it('leads with what it keeps, because the fear is that it deletes', () => {
    // Unpinning reads as throwing the setup away, and the expensive part - the
    // weights - is exactly what stays.
    const out = unpinConsequences(pool, staged)
    expect(out[0]!.text).toContain('nothing is fetched again and nothing is deleted')
  })

  it('warns that the first request for a cold model pays the build', () => {
    expect(unpinConsequences(pool, staged).some((c) => c.level === 'cost'
      && /pays the build/.test(c.text))).toBe(true)
  })

  it('blocks when the group has been staged with nothing', () => {
    // It would stand there serving nothing, and the reason would only surface
    // as a refused request.
    const out = unpinConsequences(pool, [])
    expect(out.some((c) => c.level === 'blocked')).toBe(true)
    expect(out.find((c) => c.level === 'blocked')!.text).toContain('push a model to it first')
  })
})

/**
 * Tier as a property of the machine, not an arrangement of the fleet.
 *
 * The Machines page used to offer a toggle - Groups or Tiers - which presented
 * the two as alternative views of one fleet. They are not alternatives:
 * `whyNotInPool` refuses a cluster group any machine not already offered for
 * cluster, so a tier is a precondition for membership. The cost was concrete -
 * dragging a harvest-only machine onto a cluster group returned 409 and the
 * console stopped, and the operator had to switch view, grant the tier, switch
 * back, and drag again.
 */
describe('what a machine is offered for', () => {
  const node = (tiers: string[]) => ({ id: 'n1', hostname: 'orca', tiers }) as any

  it('adds a tier the machine does not have', () => {
    expect(tierToggle(node(['harvest']), 'cluster'))
      .toEqual({ action: 'add', next: ['harvest', 'cluster'] })
  })

  it('removes one it does have', () => {
    expect(tierToggle(node(['harvest', 'cluster']), 'cluster'))
      .toEqual({ action: 'remove', next: ['harvest'] })
  })

  it('refuses to leave a machine offered for nothing, and says why', () => {
    // Such a machine still runs, still heartbeats and never gets work, which
    // looks exactly like a broken agent and sends somebody to read logs.
    const out = tierToggle(node(['harvest']), 'harvest')
    expect(out.action).toBeUndefined()
    expect(out.refused).toContain('offered for something')
    expect(out.refused).toContain('never gets work')
  })

  it('reads the old scalar, for a fleet part-way through an upgrade', () => {
    expect(tierToggle({ id: 'n', hostname: 'h', tier: 'harvest' } as any, 'cluster'))
      .toEqual({ action: 'add', next: ['harvest', 'cluster'] })
  })
})

describe('putting a machine into a group it is not offered for', () => {
  const pool = (tier: string) => ({ id: 'p', name: 'split-cluster', tier }) as any
  const node = (tiers: string[]) => ({ id: 'n1', hostname: 'orca', tiers }) as any

  it('asks before adding a harvest-only machine to a cluster group', () => {
    const out = needsTierFor(node(['harvest']), pool('cluster'))!
    expect(out.tier).toBe('cluster')
    expect(out.next).toEqual(['harvest', 'cluster'])
    // The consequence, stated where the decision is made. A cluster machine is
    // never preempted, so a request can land on it while its owner is using it.
    expect(out.question).toContain('while somebody is using the machine')
  })

  it('asks nothing when the machine is already offered for cluster', () => {
    expect(needsTierFor(node(['harvest', 'cluster']), pool('cluster'))).toBeNull()
  })

  it('asks nothing for a harvest group, which takes anyone', () => {
    expect(needsTierFor(node(['harvest']), pool('harvest'))).toBeNull()
    expect(needsTierFor(node(['cluster']), pool('harvest'))).toBeNull()
  })
})

describe('the machines in a group that are also somebody desk', () => {
  const n = (hostname: string, tiers: string[]) => ({ hostname, tiers }) as any

  it('carries the warning the tier panel used to be the only home for', () => {
    // Deleting a view can delete a fact. This is the one the tier panel said
    // and the group cards did not.
    const out = bothTiersNote([n('orca', ['harvest', 'cluster']),
                               n('rotorua', ['cluster'])])!
    expect(out.count).toBe(1)
    expect(out.label).toBe('1 also harvest')
    expect(out.detail).toContain('while its owner is using it')
  })

  it('says nothing when no machine in the group is shared', () => {
    expect(bothTiersNote([n('a', ['cluster']), n('b', ['cluster'])])).toBeNull()
    expect(bothTiersNote([])).toBeNull()
  })
})

/**
 * The console's rule and the scheduler's rule, checked against each other.
 *
 * `needsTierFor` decides whether to offer to grant a tier before adding a
 * machine to a group. If it ever disagreed with `whyNotInPool`, the console
 * would either ask a pointless question or let a drop through that the server
 * then refuses - and a readiness view that disagrees with the router is worse
 * than none, because it is believed.
 *
 * Asserted against the scheduler's own function, imported here, rather than
 * against a second description of the rule. Binding a test to a reimplementation
 * is a mistake this codebase has already made once: the copy passed and the real
 * thing was wrong.
 */
describe('the console agrees with the scheduler about tiers', () => {
  // Membership that matches everything, so only the tier check can fire.
  const pool = (tier: string) => ({ id: 'p', name: 'g', tier, membership: {} }) as any

  it('offers the grant in exactly the cases the scheduler would refuse', () => {
    const shapes = [['harvest'], ['cluster'], ['harvest', 'cluster']]
    for (const tiers of shapes) {
      for (const poolTier of ['harvest', 'cluster']) {
        const p = pool(poolTier)
        // `nodes.tier` is a generated column over `nodes.tiers`: cluster if the
        // machine is offered for cluster at all. The scheduler reads the scalar
        // and the console reads the array, so the test derives one from the
        // other the same way Postgres does.
        const scheduler = {
          id: 'n1', hostname: 'orca', chip: 'Apple M4 Pro', memory_gb: 48,
          tier: tiers.includes('cluster') ? 'cluster' : 'harvest',
        } as any
        const ui = { id: 'n1', hostname: 'orca', tiers } as any

        const wouldRefuse = whyNotInPool(scheduler, p) !== null
        const wouldAsk = needsTierFor(ui, p) !== null
        expect(wouldAsk, `${tiers.join('+')} into a ${poolTier} group`).toBe(wouldRefuse)
      }
    }
  })

  it('grants exactly what the scheduler is waiting for', () => {
    // Not merely "some tier": the grant has to be the one that makes the
    // refusal stop, or the console asks a question and the drop still fails.
    const p = pool('cluster')
    const grant = needsTierFor({ id: 'n', hostname: 'orca', tiers: ['harvest'] } as any, p)!
    const after = {
      id: 'n', hostname: 'orca', chip: 'Apple M4 Pro', memory_gb: 48,
      tier: grant.next!.includes('cluster') ? 'cluster' : 'harvest',
    } as any
    expect(whyNotInPool(after, p)).toBeNull()
  })
})

/**
 * How long a join token has left.
 *
 * The listing exists so a token can be recognised and revoked; the full value is
 * returned once, by the call that mints it, and never again. So the only thing
 * this column has to get right is whether the token still works.
 */
describe('join token expiry', () => {
  const NOW = Date.parse('2026-08-31T12:00:00Z')
  const at = (hours: number) =>
    new Date(NOW + hours * 3_600_000).toISOString()

  it('counts in hours up to two days', () => {
    expect(expiresIn(at(1), NOW)).toBe('in 1h')
    expect(expiresIn(at(23), NOW)).toBe('in 23h')
    expect(expiresIn(at(47), NOW)).toBe('in 47h')
  })

  it('counts in days beyond that', () => {
    expect(expiresIn(at(48), NOW)).toBe('in 2d')
    expect(expiresIn(at(24 * 30), NOW)).toBe('in 30d')
  })

  /** The case the column exists for: this one will not let a machine in. */
  it('says expired rather than showing a negative interval', () => {
    expect(expiresIn(at(-1), NOW)).toBe('expired')
    expect(expiresIn(at(0), NOW)).toBe('expired')
  })

  it('does not round a token that is nearly gone up to an hour', () => {
    expect(expiresIn(new Date(NOW + 60_000).toISOString(), NOW))
      .toBe('under an hour')
  })

  it('handles a token with no expiry, and a malformed one', () => {
    expect(expiresIn(null, NOW)).toBe('never')
    expect(expiresIn('not a date', NOW)).toBe('unknown')
  })
})

/**
 * Which groups an idle-unload window means anything for.
 *
 * The control plane never sends one to a cluster group that has a model pinned
 * to it: dedicated means loaded, so a window would describe a release that never
 * happens. An unpinned cluster group is the opposite case and needs one, because
 * it holds whatever it was last asked for.
 */
describe('the idle window', () => {
  it('does not apply to a cluster group pinned to a model', () => {
    const r = idleWindowApplies({ tier: 'cluster', servingModelId: 'm' })
    expect(r.applies).toBe(false)
    expect(r.why).toContain('holds it loaded')
  })

  /** The case that is easy to get backwards. */
  it('applies to an unpinned cluster group', () => {
    expect(idleWindowApplies({ tier: 'cluster', servingModelId: null }).applies)
      .toBe(true)
  })

  it('applies to a harvest group either way', () => {
    expect(idleWindowApplies({ tier: 'harvest', servingModelId: 'm' }).applies)
      .toBe(true)
    expect(idleWindowApplies({ tier: 'harvest', servingModelId: null }).applies)
      .toBe(true)
  })

  it('says so rather than throwing when there is no group', () => {
    expect(idleWindowApplies(undefined).applies).toBe(false)
  })
})

/**
 * Unset against set-to-the-default.
 *
 * They read the same and behave differently: an unset knob follows the fleet if
 * the fleet changes, a set one does not.
 */
describe('knob labels', () => {
  it('names the fleet default when nothing is set', () => {
    expect(knobLabel(null, 300, 's')).toBe('fleet default (300s)')
    expect(knobLabel(undefined, 8, ' GB')).toBe('fleet default (8 GB)')
  })

  it('shows a set value plainly, including one equal to the default', () => {
    expect(knobLabel(300, 300, 's')).toBe('300s')
    expect(knobLabel(8, 8, ' GB')).toBe('8 GB')
  })

  /** Zero is a value somebody chose, not an absence. */
  it('treats zero as set', () => {
    expect(knobLabel(0, 8, ' GB')).toBe('0 GB')
  })
})
