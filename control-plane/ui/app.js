/**
 * Fleet view.
 *
 * No build step and no framework, so this runs anywhere the control plane runs
 * and can be read without tooling. The API is the contract; this is one client
 * of it, and deliberately not the only possible one.
 *
 * Column choices come from the spike rather than from convention. Working set
 * rather than installed RAM, because Metal caps itself near 81% of unified
 * memory. Headroom rather than free memory, because what matters is what policy
 * permits right now. Yields per week, because that is the early warning that a
 * policy is too aggressive for a particular machine.
 */

import {
  attentionItems, capacityOf, copyState, distributionOf, humanBytes, importCost,
  bucketFor, certificateStanding, clampWindow, describeTier, describeWindow,
  effectiveModelFor, suspensionNote,
  groupMachines, groupMismatches,
  inBothTiers, tierMachines, tiersAfter,
  groupMode, groupWarning, importProgress, isSynthetic, kindsFor,
  machinesThatCouldHold, matchesGroup, matchesQuery, nextSort, pauseAction, progressOf,
  rolloutState, servingFor, sortRows, upgradeOutcome, windowFromDrag,
  withFreshness,
  bodySkeleton, buildUrl, callableHere, formatResponse, groupOperations,
  isReadOnly, matchesOperation, operationsFrom, responseSize, statusTone,
  whyNotCallable,
} from './view.js'

const $ = (sel) => document.querySelector(sel)
const REFRESH_MS = 5000

/**
 * How much history the capacity graph shows, dragged rather than chosen from a
 * menu. Kept out of the URL so a poll cannot look like navigation, and out of
 * localStorage so a window somebody set once does not silently outlive the
 * question they set it for.
 */
let capacityWindow = 24 * 60 * 60

/**
 * The credential this browser holds.
 *
 * A session token from signing in, not a user id. The previous scheme put a
 * user id here and sent it as a bearer token: an identifier that comes back from
 * the jobs API, sits in the audit log and appears in any screenshot, granting
 * access that never expired and could not be revoked without deleting the
 * person.
 *
 * sessionStorage rather than localStorage, so closing the tab ends it. A console
 * that can pause somebody's Mac and replace its agent binary should not stay
 * signed in on a shared machine indefinitely.
 */
const session = {
  get: () => sessionStorage.getItem('dai.token') ?? '',
  set: (v) => sessionStorage.setItem('dai.token', v),
  clear: () => sessionStorage.removeItem('dai.token'),
}
async function api(path, options = {}) {
  const res = await fetch(`/admin/v1${path}`, {
    ...options,
    headers: {
      authorization: `Bearer ${session.get()}`,
      'content-type': 'application/json',
      ...(options.headers ?? {}),
    },
  })
  if (res.status === 401) {
    // Expired, revoked, or signed out in another tab. Showing an error toast
    // for every panel on the page would bury the one thing that helps.
    session.clear()
    showGate('login')
    throw new Error('signed out')
  }
  if (res.status === 403) {
    const body = await res.json().catch(() => ({}))
    if (body.error === 'password_change_required') {
      showGate('change')
      throw new Error(body.detail ?? 'password change required')
    }
    throw new Error(body.detail ?? 'not permitted')
  }
  if (!res.ok) {
    const body = await res.json().catch(() => ({}))
    throw new Error(body.detail ?? `${res.status} ${res.statusText}`)
  }
  return res.status === 204 ? null : res.json()
}

function toast(message, bad = false) {
  const el = $('#toast')
  el.textContent = message
  el.classList.toggle('bad', bad)
  el.hidden = false
  clearTimeout(toast._t)
  toast._t = setTimeout(() => { el.hidden = true }, 3600)
}

/* ---------------------------------------------------------------- capacity */

/**
 * Stacked area of eligible capacity.
 *
 * ANE is drawn as the base band because it is always available; GPU sits on top
 * because it appears only when machines lock. The shape of that upper band over
 * a day is the whole argument for harvesting, so it is the first thing on the
 * page.
 */
/**
 * Make the chart draggable.
 *
 * Bound once per mount, on the wrapper rather than the svg, so the target does
 * not vanish under the pointer when the series redraws mid-drag. Pointer events
 * rather than mouse events, so it works on a trackpad and a touchscreen without
 * a second code path.
 */
function bindChartDrag() {
  const wrap = document.querySelector('.chart-wrap')
  if (!wrap) return
  let from = null
  let startWindow = capacityWindow

  wrap.addEventListener('pointerdown', (e) => {
    from = e.clientX
    startWindow = capacityWindow
    wrap.setPointerCapture(e.pointerId)
    wrap.classList.add('dragging')
  })
  wrap.addEventListener('pointermove', (e) => {
    if (from === null) return
    const next = windowFromDrag(startWindow, e.clientX - from, wrap.clientWidth)
    if (next === capacityWindow) return
    capacityWindow = next
    // Label follows the pointer; the series follows the next poll, because
    // refetching on every pixel would put a query per frame on the database.
    const label = $('#window-label')
    if (label) label.textContent = describeWindow(capacityWindow)
  })
  const end = (e) => {
    if (from === null) return
    from = null
    wrap.classList.remove('dragging')
    if (e.pointerId !== undefined && wrap.hasPointerCapture?.(e.pointerId)) {
      wrap.releasePointerCapture(e.pointerId)
    }
    refresh()
  }
  wrap.addEventListener('pointerup', end)
  wrap.addEventListener('pointercancel', end)
}

function drawChart(series) {
  const svg = $('#chart')
  const label = $('#window-label')
  if (label) label.textContent = describeWindow(capacityWindow)
  svg.replaceChildren()
  const W = 900, H = 220, pad = { l: 46, r: 8, t: 10, b: 20 }

  if (series.length === 0) {
    const t = el('text', { x: W / 2, y: H / 2, 'text-anchor': 'middle', fill: 'var(--muted)',
      'font-size': 13 })
    // Names the window, because "no heartbeats" over ten minutes and over three
    // days mean very different things and the reader chose which one they asked.
    t.textContent = `No heartbeats in the ${describeWindow(capacityWindow).replace('last ', 'last ')}`
    svg.append(t)
    return
  }

  const max = Math.max(1, ...series.map((p) => p.gpuGb + p.aneGb))
  const x = (i) => pad.l + (i / Math.max(1, series.length - 1)) * (W - pad.l - pad.r)
  const y = (v) => H - pad.b - (v / max) * (H - pad.t - pad.b)

  for (let g = 0; g <= 2; g++) {
    const v = (max / 2) * g
    svg.append(el('line', { x1: pad.l, x2: W - pad.r, y1: y(v), y2: y(v),
      stroke: 'var(--line)', 'stroke-width': 1 }))
    const label = el('text', { x: pad.l - 8, y: y(v) + 4, 'text-anchor': 'end',
      fill: 'var(--muted)', 'font-size': 11 })
    label.textContent = `${Math.round(v)}G`
    svg.append(label)
  }

  const band = (lower, upper, fill) => {
    const up = series.map((p, i) => `${x(i)},${y(upper(p))}`)
    const down = series.map((p, i) => `${x(i)},${y(lower(p))}`).reverse()
    svg.append(el('polygon', { points: [...up, ...down].join(' '), fill, 'fill-opacity': 0.55 }))
  }
  band(() => 0, (p) => p.aneGb, 'var(--ane)')
  band((p) => p.aneGb, (p) => p.aneGb + p.gpuGb, 'var(--gpu)')

  const first = new Date(series[0].hour), last = new Date(series[series.length - 1].hour)
  for (const [pos, when] of [[pad.l, first], [W - pad.r, last]]) {
    const t = el('text', { x: pos, y: H - 5, fill: 'var(--muted)', 'font-size': 11,
      'text-anchor': pos === pad.l ? 'start' : 'end' })
    // Seconds appear only when the window is short enough for them to mean
    // something; a three day span labelled to the second is noise.
    t.textContent = capacityWindow <= 3600
      ? when.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
      : capacityWindow > 86400
        ? when.toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit' })
        : when.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
    svg.append(t)
  }
}

function el(name, attrs) {
  const node = document.createElementNS('http://www.w3.org/2000/svg', name)
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v))
  return node
}

/* ------------------------------------------------------------------- nodes */

const GPU_STATES = new Set(['LOCKED', 'ABSENT'])

let lastNodeSignature = null

let lastJobSignature = ''

/**
 * What is queued, what it is, and where it came from.
 *
 * The source column exists mainly for the synthetic case. Work generated by a
 * harness has to be visibly synthetic here, or capacity and throughput read as
 * real activity when they are somebody's load test.
 */
function renderJobs(jobs) {
  const shown = arrange(jobs, 'jobs', JOB_COLUMNS, JOB_FIELDS)
  const signature = JSON.stringify([tables.jobs.query, tables.jobs.sort])
    + JSON.stringify(shown.map((j) => [j.id, j.state, j.counts]))
  if (signature === lastJobSignature) return
  lastJobSignature = signature

  const body = $('#jobs tbody')
  body.replaceChildren()
  $('#jobs-empty').hidden = jobs.length > 0

  for (const j of shown) {
    const progress = progressOf(j)
    const synthetic = isSynthetic(j)
    const tr = document.createElement('tr')
    tr.innerHTML = `
      <td>${escape(j.label ?? '(unlabelled)')}</td>
      <td><span class="kind ${j.kind === 'embed' ? 'on-ane' : 'on-gpu'}">${escape(j.kind)}</span></td>
      <td><span class="pill ${synthetic ? 'synthetic' : ''}">${escape(j.source ?? 'api')}</span></td>
      <td>${escape(j.submittedBy ?? '&mdash;')}</td>
      <td class="num">${progress.done}/${progress.total} (${progress.percent}%)</td>
      <td><span class="pill ${escape(j.state)}">${escape(j.state)}</span></td>`
    body.append(tr)
  }

  bindTableControls('jobs', () => { lastJobSignature = ''; if (lastData) paint(lastData) })
}

function renderNodes(nodes, details) {
  // Only rebuild when something actually changed. Replacing the table on every
  // poll destroys hover state and swallows clicks that land mid-refresh, which
  // is exactly what happened the first time this was driven by hand.
  const shown = arrange(nodes, 'nodes', NODE_COLUMNS, NODE_FIELDS)
  const signature = JSON.stringify([tables.nodes.query, tables.nodes.sort]) + JSON.stringify(shown.map((n) => [
    // n.state included so the row redraws when it changes: without it the
    // button kept its old label after a successful pause.
    n.id, n.hostname, n.presenceState, n.state, n.userPaused,
    // Serving state included, or a node that starts or stops answering never
    // redraws and keeps its old label indefinitely - the bug the pause button
    // had before its state joined this list.
    n.serving, n.inFlight, (n.models ?? []).join(','),
    details.get(n.id)?.headroomGb, details.get(n.id)?.yields7d,
  ]))
  if (signature === lastNodeSignature) return
  lastNodeSignature = signature

  const body = $('#nodes tbody')
  body.replaceChildren()
  $('#nodes-empty').hidden = nodes.length > 0
  // Told apart on purpose: an empty fleet and a search that matched nothing
  // look identical otherwise, and one of them is somebody's typo.
  $('#nodes-none').hidden = !(nodes.length > 0 && shown.length === 0)

  for (const n of shown) {
    const d = details.get(n.id)
    // A machine its owner paused runs nothing, whatever its presence says, so
    // showing it as available capacity would be a lie the fleet view tells
    // about a decision somebody made deliberately.
    const kinds = kindsFor(n)
    const serving = servingFor(n)
    const action = pauseAction(n)
    // Why this machine is offered nothing, when the reason is not idleness. A
    // suspended machine is doing what it was told to and there is nothing to
    // fix, which is exactly why it must not read as a quiet one.
    const note = suspensionNote(n)
    const tr = document.createElement('tr')
    tr.innerHTML = `
      <td><b>${escape(n.hostname)}</b></td>
      <td>${escape(n.chip ?? '')}</td>
      <td class="num">${fmt(n.metalWorkingSetGb)} GB</td>
      <td class="num">${d ? `${fmt(d.headroomGb)} GB` : '&mdash;'}</td>
      <td><span class="pill ${escape(n.presenceState ?? '')}">${escape(n.presenceState ?? 'unknown')}</span></td>
      <td><span class="kinds">
        ${action.kind === 'none' ? '<span class="kind paused-by-user">paused by owner</span>' : `
        ${note ? `<span class="kind suspended" title="${escape(note)}">suspended</span>` : ''}
        ${kinds.map((k) => `<span class="kind ${k === 'embed' ? 'on-ane' : 'on-gpu'}">${k}</span>`).join('')}`}
      </span></td>
      <td><span class="serving ${serving.state}">${escape(serving.label)}</span>${
        serving.models.length > 0
          ? `<div class="muted">${escape(serving.models.map((m) => m.split('/').pop()).join(', '))}</div>`
          : ''}</td>
      <td class="num">${d ? d.yields7d : '&mdash;'}</td>
      <td><span class="pill ${n.state === 'paused' ? 'paused' : ''}">${escape(n.state)}</span></td>
      ${n.userPaused
        // No admin control offered, because there is none. The button would
        // have to either lie or fail, and a disabled control at least says the
        // truth: this is not yours to lift.
        ? `<td><span class="muted" title="Only the person at that machine can resume it">${escape(action.label)}</span></td>`
        // Reflects the state rather than assuming one. It always said "Pause",
        // so pausing a node left a button that appeared to do nothing and there
        // was no way back: a one-way door dressed as a toggle.
        : `<td><button data-action="${action.kind}" data-node="${n.id}">${escape(action.label)}</button></td>`}`
    tr.addEventListener('click', (ev) => {
      if (ev.target.closest('button')) return
      openNode(n.id)
    })
    body.append(tr)
  }

  bindTableControls('nodes', () => { lastNodeSignature = null; if (lastData) paint(lastData) })

  body.querySelectorAll('[data-action]').forEach((btn) =>
    btn.addEventListener('click', async () => {
      const { action, node } = btn.dataset
      try {
        await api(`/nodes/${node}/${action}`, { method: 'POST', body: '{}' })
        // The owner of a machine can always pause it, whatever roles say.
        toast(action === 'pause'
          ? 'Paused. The node stops receiving work immediately.'
          : 'Resumed. The node will take work again when its presence allows.')
        refresh()
      } catch (err) { toast(err.message, true) }
    }))
}

/* ------------------------------------------------------------------ drawer */

/**
 * One drawer, four jobs, and a way back between them.
 *
 * It shows machine detail, a model's placement, where to push a model, and what
 * could be added. Each of those replaced whatever was there with no title
 * saying what kind of thing you were looking at and no way to return, so
 * following a model into a machine meant closing the drawer and finding the
 * machine again by hand.
 *
 * A stack rather than history, because the entries are cheap to re-render and
 * the alternative - putting drawer state in the URL - would make a poll that
 * changes nothing look like navigation.
 */
const drawer = {
  stack: [],

  /** Replace the stack, for a drawer opened from the page. */
  open(entry) {
    this.stack = [entry]
    this.render()
  },

  /** Push, for a drawer opened from inside another one. */
  push(entry) {
    this.stack.push(entry)
    this.render()
  },

  back() {
    this.stack.pop()
    this.stack.length === 0 ? this.close() : this.render()
  },

  close() {
    this.stack = []
    $('#drawer').hidden = true
  },

  /** Re-run the top entry's renderer, so a reopened drawer is not stale. */
  async render() {
    const top = this.stack[this.stack.length - 1]
    if (!top) return this.close()

    $('#drawer-title').innerHTML = `
      ${this.stack.length > 1
        ? '<button class="link back" id="drawer-back">&larr; Back</button>'
        : ''}
      <span class="kicker">${escape(top.kind)}</span>
      <span class="name">${escape(top.title)}</span>`
    $('#drawer-body').innerHTML = '<p class="dim">Loading&hellip;</p>'
    $('#drawer').hidden = false

    const back = document.querySelector('#drawer-back')
    if (back) back.addEventListener('click', () => this.back())

    try {
      const html = await top.body()
      // Guard against a slow fetch landing after somebody navigated away, which
      // would drop the contents of one panel into the header of another.
      if (this.stack[this.stack.length - 1] !== top) return
      $('#drawer-body').innerHTML = html
      top.mount?.($('#drawer-body'))
    } catch (err) {
      $('#drawer-body').innerHTML = `<p class="dim">${escape(err.message)}</p>`
    }
  },
}


function openNode(id, { push = false } = {}) {
  const entry = {
    kind: 'Machine',
    title: id,
    async body() {
      const d = await api(`/nodes/${id}/detail`)
      this.title = d.hostname
      $('#drawer-title .name').textContent = d.hostname
      return `
      <dl class="kv">
        <dt>Chip</dt><dd>${escape(d.chip ?? '')}</dd>
        <dt>Unified memory</dt><dd>${fmt(d.memoryGb)} GB</dd>
        <dt>Metal working set</dt><dd>${fmt(d.metalWorkingSetGb)} GB</dd>
        <dt>Headroom now</dt><dd>${fmt(d.headroomGb)} GB</dd>
        <dt>Presence</dt><dd>${escape(d.presenceState ?? 'unknown')}</dd>
        ${d.userPaused ? `<dt>Owner</dt><dd class="paused-by-user">paused this machine${
          d.userPausedAt ? ` ${new Date(d.userPausedAt).toLocaleString()}` : ''
        }</dd>` : ''}
        <dt>Agent</dt><dd>${escape(d.agentVersion ?? 'unknown')}${
          d.agentFingerprint
            ? ` <span class="muted" title="sha256 of the running executable">${
                escape(String(d.agentFingerprint).slice(0, 12))}</span>`
            : ''
        }</dd>
        <dt>Certificate</dt><dd>${certLine(d)}</dd>
        ${Object.keys(d.syncFaults ?? {}).length > 0 ? `<dt>Not holding</dt><dd class="fault">${
          Object.entries(d.syncFaults).map(([id, why]) =>
            `${escape(id === '*' ? 'model sync' : id.split('/').pop())}: ${escape(why)}`).join('<br>')
        }</dd>` : ''}
        <dt>On AC power</dt><dd>${d.onAcPower === null ? '&mdash;' : d.onAcPower}</dd>
        <dt>Yields (7d)</dt><dd>${d.yields7d}</dd>
        <dt>Pinned networks</dt><dd>${escape(d.allowedCidrs ?? 'unpinned')}</dd>
      </dl>
      ${d.policy ? policyBlock(d.policy) : ''}
      <h3 style="font-size:12px;color:var(--muted);text-transform:uppercase;
        letter-spacing:.07em;margin:18px 0 4px">Idle pattern</h3>
      <p class="note" style="margin-bottom:6px">
        Share of samples in each hour where the machine was locked or logged out.
        Answers whether an eight hour job can be scheduled here.
      </p>
      ${idleBlock(d.idlePattern)}
      <h3 style="font-size:12px;color:var(--muted);text-transform:uppercase;
        letter-spacing:.07em;margin:18px 0 6px">Activity</h3>
      <p class="note" style="margin-bottom:8px">
        Readable by this machine's owner regardless of roles. Without it, any
        unrelated slowdown gets blamed on the agent with no way to check.
      </p>
      <div class="log">${d.activity.map(logLine).join('') || '<div>Nothing yet</div>'}</div>`
    },
  }
  push ? drawer.push(entry) : drawer.open(entry)
}

/**
 * When this machine's certificate runs out, and the way to get it a new one.
 *
 * The button is here rather than on the machine itself because the machine
 * cannot be asked directly: the key lives in the Secure Enclave and signs only
 * inside the launchd daemon, so `dai-agent renew` over ssh fails even as root.
 * The request rides the heartbeat the node already sends, which is also why
 * nothing happens instantly - a node that is asleep or offline picks it up when
 * it next reports in, and until then the request stands.
 */
function certLine(d) {
  const c = certificateStanding(d)
  const when = d.certNotAfter ? new Date(d.certNotAfter).toLocaleDateString() : ''
  return `${escape(when)} <span class="${c.state === 'valid' ? 'muted' : 'fault'}">(${
    escape(c.detail)})</span> ${c.canAsk
      ? `<button data-renew="${d.id}">Ask to renew</button>`
      : c.asked
        ? `<span class="muted" title="Sent on this node's next heartbeat">renewal asked ${
            escape(new Date(c.asked).toLocaleString())}</span>`
        : ''}`
}

/**
 * Wired on the drawer rather than at render time, because the drawer redraws
 * its body and a listener bound to a replaced node stops firing.
 */
document.addEventListener('click', async (ev) => {
  const btn = ev.target.closest('[data-renew]')
  if (!btn) return
  btn.disabled = true
  try {
    await api(`/nodes/${btn.dataset.renew}/renew`, { method: 'POST', body: '{}' })
    toast('Asked. The node renews on its next heartbeat, which also gives it '
      + 'the node CA it needs to join a split.')
  } catch (err) { btn.disabled = false; toast(err.message, true) }
})

function policyBlock(p) {
  return `<dl class="kv">
    <dt>GPU permitted</dt><dd>${p.gpu}</dd>
    <dt>ANE permitted</dt><dd>${p.ane}</dd>
    <dt>QoS</dt><dd>${escape(p.qos)}</dd>
    <dt>Duty ceiling</dt><dd>${p.dutyMax}</dd>
    <dt>Memory fraction</dt><dd>${p.memFrac}</dd>
  </dl>`
}

function idleBlock(pattern) {
  const byHour = new Array(24).fill(null).map(() => ({ total: 0, free: 0 }))
  for (const row of pattern) {
    const h = byHour[row.hour]
    if (!h) continue
    h.total += row.n
    if (GPU_STATES.has(row.presence_state)) h.free += row.n
  }
  const bars = byHour.map((h) => {
    const pct = h.total ? Math.round((h.free / h.total) * 100) : 0
    return `<i class="${h.total ? '' : 'none'}" style="height:${Math.max(pct, 2)}%"
      title="${pct}% free"></i>`
  }).join('')
  return `<div class="hours">${bars}</div>
    <div class="hour-axis"><span>00</span><span>06</span><span>12</span>
      <span>18</span><span>23</span></div>`
}

function logLine(entry) {
  const when = new Date(entry.at).toLocaleString()
  return `<div><b>${escape(entry.event)}</b> &middot; ${escape(when)}
    ${escape(JSON.stringify(entry.detail))}</div>`
}

/* ----------------------------------------------------------------- refresh */

/* ------------------------------------------------------------------ models */

/**
 * The catalogue, and the gap between declared and actual.
 *
 * The table leads on distribution rather than on size or date, because the only
 * question worth asking of this list is which machines are missing something
 * they were told to have. Everything else is reference.
 */
/**
 * Imports in flight, above the catalogue rather than inside it.
 *
 * A model appears in the catalogue only once every file has landed and hashed,
 * which is right - a half-registered model would be assignable and unfetchable
 * - but it left minutes during which an eighteen gigabyte import showed nothing
 * anywhere, and the only honest reading of the page was that it had failed.
 */
function renderImports(imports) {
  const box = $('#imports')
  if (!box) return
  if (imports.length === 0) { box.innerHTML = ''; return }

  box.innerHTML = imports.map((row) => {
    const p = importProgress(row)
    return `<section class="panel import ${p.state}">
      <div class="import-head">
        <b class="mono">${escape(row.modelId)}</b>
        <span class="dim">${escape(p.label)}</span>
        ${p.percent === null ? '' : `<span class="pct">${p.percent}%</span>`}
      </div>
      <div class="bar"><i style="width:${p.percent ?? 8}%"
        class="${p.percent === null ? 'indeterminate' : ''}"></i></div>
    </section>`
  }).join('')
}

let lastModelSignature = ''

function renderModels(models, pools) {
  // Same reason as the node table: replacing rows on every poll destroys hover
  // state and swallows clicks that land mid-refresh.
  const shown = arrange(models, 'models', MODEL_COLUMNS, MODEL_FIELDS)
  const signature = JSON.stringify([tables.models.query, tables.models.sort])
    + JSON.stringify(shown.map((m) => [
      m.id, m.nodesHolding, m.nodesWanting, (m.assignedPools ?? []).join(','),
    ])) + JSON.stringify(pools.map((p2) => [p2.id, p2.name]))
  if (signature === lastModelSignature) return
  lastModelSignature = signature

  const body = document.querySelector('#models tbody')
  document.querySelector('#models-empty').hidden = models.length > 0
  const poolName = new Map(pools.map((p) => [p.id, p.name]))

  body.innerHTML = shown.map((m) => {
    const d = distributionOf(m)
    const assigned = (m.assignedPools ?? []).map((id) => poolName.get(id) ?? id)
    return `<tr data-model="${escape(m.id)}">
      <td class="mono">${escape(m.id)}</td>
      <td>${escape(m.runtime)} &middot; ${escape(m.kind)}</td>
      <td class="num">${humanBytes(m.sizeBytes)}</td>
      <td class="num">${m.contextLength ? m.contextLength.toLocaleString() : '—'}</td>
      <td>${assigned.length ? assigned.map(escape).join(', ') : '<span class="dim">nowhere</span>'}</td>
      <td><span class="pill ${d.state}">${escape(d.label)}</span></td>
      <td class="actions">
        <button class="link" data-place="${escape(m.id)}">Placement</button>
        <button class="link" data-push="${escape(m.id)}">Push&hellip;</button>
      </td>
    </tr>`
  }).join('')

  bindTableControls('models', () => { lastModelSignature = ''; if (lastData) paint(lastData) })

  for (const btn of body.querySelectorAll('[data-place]')) {
    btn.addEventListener('click', () => showPlacement(btn.dataset.place))
  }
  for (const btn of body.querySelectorAll('[data-push]')) {
    btn.addEventListener('click', () => showPush(btn.dataset.push, models, pools))
  }
}

/**
 * Pushing a model to workstations.
 *
 * A pool rather than a machine, deliberately. Assigning to a list of machines
 * describes today's fleet; assigning to a pool describes the intent, and a
 * machine enrolled next week inherits it without anybody remembering to go back
 * and add it.
 *
 * Nothing is transferred here. The declaration is recorded and nodes reconcile
 * toward it when they are free, because a machine that is asleep or in use
 * cannot be pushed to and a mechanism that only works on a machine somebody is
 * watching is not a fleet mechanism.
 */
function showPush(modelId, models, pools) {
  const model = models.find((m) => m.id === modelId)
  const assigned = new Set(model?.assignedPools ?? [])
  drawer.open({
    kind: 'Push to workstations',
    title: modelId,
    body: () => `
    <p class="dim">${humanBytes(model?.sizeBytes)}. Declares that every machine in
       the pool should hold these weights. Nodes fetch them when nobody is at the
       machine, verify every file against its hash, and report back.</p>
    <table class="mini"><tbody>
    ${pools.map((p) => `
      <tr>
        <td>${escape(p.name)}<br><span class="dim">${escape(p.tier)} tier</span></td>
        <td style="text-align:right">
          <button class="${assigned.has(p.id) ? '' : 'primary'}"
                  data-pool="${escape(p.id)}"
                  data-on="${assigned.has(p.id) ? '1' : ''}">
            ${assigned.has(p.id) ? 'Stop pushing' : 'Push to this pool'}
          </button>
        </td>
      </tr>`).join('')}
    </tbody></table>`,
    mount(root) {
      for (const btn of root.querySelectorAll('[data-pool]')) {
        btn.addEventListener('click', async () => {
          const on = btn.dataset.on === '1'
          btn.disabled = true
          try {
            await api(`/pools/${btn.dataset.pool}/models/${encodeURIComponent(modelId)}`,
              { method: on ? 'DELETE' : 'PUT' })
            toast(on ? 'no longer pushed' : 'pushed; machines will fetch when free')
            drawer.close()
            refresh()
          } catch (err) {
            toast(err.message, true)
            btn.disabled = false
          }
        })
      }
    },
  })
}

/**
 * Choosing a model to add.
 *
 * Local candidates first, and the cost of each said out loud. A model already
 * on this machine is a copy; one from the internet crosses the building's
 * uplink, which is the thing this product exists to avoid doing casually, so
 * the word download appears on screen rather than being implied.
 */
function showAddModel(nodes) {
  drawer.open({
    kind: 'Add a model',
    title: 'from this machine, or the internet',
    async body() {
      const available = await api('/models/available')
      return `
      <p class="dim">Models already on this machine are listed first: importing one
         is a copy, and hashes every file so a truncated shard cannot pass as good.</p>
      <table class="mini"><tbody>
      ${available.map((c) => {
        const cost = importCost(c)
        const fit = machinesThatCouldHold(c.sizeBytes, nodes)
        return `<tr>
          <td>
            <span class="mono">${escape(c.id)}</span><br>
            <span class="dim">${humanBytes(c.sizeBytes)} &middot;
              ${fit.fits} of ${fit.total} machines could hold it</span>
            ${c.note ? `<br><span class="dim">${escape(c.note)}</span>` : ''}
          </td>
          <td style="text-align:right">
            <span class="pill ${cost.state}">${escape(cost.label)}</span><br>
            ${c.registered ? ''
              : c.source === 'local'
                ? `<button class="primary" data-import="${escape(c.id)}">Import</button>`
                : '<span class="dim">not yet downloadable</span>'}
          </td>
        </tr>`
      }).join('')}
      </tbody></table>`
    },
    mount(root) {
      for (const btn of root.querySelectorAll('[data-import]')) {
        btn.addEventListener('click', async () => {
          btn.disabled = true
          btn.textContent = 'Importing\u2026'
          try {
            await api('/models/import', {
              method: 'POST', body: JSON.stringify({ id: btn.dataset.import }),
            })
            // Closed rather than left open, because the progress bar on the
            // page behind is now the honest account of what happens next.
            toast('importing: hashing and copying, watch the progress above')
            drawer.close()
            refresh()
          } catch (err) {
            toast(err.message, true)
            btn.disabled = false
            btn.textContent = 'Import'
          }
        })
      }
    },
  })
}

/** Per machine, for one model: wanted, held, loaded. */
function showPlacement(modelId) {
  drawer.open({
    kind: 'Placement',
    title: modelId,
    async body() {
      const m = await api(`/models/${encodeURIComponent(modelId)}`)
      return `
      <p class="dim">${humanBytes(m.sizeBytes)} across ${m.fileCount} files,
         every one hashed. ${m.family ? `Template family ${escape(m.family)}.` : ''}</p>
      ${m.history?.length ? `<div class="history">
        ${m.history.slice(0, 4).map((h) => `<div>
          <b>${escape(h.action.replace('model.', ''))}</b>
          ${h.by ? `by ${escape(h.by)}` : ''}
          &middot; ${escape(new Date(h.at).toLocaleString())}
        </div>`).join('')}
      </div>` : ''}
      <table class="mini"><thead><tr><th>Machine</th><th>State</th></tr></thead><tbody>
      ${m.placement.map((p) => {
        const c = copyState(p)
        // The machine is a link into its own drawer, which is why the stack
        // exists: following a model to a machine used to mean closing this and
        // finding the machine again by hand.
        return `<tr><td><button class="link" data-node="${escape(p.nodeId)}">
                  ${escape(p.hostname)}</button></td>
                <td><span class="pill ${c.state}">${escape(c.label)}</span></td></tr>`
      }).join('')}
      </tbody></table>`
    },
    mount(root) {
      for (const b of root.querySelectorAll('[data-node]')) {
        b.addEventListener('click', () => openNode(b.dataset.node, { push: true }))
      }
    },
  })
}

/* -------------------------------------------------------------- signing in */

/**
 * Show the sign-in gate, or put it away.
 *
 * `change` is the same gate with the password form instead. A deployment still
 * on the shipped password reaches only this: the server refuses everything else
 * until it is changed, so a console with a dismissible reminder would just be a
 * console that does not work.
 */
function showGate(which) {
  const gate = $('#gate')
  if (!gate) return
  if (which === null) {
    gate.hidden = true
    document.querySelector('.shell')?.removeAttribute('inert')
    return
  }
  gate.hidden = false
  // The page behind is made inert rather than merely covered, so nothing behind
  // the gate can be reached by tabbing into it.
  document.querySelector('.shell')?.setAttribute('inert', '')
  $('#login-form').hidden = which !== 'login'
  $('#change-form').hidden = which !== 'change'
  ;(which === 'login' ? $('#login-user') : $('#change-current')).focus()
}

function gateError(id, message) {
  const el = $(id)
  el.textContent = message
  el.hidden = !message
}

async function signIn(event) {
  event.preventDefault()
  gateError('#login-error', '')
  try {
    const res = await fetch('/admin/v1/auth/login', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        username: $('#login-user').value.trim(),
        password: $('#login-pass').value,
      }),
    })
    const body = await res.json().catch(() => ({}))
    if (!res.ok) {
      gateError('#login-error', body.detail ?? 'could not sign in')
      return
    }
    session.set(body.token)
    // Read before the field is cleared. Clearing first filled the change form's
    // "current password" with an empty string, so the only route out of a
    // forced password change was blocked by a required field the person had no
    // reason to think was empty.
    const used = $('#login-pass').value
    $('#login-pass').value = ''
    signedInAs(body.username ?? body.email)

    if (body.mustChangePassword) {
      // Straight to the form rather than to a console that will refuse every
      // request. The current password is known here, so it is filled in.
      $('#change-current').value = used
      showGate('change')
      return
    }
    showGate(null)
    refresh()
  } catch (err) {
    gateError('#login-error', err.message)
  }
}

async function changePassword(event) {
  event.preventDefault()
  gateError('#change-error', '')
  const next = $('#change-new').value
  if (next !== $('#change-again').value) {
    // Checked here rather than server side, because the server never sees the
    // second field and a mismatch is a typing mistake, not a policy failure.
    gateError('#change-error', 'the two new passwords do not match')
    return
  }
  try {
    const res = await fetch('/admin/v1/auth/password', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${session.get()}`,
      },
      body: JSON.stringify({
        currentPassword: $('#change-current').value,
        newPassword: next,
      }),
    })
    const body = await res.json().catch(() => ({}))
    if (!res.ok) {
      gateError('#change-error', body.detail ?? 'could not change the password')
      return
    }
    for (const id of ['#change-current', '#change-new', '#change-again']) $(id).value = ''
    showGate(null)
    toast(body.otherSessionsEnded
      ? `password changed, ${body.otherSessionsEnded} other session(s) ended`
      : 'password changed')
    refresh()
  } catch (err) {
    gateError('#change-error', err.message)
  }
}

function signedInAs(who) {
  const el = $('#signed-in-as')
  if (el) el.textContent = who ?? ''
}

async function signOut() {
  try {
    await fetch('/admin/v1/auth/logout', {
      method: 'POST', headers: { authorization: `Bearer ${session.get()}` },
    })
  } catch { /* the credential is being discarded either way */ }
  session.clear()
  signedInAs('')
  showGate('login')
}

/** On load: use the stored token if it still works, otherwise ask. */
async function resumeOrAsk() {
  if (!session.get()) { showGate('login'); return false }
  try {
    const me = await api('/auth/me')
    signedInAs(me.username ?? me.email)
    if (me.mustChangePassword) { showGate('change'); return false }
    showGate(null)
    return true
  } catch {
    // api() has already shown the right gate for a 401 or a pending password
    // change; anything else means the console is unusable anyway.
    return false
  }
}

/* ------------------------------------------------------------------ groups */

/**
 * Machines arranged by the group they belong to.
 *
 * Groups were invisible everywhere but the models page, which said a model was
 * pushed to "overnight-harvest" while nothing else acknowledged that such a
 * thing existed. They are the unit models are pushed to and work is scheduled
 * against, so they belong at the top of the page about machines.
 *
 * Machines are dragged between them. A group that is a rule rather than a list
 * refuses the first drop and says what it would cost, because converting one
 * into the other changes who belongs and doing that silently is how a fleet
 * loses half its machines without anybody touching them.
 */
/**
 * Which way the fleet is arranged on this page.
 *
 * Groups are what work is scheduled against. Tiers are what a machine is
 * offered for, and a machine can be in both of them, so they are two views of
 * one fleet rather than two halves of it. Kept in the URL so a link to "the
 * fleet by tier" is a link somebody can send.
 */
function currentAxis() {
  return new URLSearchParams(location.hash.split('?')[1] ?? '').get('by') === 'tiers'
    ? 'tiers' : 'groups'
}

function renderGroups(nodes, pools, models) {
  const box = $('#groups')
  if (!box) return

  for (const b of document.querySelectorAll('#axis button')) {
    b.classList.toggle('on', b.dataset.axis === currentAxis())
  }
  const newGroup = $('#new-group')
  if (newGroup) newGroup.hidden = currentAxis() === 'tiers'

  if (currentAxis() === 'tiers') return renderTiers(box, nodes)

  const { groups, ungrouped } = groupMachines(nodes, pools, matchesGroup)

  const card = (title, subtitle, members, poolId, warning, extra = '', off = false) => `
    <section class="panel group${off ? ' stood-down' : ''}" ${poolId ? `data-drop="${escape(poolId)}"` : ''}>
      <div class="panel-head">
        <h2>${escape(title)}</h2>
        ${warning ? `<span class="triangle ${warning.level}"
          title="${escape(warning.reasons.join('\n'))}">&#9650;</span>
          <span class="hint ${warning.level}">${escape(warning.label)}</span>` : ''}
        <span class="hint">${escape(subtitle)}</span>
        ${extra}
      </div>
      ${members.length === 0
        ? '<p class="empty">Nothing here. Drag a machine in.</p>'
        : `<div class="chips">${members.map((n) => `
            <div class="machine-chip" draggable="true" data-node="${escape(n.id)}"
                 data-from="${poolId ? escape(poolId) : ''}">
              <b>${escape(n.hostname)}</b>
              <span>${escape(n.chip ?? '')} &middot; ${fmt(n.memoryGb ?? n.memory_gb)} GB</span>
              ${poolId ? `<button class="link remove" data-remove="${escape(n.id)}"
                data-pool="${escape(poolId)}" title="Take out of this group">&times;</button>` : ''}
            </div>`).join('')}</div>`}
    </section>`

  box.innerHTML = groups.map((g) => {
    // Every group, not just this one: a machine's model can be decided by a
    // cluster group this card is not about.
    const warning = groupWarning(groupMismatches(g.pool, g.nodes, models, pools))
    const mode = g.mode === 'list' ? 'hand-picked list' : 'a rule machines match'
    // The socket is on the card because it is the address somebody points an
    // application at. A group whose port lives only in the database is one an
    // operator has to go and look up, which is how they end up pointing at the
    // wrong group's machines.
    const at = g.pool.servingPort
      ? `, answering on :${g.pool.servingPort}`
      : ''
    const socket = g.pool.servingPort ? '' : `
      <button class="link" data-socket="${escape(g.pool.id)}"
              title="Give this group a port of its own, so clients can address it directly"
              >give it a socket</button>`
    // Standing a group down keeps everything it has and asserts none of it,
    // which is how its machines are handed back without dismantling the group.
    const off = g.pool.enabled === false
    const remove = `<button class="link danger" data-delete="${escape(g.pool.id)}"
              title="Delete this group: its jobs, model assignments and roles go with it"
              >delete</button>`
    const stand = `<button class="link" data-enabled="${escape(g.pool.id)}"
              data-to="${off ? 'true' : 'false'}"
              title="${off
                ? 'Bring this group back: it starts deciding what its machines serve again'
                : 'Stand this group down: it keeps its machines, model and socket, and asserts none of them'}"
              >${off ? 'bring it back' : 'stand it down'}</button>`
    const state = off ? 'stood down, ' : ''
    return card(g.pool.name, `${state}${g.pool.tier} tier, ${mode}${at}`, g.nodes, g.pool.id,
                warning, socket + stand + remove, off)
  }).join('') + (ungrouped.length > 0
    ? card('In no group', 'not scheduled by any pool, and holding no assigned models',
      ungrouped, null, null)
    : '')

  // Groups made before sockets existed. Asked for rather than backfilled: the
  // schema will not open ports nobody requested during an upgrade, so somebody
  // has to say so once per group.
  // Deleting asks first, and what it asks with is the control plane's own
  // sentence rather than a generic "are you sure": the refusal names the jobs,
  // the assignments and the machines, which is the part somebody needs to weigh.
  box.querySelectorAll('[data-delete]').forEach((btn) =>
    btn.addEventListener('click', async (ev) => {
      ev.stopPropagation()
      const id = btn.dataset.delete
      try {
        await api(`/pools/${id}`, { method: 'DELETE' })
        toast('deleted')
        refresh()
      } catch (err) {
        // The 409 is the question. Anything else is a real failure.
        if (!/would be freed|comes back/.test(err.message)) { toast(err.message, true); return }
        if (!confirm(`${err.message}\n\nDelete it anyway?`)) return
        try {
          const gone = await api(`/pools/${id}?confirm=true`, { method: 'DELETE' })
          toast(`deleted ${gone.name}${gone.retiredPort
            ? `, port ${gone.retiredPort} retired` : ''}`)
          refresh()
        } catch (e) { toast(e.message, true) }
      }
    }))

  box.querySelectorAll('[data-enabled]').forEach((btn) =>
    btn.addEventListener('click', async (ev) => {
      ev.stopPropagation()
      btn.disabled = true
      try {
        const to = btn.dataset.to === 'true'
        const said = await api(`/pools/${btn.dataset.enabled}/enabled`,
                               { method: 'PUT', body: JSON.stringify({ enabled: to }) })
        // What the machines do next, which is the reason somebody pressed it.
        const moved = (said.machines ?? [])
          .map((m) => `${m.hostname} now serves ${
            m.nowServes ? m.nowServes.split('/').pop() : 'nothing'}`)
          .join('; ')
        toast(`${said.name} ${to ? 'is back' : 'stood down'}${moved ? `: ${moved}` : ''}`)
        refresh()
      } catch (err) { btn.disabled = false; toast(err.message, true) }
    }))

  box.querySelectorAll('[data-socket]').forEach((btn) =>
    btn.addEventListener('click', async (ev) => {
      ev.stopPropagation()
      btn.disabled = true
      try {
        const got = await api(`/pools/${btn.dataset.socket}/socket`, { method: 'PUT' })
        toast(`answering on port ${got.servingPort}`)
        refresh()
      } catch (err) { btn.disabled = false; toast(err.message, true) }
    }))

  bindGroupDragging(box, pools)
}

/**
 * The fleet by what each machine is offered for.
 *
 * Two panels rather than a list, because the interesting question is which
 * machines are in both - that is the choice with a consequence, and it should
 * be visible without reading a table.
 *
 * Dragging here *adds* rather than moves. A machine dropped on cluster is
 * offered for cluster work as well, and keeps whatever it had. That differs
 * from groups, where a drag moves a machine, so the panels say so rather than
 * leaving somebody to discover it by dropping one.
 */
function renderTiers(box, nodes) {
  const byTier = tierMachines(nodes)

  box.innerHTML = byTier.map(({ tier, nodes: members }) => `
    <section class="panel group" data-tier="${escape(tier)}">
      <div class="panel-head">
        <h2>${escape(tier)}</h2>
        ${tier === 'cluster' && members.some(inBothTiers)
          ? `<span class="triangle warn" title="${escape(
              'These machines belong to people. An interactive request can land on one '
              + 'while its owner is using it.')}">&#9650;</span>
             <span class="hint warn">${members.filter(inBothTiers).length} also harvest</span>`
          : ''}
        <span class="hint">${escape(describeTier(tier))}</span>
      </div>
      ${members.length === 0
        ? '<p class="empty">Nothing offered for this. Drag a machine in to add it.</p>'
        : `<div class="chips">${members.map((n) => `
            <div class="machine-chip" draggable="true" data-node="${escape(n.id)}"
                 data-from="${escape(tier)}">
              <b>${escape(n.hostname)}</b>
              <span>${escape(n.chip ?? '')} &middot; ${fmt(n.memoryGb ?? n.memory_gb)} GB${
                inBothTiers(n) ? ' &middot; both' : ''}</span>
              <button class="link remove" data-remove="${escape(n.id)}"
                data-tier="${escape(tier)}"
                title="Stop offering this machine for ${escape(tier)} work">&times;</button>
            </div>`).join('')}</div>`}
    </section>`).join('')
    + `<p class="hint" style="grid-column:1/-1">Dragging a machine onto a tier adds it.
       A machine can be offered for both, and keeps what it already had.</p>`

  bindTierDragging(box, nodes)
}

function bindTierDragging(box, nodes) {
  const nodeById = (id) => nodes.find((n) => n.id === id)

  const apply = async (node, tier, action) => {
    const next = tiersAfter(node, tier, action)
    if (!next) {
      // The refusal worth explaining. A machine offered for nothing still runs,
      // still heartbeats and never gets work, which looks like a broken agent.
      toast(action === 'remove'
        ? `${node.hostname} has to be offered for something`
        : `${node.hostname} is already there`)
      return
    }
    await api(`/nodes/${node.id}/tiers`,
      { method: 'PUT', body: JSON.stringify({ tiers: next }) })
    toast(`${node.hostname}: ${next.join(' and ')}`)
    refresh()
  }

  let dragging = null
  for (const chip of box.querySelectorAll('.machine-chip')) {
    chip.addEventListener('dragstart', (e) => {
      dragging = chip.dataset.node
      e.dataTransfer.effectAllowed = 'copy'
      e.dataTransfer.setData('text/plain', chip.dataset.node)
      chip.classList.add('lifting')
    })
    chip.addEventListener('dragend', () => {
      chip.classList.remove('lifting')
      dragging = null
    })
  }

  for (const panel of box.querySelectorAll('section[data-tier]')) {
    panel.addEventListener('dragover', (e) => { e.preventDefault(); panel.classList.add('over') })
    panel.addEventListener('dragleave', () => panel.classList.remove('over'))
    panel.addEventListener('drop', async (e) => {
      e.preventDefault()
      panel.classList.remove('over')
      const node = nodeById(dragging ?? e.dataTransfer.getData('text/plain'))
      if (node) await apply(node, panel.dataset.tier, 'add')
    })
  }

  for (const button of box.querySelectorAll('[data-remove]')) {
    button.addEventListener('click', async (e) => {
      e.stopPropagation()
      const node = nodeById(button.dataset.remove)
      if (node) await apply(node, button.dataset.tier, 'remove')
    })
  }
}

function bindGroupDragging(box, pools) {
  let dragging = null

  for (const chip of box.querySelectorAll('.machine-chip')) {
    chip.addEventListener('dragstart', (e) => {
      dragging = { nodeId: chip.dataset.node, from: chip.dataset.from || null }
      e.dataTransfer.effectAllowed = 'move'
      // Set, because Firefox will not start a drag without it, even though
      // nothing here reads it back.
      e.dataTransfer.setData('text/plain', chip.dataset.node)
      chip.classList.add('lifting')
    })
    chip.addEventListener('dragend', () => {
      chip.classList.remove('lifting')
      dragging = null
    })
  }

  for (const target of box.querySelectorAll('[data-drop]')) {
    target.addEventListener('dragover', (e) => {
      if (!dragging || dragging.from === target.dataset.drop) return
      e.preventDefault()
      target.classList.add('over')
    })
    target.addEventListener('dragleave', () => target.classList.remove('over'))
    target.addEventListener('drop', async (e) => {
      e.preventDefault()
      target.classList.remove('over')
      if (!dragging) return
      const { nodeId, from } = dragging
      const to = target.dataset.drop
      if (from === to) return
      await moveMachine(nodeId, from, to, pools)
    })
  }

  for (const btn of box.querySelectorAll('[data-remove]')) {
    btn.addEventListener('click', async (e) => {
      e.stopPropagation()
      try {
        await api(`/pools/${btn.dataset.pool}/nodes/${btn.dataset.remove}`, { method: 'DELETE' })
        toast('taken out of the group')
        refresh()
      } catch (err) { toast(err.message, true) }
    })
  }
}

/**
 * Move a machine between groups.
 *
 * The add happens before the remove, so a failure leaves the machine in both
 * rather than in neither: a machine in two groups is untidy, and a machine in
 * none silently stops being scheduled.
 */
async function moveMachine(nodeId, from, to, pools) {
  try {
    await api(`/pools/${to}/nodes/${nodeId}`, { method: 'PUT', body: '{}' })
  } catch (err) {
    // The server refuses the first hand-picked machine in a rule-based group
    // and says what converting it would drop. Asking is the whole point.
    const target = pools.find((p) => p.id === to)
    if (/currently matches/.test(err.message)) {
      if (!confirm(`${err.message}\n\nConvert "${target?.name ?? to}" into a list?`)) return
      try {
        await api(`/pools/${to}/nodes/${nodeId}`,
          { method: 'PUT', body: JSON.stringify({ confirm: true }) })
      } catch (e2) { toast(e2.message, true); return }
    } else {
      toast(err.message, true)
      return
    }
  }
  if (from) {
    try {
      await api(`/pools/${from}/nodes/${nodeId}`, { method: 'DELETE' })
    } catch (err) { toast(`added, but could not remove from the old group: ${err.message}`, true) }
  }
  toast('moved')
  refresh()
}

async function createGroup() {
  const name = prompt('Name for the new group')
  if (!name || !name.trim()) return
  try {
    const made = await api('/pools',
                           { method: 'POST', body: JSON.stringify({ name: name.trim() }) })
    // The port, at the moment of creation, because that is when somebody is
    // about to go and use it. Told rather than left to be found: the socket is
    // how an application addresses this group and nothing else in a request
    // names it.
    toast(made.servingPort
      ? `created ${name.trim()}, answering on port ${made.servingPort}`
      : `created ${name.trim()}`)
    refresh()
  } catch (err) { toast(err.message, true) }
}

/* -------------------------------------------------------------- deployment */

/**
 * Deployment fetches on its own, like the log view.
 *
 * It is read while something is happening - a rollout, a rollback - so it wants
 * its own cadence, and it is the one page where a stale answer is actively
 * misleading.
 */
async function loadDeployment(pools) {
  try {
    const [rollout, builds, upgrades] = await Promise.all([
      api('/agent/rollout'), api('/agent/builds'), api('/agent/upgrades'),
    ])

    const body = document.querySelector('#rollout tbody')
    if (!body) return
    body.innerHTML = rollout.map((r) => {
      const st = rolloutState(r)
      return `<tr>
        <td><b>${escape(r.hostname)}</b></td>
        <td class="mono">${escape(r.running)}</td>
        <td class="mono dim">${r.fingerprint
          ? escape(r.fingerprint.slice(0, 12))
          : '<span class="dim">not reported</span>'}</td>
        <td>${r.channel === 'managed' ? 'this control plane' : 'MDM or by hand'}</td>
        <td><span class="pill ${st.state}">${escape(st.label)}</span></td>
      </tr>`
    }).join('')

    const bbody = document.querySelector('#builds tbody')
    document.querySelector('#builds-empty').hidden = builds.builds.length > 0
    bbody.innerHTML = builds.builds.map((b) => `<tr>
      <td class="mono"><b>${escape(b.version)}</b></td>
      <td class="num">${humanBytes(b.sizeBytes)}</td>
      <td class="mono dim">${escape(b.sha256.slice(0, 12))}</td>
      <td class="num">${b.nodesRunning}</td>
      <td class="dim">${escape(new Date(b.uploadedAt).toLocaleString())}
        ${b.uploadedBy ? `by ${escape(b.uploadedBy)}` : ''}</td>
    </tr>`).join('')

    renderPoolChannels(pools, builds.builds)

    const up = $('#upgrades')
    up.innerHTML = upgrades.length === 0
      ? '<p class="empty">Nothing has been upgraded from here yet.</p>'
      : upgrades.slice(0, 12).map((u) => {
        const o = upgradeOutcome(u)
        return `<div class="upgrade ${o.state}">
          <b>${escape(u.hostname)}</b>
          <span>${escape(o.label)}</span>
          ${u.detail ? `<span class="why">${escape(u.detail)}</span>` : ''}
          <span class="when">${escape(new Date(u.at).toLocaleString())}</span>
        </div>`
      }).join('')
  } catch (err) {
    toast(err.message, true)
  }
}

/**
 * Who owns the binary on each pool.
 *
 * External is the default and stays the default. A system that arrives able to
 * push executables to other people's Macs without anyone opting in is the wrong
 * system, and the switch to managed should be a decision somebody made rather
 * than one they inherited.
 */
function renderPoolChannels(pools, builds) {
  const box = $('#pool-channels')
  if (!box) return
  box.innerHTML = pools.map((p) => `
    <div class="channel" data-pool="${escape(p.id)}">
      <div>
        <b>${escape(p.name)}</b>
        <span class="dim">${escape(p.tier)} tier</span>
      </div>
      <select data-channel="${escape(p.id)}">
        <option value="external">MDM or by hand</option>
        <option value="managed">this control plane</option>
      </select>
      <select data-version="${escape(p.id)}">
        <option value="">no version chosen</option>
        ${builds.map((b) => `<option value="${escape(b.version)}">${escape(b.version)}</option>`).join('')}
      </select>
    </div>`).join('')

  for (const p of pools) {
    const channel = box.querySelector(`[data-channel="${p.id}"]`)
    const version = box.querySelector(`[data-version="${p.id}"]`)
    channel.value = p.agentChannel ?? 'external'
    version.value = p.desiredAgentVersion ?? ''
    const save = async () => {
      try {
        await api(`/pools/${p.id}/agent`, {
          method: 'PUT',
          body: JSON.stringify({ channel: channel.value, version: version.value || null }),
        })
        toast(channel.value === 'managed'
          ? 'machines in this pool will upgrade themselves, and roll back if the new build does not report in'
          : 'this control plane will report drift and change nothing')
        loadDeployment(pools)
      } catch (err) { toast(err.message, true) }
    }
    channel.addEventListener('change', save)
    version.addEventListener('change', save)
  }
}

/* -------------------------------------------------------------------- logs */

/**
 * The log view fetches on its own rather than riding the fleet poll.
 *
 * Its query is a question somebody asked, and re-running it every five seconds
 * would move rows under the cursor of the person reading them. It refreshes
 * when the query changes and when they ask for it, which is what a log reader
 * expects.
 */
const logState = { q: '', since: '86400', source: '' }

function logQuery(extra = {}) {
  const p = new URLSearchParams()
  if (logState.q.trim()) p.set('q', logState.q.trim())
  if (logState.source) p.set('source', logState.source)
  if (logState.since) {
    p.set('since', new Date(Date.now() - Number(logState.since) * 1000).toISOString())
  }
  for (const [k, v] of Object.entries(extra)) p.set(k, v)
  return p.toString()
}

async function loadLogs() {
  const body = document.querySelector('#logs tbody')
  if (!body) return
  try {
    const rows = await api(`/logs?${logQuery({ limit: '500' })}`)
    document.querySelector('#logs-empty').hidden = rows.length > 0
    body.innerHTML = rows.map((r) => `<tr>
      <td class="at">${escape(new Date(r.at).toLocaleString())}</td>
      <td${r.source === 'fleet' ? ' class="fleet-actor"' : ''}>${
        escape(r.source === 'node' ? (r.node ?? 'unknown') : (r.actor ?? 'fleet'))}</td>
      <td>${escape(r.event)}</td>
      <td class="detail">${escape(JSON.stringify(r.detail))}</td>
    </tr>`).join('')
  } catch (err) {
    toast(err.message, true)
  }
}

/**
 * Export by fetching and saving, not by navigating.
 *
 * Navigating would mean putting the session token in the URL, where it would
 * land in browser history, the referrer of anything the page opens, and any
 * proxy log in between. A credential in a query string is a credential you have
 * published. Fetching with the header and handing the browser a blob keeps it
 * where it belongs.
 */
async function exportLogs(format) {
  try {
    const res = await fetch(`/admin/v1/logs?${logQuery({ format })}`, {
      headers: { authorization: `Bearer ${session.get()}` },
    })
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
    const blob = await res.blob()
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `dai-log-${new Date().toISOString()}.${format === 'html' ? 'html' : 'txt'}`
    a.click()
    // Revoked, or every export leaks its contents into memory for the life of
    // the tab, and these are the largest documents this page produces.
    URL.revokeObjectURL(url)
    toast(`exported as ${format}`)
  } catch (err) {
    toast(err.message, true)
  }
}

function bindLogControls() {
  const q = $('#log-q')
  if (!q) return
  q.value = logState.q
  $('#log-since').value = logState.since
  $('#log-source').value = logState.source

  let typing
  q.addEventListener('input', () => {
    logState.q = q.value
    clearTimeout(typing)
    // Debounced, because each keystroke is a query across two tables and a
    // search that fires per character makes the database do the typing.
    typing = setTimeout(loadLogs, 250)
  })
  $('#log-since').addEventListener('change', (e) => {
    logState.since = e.target.value
    loadLogs()
  })
  $('#log-source').addEventListener('change', (e) => {
    logState.source = e.target.value
    loadLogs()
  })
  $('#log-text').addEventListener('click', () => exportLogs('text'))
  $('#log-html').addEventListener('click', () => exportLogs('html'))
  loadLogs()
}

let lastNodes = []
let lastData = null

/* ------------------------------------------------------------------ tables */

/**
 * Search and sort, per table, held here rather than in the DOM.
 *
 * Kept outside the render because the tables are rebuilt on a poll: state
 * living in the markup would be reset every five seconds, which is worse than
 * having none at all. It is deliberately not persisted - a filter somebody
 * cannot see the origin of is how a fleet appears to have lost half its
 * machines.
 */
const tables = {
  nodes: { query: '', sort: null },
  models: { query: '', sort: null },
  jobs: { query: '', sort: null },
}

const NODE_COLUMNS = {
  hostname: (n) => n.hostname,
  chip: (n) => n.chip,
  working: (n) => n.metalWorkingSetGb,
  presence: (n) => n.presenceState,
  state: (n) => n.state,
}
const NODE_FIELDS = ['hostname', 'chip', 'presenceState', 'state',
  (n) => (n.models ?? []).join(' ')]

const MODEL_COLUMNS = {
  id: (m) => m.id,
  runtime: (m) => m.runtime,
  size: (m) => m.sizeBytes,
  context: (m) => m.contextLength,
  holding: (m) => m.nodesHolding,
}
const MODEL_FIELDS = ['id', 'runtime', 'kind', 'family']

const JOB_COLUMNS = {
  label: (j) => j.label ?? j.id,
  kind: (j) => j.kind,
  source: (j) => j.source,
  state: (j) => j.state,
}
const JOB_FIELDS = ['label', 'kind', 'source', 'state', 'submittedBy']

/** Filter then sort, which is the order a reader expects of the two. */
function arrange(rows, key, columns, fields) {
  const t = tables[key]
  const found = rows.filter((r) => matchesQuery(r, t.query, fields))
  return t.sort ? sortRows(found, t.sort.key, t.sort.dir, columns) : found
}

/** A search box bound to one table. */
function searchBox(key, placeholder) {
  return `<input class="search" data-search="${key}" type="search"
    placeholder="${placeholder}" spellcheck="false">`
}

/**
 * Make the headers sortable and the search box live.
 *
 * Re-bound after every mount because the markup is replaced wholesale. The
 * search input's value is restored from state for the same reason: it would
 * otherwise clear itself under the reader's cursor on the next poll.
 */
function bindTableControls(key, onChange) {
  const input = document.querySelector(`[data-search="${key}"]`)
  if (input) {
    input.value = tables[key].query
    input.addEventListener('input', () => {
      tables[key].query = input.value
      onChange()
    })
  }
  for (const th of document.querySelectorAll(`#${key} th[data-sort]`)) {
    const col = th.dataset.sort
    const active = tables[key].sort
    th.classList.add('sortable')
    if (active?.key === col) th.classList.add(active.dir === 'asc' ? 'asc' : 'desc')
    th.addEventListener('click', () => {
      tables[key].sort = nextSort(tables[key].sort, col)
      onChange()
    })
  }
}

/* ------------------------------------------------------------------- views */

/**
 * Four views rather than five panels on one scroll.
 *
 * The old page put capacity, machines, models, queues and work at equal weight
 * and left the reader to work out whether anything was wrong. That is the wrong
 * division of labour: the control plane already knows what is out of place, and
 * a person was re-deriving it by eye every time they looked.
 *
 * Markup lives here rather than in the document because only one view is
 * mounted at a time. A hidden table still costs a render and, more to the
 * point, its stale contents are one CSS mistake away from being visible.
 */
const VIEWS = {
  overview: () => `
    <header class="view-head">
      <h1>Overview</h1>
      <p class="note">What needs attention, and the capacity behind it.</p>
    </header>
    <section class="panel attention"><div id="attention"></div></section>
    <section class="panel">
      <div class="panel-head"><h2>Eligible capacity</h2></div>
      <p class="note">
        GPU work runs only when a machine is locked or logged out. ANE work runs
        whatever its owner is doing, so the band beneath the curve is the
        capacity that exists during the working day.
      </p>
      <div class="stats" id="stats"></div>
      <div class="chart-wrap">
        <svg id="chart" viewBox="0 0 900 220" preserveAspectRatio="none"></svg>
      </div>
      <div class="legend">
        <span><i class="swatch gpu"></i>GPU (locked or absent)</span>
        <span><i class="swatch ane"></i>ANE (any state)</span>
        <span class="right" id="window-label"></span>
      </div>
      <p class="note drag-hint">Drag the chart sideways to change the span,
        from ten minutes to three days.</p>
    </section>
    <section class="panel">
      <div class="panel-head"><h2>Queues</h2></div>
      <div id="queues" class="queues"></div>
    </section>`,

  machines: () => `
    <header class="view-head">
      <h1>Machines</h1>
      <p class="note">
        Working set is what Metal will allow, headroom is what policy permits
        right now, and yields are the early warning that a policy is too
        aggressive for a particular machine.
      </p>
      ${searchBox('nodes', 'Search machines')}
      <div class="axis" id="axis">
        <button data-axis="groups" class="on">Groups</button>
        <button data-axis="tiers">Tiers</button>
      </div>
      <button id="new-group" class="primary">New group</button>
    </header>
    <div id="groups"></div>
    <section class="panel">
      <div class="panel-head"><h2>All machines</h2></div>
      <div class="table-wrap">
        <table id="nodes">
          <thead><tr>
            <th data-sort="hostname">Machine</th><th data-sort="chip">Chip</th>
            <th class="num" data-sort="working"
                title="Metal caps itself near 81% of unified memory">Working set</th>
            <th class="num" title="What is takeable right now under policy">Headroom</th>
            <th data-sort="presence">Presence</th><th>Permits</th>
            <th title="What this machine can answer with, and whether it could answer now">Serving</th>
            <th class="num" title="How often this node interrupted work in the last week">Yields 7d</th>
            <th data-sort="state">State</th><th></th>
          </tr></thead>
          <tbody></tbody>
        </table>
      </div>
      <p class="empty" id="nodes-empty" hidden>No machines yet. Enrol one, then approve it.</p>
      <p class="empty" id="nodes-none" hidden>Nothing matches that search.</p>
    </section>`,

  models: () => `
    <header class="view-head">
      <h1>Models</h1>
      <p class="note">What the fleet is supposed to hold, against what it does.</p>
      ${searchBox('models', 'Search models')}
      <button id="add-model" class="primary">Add model</button>
    </header>
    <div id="imports"></div>
    <section class="panel">
      <div class="table-wrap">
        <table id="models">
          <thead><tr>
            <th data-sort="id">Model</th><th data-sort="runtime">Runtime</th>
            <th class="num" data-sort="size">Size</th>
            <th class="num" data-sort="context"
                title="Advertised by the weights. Testing has shown this to be optimistic.">Context</th>
            <th title="Pools declared to hold it. Nodes reconcile toward this on their own schedule.">Pushed to</th>
            <th data-sort="holding"
                title="On disk, not loaded in memory. A healthy idle machine holds models and has none loaded.">Distribution</th>
            <th></th>
          </tr></thead>
          <tbody></tbody>
        </table>
        <p id="models-empty" class="empty">
          No models yet. Add one: models already on this machine import without
          downloading anything.
        </p>
      </div>
    </section>`,

  deploy: () => `
    <header class="view-head">
      <h1>Deployment</h1>
      <p class="note">
        What every machine is running, and who is allowed to change it. A pool
        set to <b>managed</b> is updated from here; <b>external</b> means an MDM
        or a person owns the binary and this page only reports what it sees.
      </p>
    </header>
    <section class="panel">
      <div class="panel-head"><h2>Machines</h2></div>
      <div class="table-wrap">
        <table id="rollout">
          <thead><tr>
            <th>Machine</th><th>Running</th><th>Fingerprint</th>
            <th>Owned by</th><th>State</th>
          </tr></thead>
          <tbody></tbody>
        </table>
      </div>
    </section>
    <section class="panel">
      <div class="panel-head">
        <h2>Pools</h2>
        <span class="hint">who deploys, and which version they should be on</span>
      </div>
      <div id="pool-channels"></div>
    </section>
    <section class="panel">
      <div class="panel-head">
        <h2>Builds</h2>
        <span class="hint">registered on the control plane, verified by hash</span>
      </div>
      <div class="table-wrap">
        <table id="builds">
          <thead><tr>
            <th>Version</th><th class="num">Size</th><th>Hash</th>
            <th class="num">Machines</th><th>Registered</th>
          </tr></thead>
          <tbody></tbody>
        </table>
        <p id="builds-empty" class="empty" hidden>
          No builds registered. Register one with
          <code>POST /admin/v1/agent/builds</code>.
        </p>
      </div>
    </section>
    <section class="panel">
      <div class="panel-head">
        <h2>Recent upgrades</h2>
        <span class="hint">including rollbacks a machine decided on its own</span>
      </div>
      <div id="upgrades"></div>
    </section>`,

  logs: () => `
    <header class="view-head">
      <h1>Logs</h1>
      <p class="note">
        What each machine has been doing, and who told the fleet to do
        something, read as one sequence. A push and the fetches it caused are
        one story.
      </p>
    </header>
    <section class="panel">
      <div class="log-controls">
        <input class="search" id="log-q" type="search"
               placeholder="Search machines, people, events, payloads" spellcheck="false">
        <select id="log-since">
          <option value="600">last 10 minutes</option>
          <option value="3600">last hour</option>
          <option value="86400" selected>last 24 hours</option>
          <option value="604800">last 7 days</option>
          <option value="">everything</option>
        </select>
        <select id="log-source">
          <option value="">both logs</option>
          <option value="node">machines only</option>
          <option value="fleet">fleet actions only</option>
        </select>
        <span class="spacer"></span>
        <button id="log-text">Export text</button>
        <button id="log-html">Export HTML</button>
      </div>
      <div class="table-wrap">
        <table id="logs">
          <thead><tr>
            <th>Time</th><th>Where</th><th>Event</th><th>Detail</th>
          </tr></thead>
          <tbody></tbody>
        </table>
        <p id="logs-empty" class="empty" hidden>Nothing matches.</p>
      </div>
    </section>`,

  work: () => `
    <header class="view-head">
      <h1>Work</h1>
      <p class="note">
        Work generated by a harness is marked as such. Unmarked, its throughput
        reads as the studio's real activity.
      </p>
      ${searchBox('jobs', 'Search work')}
    </header>
    <section class="panel">
      <div class="table-wrap">
        <table id="jobs">
          <thead><tr>
            <th data-sort="label">What</th><th data-sort="kind">Kind</th>
            <th data-sort="source"
                title="Claimed by whoever submitted it. Synthetic work must say so.">Source</th>
            <th>Submitted by</th><th class="num">Progress</th>
            <th data-sort="state">State</th>
          </tr></thead>
          <tbody></tbody>
        </table>
        <p id="jobs-empty" class="empty">Nothing has been submitted yet.</p>
      </div>
    </section>`,
}

/* ------------------------------------------------------------- api explorer */

/**
 * The contract, made usable.
 *
 * The console already linked to a rendered copy of the OpenAPI document, which
 * is good for reading and no help at all in answering "what does this actually
 * return on my fleet". Answering that meant leaving the console, finding a
 * token and writing a curl line, so in practice nobody did and the API stayed a
 * document rather than a tool.
 *
 * Two decisions worth stating.
 *
 * It sends with the session you are already signed in with. There is no box to
 * paste a token into, because a console that asks people to handle raw
 * credentials teaches them to keep credentials lying around.
 *
 * Anything that is not a GET asks twice. An explorer is a thing people click on
 * to find out what an endpoint does, and the endpoint they are most curious
 * about is the one that revokes a machine. The second click names the method
 * and the path so what is about to happen is on screen when it is confirmed.
 */
let apiSpec = null
let apiOperations = []
const apiExpanded = new Set()

async function loadApi() {
  if (!apiSpec) {
    const res = await fetch('/openapi.json', { headers: { accept: 'application/json' } })
    if (!res.ok) {
      $('#api-list').innerHTML =
        `<p class="empty">Could not read the contract (${res.status}).</p>`
      return
    }
    apiSpec = await res.json()
    apiOperations = operationsFrom(apiSpec)
  }
  renderApi()
}

function renderApi() {
  const list = $('#api-list')
  if (!list) return
  const query = $('#api-search')?.value ?? ''
  const shown = apiOperations.filter((op) => matchesOperation(op, query))
  const groups = groupOperations(shown)

  $('#api-count').textContent =
    `${shown.length} of ${apiOperations.length}`
  $('#api-empty').hidden = shown.length > 0

  list.innerHTML = groups.map((g) => `
    <div class="api-group">
      <h3>${escape(g.tag)} <span class="count">${g.operations.length}</span></h3>
      ${g.operations.map(renderOperation).join('')}
    </div>`).join('')

  for (const el of list.querySelectorAll('.api-op')) bindOperation(el)
}

function bindOperation(el) {
  if (!el) return
  const head = el.querySelector('.api-op-head')
  if (head) head.addEventListener('click', () => toggleOperation(head.dataset.op))
  const send = el.querySelector('[data-send]')
  if (send) send.addEventListener('click', () => sendOperation(send.dataset.send))
}

/**
 * One endpoint, collapsed to a line.
 *
 * A method, a path and a summary is what somebody scanning for an endpoint
 * reads; everything else is what they need once they have found it, and putting
 * it all on screen at once made a page nobody could scan.
 */
function renderOperation(op) {
  const open = apiExpanded.has(op.id)
  const callable = callableHere(op)
  return `
    <div class="api-op${open ? ' open' : ''}" id="op-${escape(cssId(op.id))}">
      <button class="api-op-head" data-op="${escape(op.id)}"
              aria-expanded="${open}">
        <span class="chev">${open ? '&#9662;' : '&#9656;'}</span>
        <span class="method m-${escape(op.method.toLowerCase())}">${escape(op.method)}</span>
        <code class="api-path">${escape(op.path)}</code>
        <span class="api-summary">${escape(op.summary)}</span>
      </button>
      ${open ? renderOperationBody(op, callable) : ''}
    </div>`
}

function renderOperationBody(op, callable) {
  const body = op.requestBody
    ? JSON.stringify(bodySkeleton(apiSpec, op.requestBody), null, 2) : ''
  const params = op.params.filter((p) => p.in === 'path' || p.in === 'query')

  return `
    <div class="api-op-body">
      ${op.description ? `<p class="api-desc">${escape(op.description).replace(/\n\n/g, '<br><br>')}</p>` : ''}
      ${params.length ? `
        <div class="api-params">
          ${params.map((p) => `
            <label>
              <span>${escape(p.name)}
                <em>${escape(p.in)}${p.required ? ', required' : ''}</em></span>
              <input data-param="${escape(op.id)}|${escape(p.name)}"
                     placeholder="${escape(p.description.split('\n')[0].slice(0, 60))}">
            </label>`).join('')}
        </div>` : ''}
      ${op.requestBody ? `
        <label class="api-body-label">
          <span>Request body <em>json</em></span>
          <textarea data-body="${escape(op.id)}" spellcheck="false"
                    rows="${Math.min(18, body.split('\n').length + 1)}">${escape(body)}</textarea>
        </label>` : ''}
      <div class="api-actions">
        ${callable
          ? `<button class="primary" data-send="${escape(op.id)}">
               Send ${escape(op.method)}</button>`
          : `<span class="note api-blocked">Cannot be sent from here:
               ${escape(whyNotCallable(op))}</span>`}
        <span class="note">Responds ${escape(op.responses.join(', ') || 'unspecified')}</span>
      </div>
      <div class="api-response" data-response="${escape(op.id)}" hidden></div>
    </div>`
}

/** An id that is safe in a CSS selector and stable per operation. */
function cssId(id) { return id.replace(/[^A-Za-z0-9]/g, '-') }

/**
 * Open or close one endpoint, replacing only that row.
 *
 * Redrawing the whole list would be simpler and is what this did first, and it
 * threw away the scroll position every time: clicking an endpoint near the
 * bottom jumped the page somewhere else, which reads as the click having done
 * something other than what it did. It also discarded any request body the
 * reader had already typed into another open endpoint.
 */
function toggleOperation(id) {
  const op = apiOperations.find((o) => o.id === id)
  if (apiExpanded.has(id)) apiExpanded.delete(id)
  else apiExpanded.add(id)

  const el = document.getElementById(`op-${cssId(id)}`)
  if (!op || !el) { renderApi(); return }
  el.outerHTML = renderOperation(op)
  bindOperation(document.getElementById(`op-${cssId(id)}`))
}

/**
 * Send it, and show exactly what came back.
 *
 * Status, timing and body, including the failures. An explorer that only
 * rendered successes would hide the half of the contract people come here to
 * understand: what a 403 says, and whether a 404 means "no such node" or "no
 * such route".
 */
async function sendOperation(id) {
  const op = apiOperations.find((o) => o.id === id)
  const box = document.querySelector(`[data-response="${CSS.escape(id)}"]`)
  const button = document.querySelector(`[data-send="${CSS.escape(id)}"]`)
  if (!op || !box || !button) return

  const values = {}
  for (const input of document.querySelectorAll(`[data-param^="${CSS.escape(id)}|"]`)) {
    values[input.dataset.param.split('|')[1]] = input.value
  }
  const built = buildUrl(op, values)
  if (built.error) {
    showApiResponse(box, { note: built.error, tone: 'warn' })
    return
  }

  let payload
  const textarea = document.querySelector(`[data-body="${CSS.escape(id)}"]`)
  if (textarea && textarea.value.trim()) {
    try {
      payload = JSON.parse(textarea.value)
    } catch (err) {
      // Caught here rather than sent, so a typo comes back as a typo instead of
      // a 400 that reads like the endpoint rejected a correct request.
      showApiResponse(box, { note: `Request body is not valid JSON: ${err.message}`,
                             tone: 'warn' })
      return
    }
  }

  // The second click, for anything that can change something.
  if (!isReadOnly(op) && button.dataset.armed !== 'yes') {
    button.dataset.armed = 'yes'
    button.classList.add('arm')
    button.textContent = `Confirm ${op.method} ${op.path}`
    showApiResponse(box, {
      note: 'This changes something on the fleet. Click again to send it.',
      tone: 'warn',
    })
    return
  }

  button.disabled = true
  const started = performance.now()
  try {
    const res = await fetch(built.url, {
      method: op.method,
      headers: {
        authorization: `Bearer ${session.get()}`,
        ...(payload === undefined ? {} : { 'content-type': 'application/json' }),
      },
      ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
    })
    const text = await res.text()
    showApiResponse(box, {
      status: res.status,
      statusText: res.statusText,
      ms: Math.round(performance.now() - started),
      contentType: res.headers.get('content-type') ?? '',
      body: text,
    })
  } catch (err) {
    showApiResponse(box, { note: `Request failed: ${err.message}`, tone: 'bad' })
  } finally {
    button.disabled = false
    button.dataset.armed = ''
    button.classList.remove('arm')
    button.textContent = `Send ${op.method}`
  }
}

function showApiResponse(box, r) {
  box.hidden = false
  if (r.note) {
    box.innerHTML = `<p class="api-note ${escape(r.tone ?? 'flat')}">${escape(r.note)}</p>`
    return
  }
  const tone = statusTone(r.status)
  const formatted = formatResponse(r.body, r.contentType)
  box.innerHTML = `
    <div class="api-status">
      <span class="pill ${escape(tone)}">${r.status} ${escape(r.statusText ?? '')}</span>
      <span class="note">${r.ms} ms${r.body ? `, ${responseSize(r.body.length)}` : ''}</span>
    </div>
    ${formatted ? `<pre class="api-out">${escape(formatted)}</pre>`
                : '<p class="api-note flat">No body.</p>'}`
}

VIEWS.api = () => `
  <header class="view-head">
    <h1>API</h1>
    <p class="note">
      Every endpoint this control plane serves, and a way to call it with the
      session you are already signed in with.
    </p>
  </header>
  <section class="panel">
    <div class="panel-head">
      <h2>Endpoints</h2>
      <div class="controls">
        <input id="api-search" class="search" type="search"
               placeholder="Filter by path, method or summary" autocomplete="off">
        <span class="note" id="api-count"></span>
      </div>
    </div>
    <div id="api-list" class="api-list"></div>
    <p class="empty" id="api-empty" hidden>Nothing matches that filter.</p>
  </section>`

const currentView = () => {
  // The query is stripped before the name is read. The machines page carries
  // `?by=tiers` so a link to the fleet-by-tier is something somebody can send,
  // and without this that link resolved to no view at all and fell back to the
  // overview.
  const name = location.hash.replace(/^#\/?/, '').split('?')[0] || 'overview'
  return VIEWS[name] ? name : 'overview'
}

/**
 * Mount a view.
 *
 * The signature caches inside the render functions are per-table and would go
 * stale against a freshly mounted, empty table, so they are cleared here. That
 * is the whole cost of keeping them, and they exist because replacing a table
 * on every poll destroys hover state and swallows clicks that land mid-refresh.
 */
function mount(name) {
  $('#view').innerHTML = VIEWS[name]()
  lastNodeSignature = null
  lastJobSignature = ''
  lastModelSignature = ''
  for (const a of document.querySelectorAll('.views a')) {
    a.classList.toggle('on', a.dataset.view === name)
  }
  if (name === 'models') {
    $('#add-model').addEventListener('click', () => showAddModel(lastNodes))
  }
  if (name === 'machines') {
    $('#new-group').addEventListener('click', createGroup)
    for (const b of document.querySelectorAll('#axis button')) {
      b.addEventListener('click', () => {
        location.hash = b.dataset.axis === 'tiers' ? '#/machines?by=tiers' : '#/machines'
      })
    }
  }
  if (name === 'overview') bindChartDrag()
  if (name === 'logs') bindLogControls()
  if (name === 'api') {
    $('#api-search').addEventListener('input', renderApi)
    loadApi()
  }
  if (name === 'deploy') loadDeployment(lastData?.pools ?? [])
  if (lastData) paint(lastData)
}

/**
 * Whatever needs saying, above everything else.
 *
 * Levelled rather than listed: a decision waiting on a human blocks everything
 * behind it, a machine paused by its owner is not a fault at all, and an empty
 * list reads as a broken page unless it says so out loud.
 */
function renderAttention(items) {
  const box = $('#attention')
  if (!box) return
  box.innerHTML = items.map((i) => `
    <div class="att ${i.level}"${i.view ? ` data-goto="${escape(i.view)}"` : ''}>
      <span class="mark"></span>
      <div>
        <b>${escape(i.text)}</b>
        ${i.detail ? `<span>${escape(i.detail)}</span>` : ''}
      </div>
    </div>`).join('')
  for (const el2 of box.querySelectorAll('[data-goto]')) {
    el2.addEventListener('click', () => { location.hash = `#/${el2.dataset.goto}` })
  }
}

async function refresh() {
  if (!session.get()) return
  try {
    const [summary, nodes, jobs, models, pools] = await Promise.all([
      api(`/fleet/summary?window=${capacityWindow}`), api('/nodes'), api('/jobs'),
      api('/models'), api('/pools'),
    ])
    // Separate, and tolerated failing: an older control plane has no such
    // endpoint and the rest of the page should not go blank over it.
    const imports = await api('/models/imports').catch(() => [])

    // Detail carries headroom and yields, which the list endpoint does not.
    // Fine at fleet sizes where a person is looking at a table; beyond that it
    // wants a summary endpoint rather than a request per machine.
    const details = new Map()
    await Promise.all(nodes.map(async (n) => {
      try { details.set(n.id, await api(`/nodes/${n.id}/detail`)) } catch { /* skip */ }
    }))

    const fresh = withFreshness(nodes)
    lastNodes = fresh
    lastData = { summary, nodes: fresh, jobs, models, pools, details, imports }
    $('#conn').textContent = `updated ${new Date().toLocaleTimeString()}`
    $('#nav-machines').textContent = nodes.length || ''
    $('#nav-models').textContent = models.length || ''
    $('#nav-work').textContent = jobs.filter((j) => j.state === 'running').length || ''
    paint(lastData)
  } catch (err) {
    $('#conn').textContent = 'not reachable'
    toast(err.message, true)
  }
}

/** Draw whichever view is mounted, from data already fetched. */
function paint({ summary, nodes, jobs, models, pools, details, imports = [] }) {
  const view = currentView()

  if (view === 'overview') {
    renderAttention(attentionItems({
      nodes, models, jobs,
      pending: summary.pendingNodes ?? 0,
    }))
    $('#stats').innerHTML = `
      <div class="stat"><b>${fmt(summary.gpuCapacityGb)} GB</b><span>GPU eligible now</span></div>
      <div class="stat"><b>${fmt(summary.aneCapacityGb)} GB</b><span>ANE eligible now</span></div>
      <div class="stat"><b>${summary.eligibleForGpu}/${summary.nodes}</b><span>nodes free for GPU</span></div>`
    drawChart(summary.series)

    const queues = new Map()
    for (const q of summary.queues) {
      const k = queues.get(q.kind) ?? {}
      k[q.state] = q.n
      queues.set(q.kind, k)
    }
    $('#queues').innerHTML = queues.size === 0
      ? '<p class="empty">No work submitted.</p>'
      : [...queues].map(([kind, s]) => `
          <div class="queue"><b>${s.pending ?? 0}</b>
          <span>${escape(kind)} pending &middot; ${s.leased ?? 0} leased &middot;
          ${s.done ?? 0} done${s.failed ? ` &middot; ${s.failed} failed` : ''}</span></div>`).join('')
  }

  if (view === 'machines') {
    renderGroups(nodes, pools, models)
    renderNodes(nodes, details)
  }
  if (view === 'models') {
    renderImports(imports)
    renderModels(models, pools)
  }
  if (view === 'work') renderJobs(jobs)
  if (view === 'deploy') loadDeployment(pools)
}

function fmt(v) { return v === null || v === undefined ? '—' : Number(v).toFixed(1) }
function escape(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
}

/**
 * Theme, chosen or inherited.
 *
 * Applied to the document element rather than the body so the page has its
 * colours before first paint, which is the difference between loading and
 * flashing white at somebody reading it at night.
 */
const theme = {
  get: () => localStorage.getItem('dai.theme') ?? 'auto',
  set(v) {
    localStorage.setItem('dai.theme', v)
    this.apply()
  },
  apply() {
    const v = this.get()
    if (v === 'auto') document.documentElement.removeAttribute('data-theme')
    else document.documentElement.setAttribute('data-theme', v)
    for (const b of document.querySelectorAll('#theme button')) {
      b.classList.toggle('on', b.dataset.theme === v)
    }
  },
}
for (const b of document.querySelectorAll('#theme button')) {
  b.addEventListener('click', () => theme.set(b.dataset.theme))
}
theme.apply()

/* The page has to know the drawer is open so it can make room for it rather
   than be covered by it. Watched rather than announced, because every call site
   sets `hidden` directly and one that forgot to also set a class would put the
   bug back. */
new MutationObserver(() => {
  document.body.classList.toggle('drawer-open', !$('#drawer').hidden)
}).observe($('#drawer'), { attributes: true, attributeFilter: ['hidden'] })

$('#login-form').addEventListener('submit', signIn)
$('#change-form').addEventListener('submit', changePassword)
$('#sign-out').addEventListener('click', signOut)
$('#drawer-close').addEventListener('click', () => drawer.close())
document.addEventListener('keydown', (e) => {
  // Escape steps back one level rather than dismissing everything, which is
  // what it means everywhere else a stack of panels exists.
  if (e.key === 'Escape' && !$('#drawer').hidden) drawer.back()
})

window.addEventListener('hashchange', () => mount(currentView()))

mount(currentView())
// Nothing is fetched until there is a credential that works, so a signed-out
// page does not fire a request per panel and fill the screen with failures.
resumeOrAsk().then((ready) => {
  if (ready) refresh()
  setInterval(() => { if (session.get() && $('#gate').hidden) refresh() }, REFRESH_MS)
})
