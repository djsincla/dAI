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

const $ = (sel) => document.querySelector(sel)
const REFRESH_MS = 5000

const session = {
  get: () => localStorage.getItem('dai.session') ?? '',
  set: (v) => localStorage.setItem('dai.session', v),
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
function drawChart(series) {
  const svg = $('#chart')
  svg.replaceChildren()
  const W = 900, H = 220, pad = { l: 46, r: 8, t: 10, b: 20 }

  if (series.length === 0) {
    const t = el('text', { x: W / 2, y: H / 2, 'text-anchor': 'middle', fill: 'var(--muted)',
      'font-size': 13 })
    t.textContent = 'No heartbeats in the last 24 hours'
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
    t.textContent = when.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
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

function renderNodes(nodes, details) {
  // Only rebuild when something actually changed. Replacing the table on every
  // poll destroys hover state and swallows clicks that land mid-refresh, which
  // is exactly what happened the first time this was driven by hand.
  const signature = JSON.stringify(nodes.map((n) => [
    // n.state included so the row redraws when it changes: without it the
    // button kept its old label after a successful pause.
    n.id, n.hostname, n.presenceState, n.state, n.userPaused,
    details.get(n.id)?.headroomGb, details.get(n.id)?.yields7d,
  ]))
  if (signature === lastNodeSignature) return
  lastNodeSignature = signature

  const body = $('#nodes tbody')
  body.replaceChildren()
  $('#nodes-empty').hidden = nodes.length > 0

  for (const n of nodes) {
    const d = details.get(n.id)
    // A machine its owner paused runs nothing, whatever its presence says, so
    // showing it as available capacity would be a lie the fleet view tells
    // about a decision somebody made deliberately.
    const gpu = n.state === 'active' && GPU_STATES.has(n.presenceState) && !n.userPaused
    const tr = document.createElement('tr')
    tr.innerHTML = `
      <td><b>${escape(n.hostname)}</b></td>
      <td>${escape(n.chip ?? '')}</td>
      <td class="num">${fmt(n.metalWorkingSetGb)} GB</td>
      <td class="num">${d ? `${fmt(d.headroomGb)} GB` : '&mdash;'}</td>
      <td><span class="pill ${escape(n.presenceState ?? '')}">${escape(n.presenceState ?? 'unknown')}</span></td>
      <td><span class="kinds">
        ${n.userPaused ? '<span class="kind paused-by-user">paused by owner</span>' : `
        <span class="kind on-ane">embed</span>
        ${gpu ? '<span class="kind on-gpu">generate</span><span class="kind on-gpu">render</span>' : ''}`}
      </span></td>
      <td class="num">${d ? d.yields7d : '&mdash;'}</td>
      <td><span class="pill ${n.state === 'paused' ? 'paused' : ''}">${escape(n.state)}</span></td>
      ${n.userPaused
        // No admin control offered, because there is none. The button would
        // have to either lie or fail, and a disabled control at least says the
        // truth: this is not yours to lift.
        ? '<td><span class="muted" title="Only the person at that machine can resume it">owner paused</span></td>'
        // Reflects the state rather than assuming one. It always said "Pause",
        // so pausing a node left a button that appeared to do nothing and there
        // was no way back: a one-way door dressed as a toggle.
        : `<td><button data-action="${n.state === 'paused' ? 'resume' : 'pause'}"
                      data-node="${n.id}">${n.state === 'paused' ? 'Resume' : 'Pause'}</button></td>`}`
    tr.addEventListener('click', (ev) => {
      if (ev.target.closest('button')) return
      openNode(n.id)
    })
    body.append(tr)
  }

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

async function openNode(id) {
  try {
    const d = await api(`/nodes/${id}/detail`)
    $('#drawer-title').textContent = d.hostname
    $('#drawer-body').innerHTML = `
      <dl class="kv">
        <dt>Chip</dt><dd>${escape(d.chip ?? '')}</dd>
        <dt>Unified memory</dt><dd>${fmt(d.memoryGb)} GB</dd>
        <dt>Metal working set</dt><dd>${fmt(d.metalWorkingSetGb)} GB</dd>
        <dt>Headroom now</dt><dd>${fmt(d.headroomGb)} GB</dd>
        <dt>Presence</dt><dd>${escape(d.presenceState ?? 'unknown')}</dd>
        ${d.userPaused ? `<dt>Owner</dt><dd class="paused-by-user">paused this machine${
          d.userPausedAt ? ` ${new Date(d.userPausedAt).toLocaleString()}` : ''
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
    $('#drawer').hidden = false
  } catch (err) { toast(err.message, true) }
}

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

async function refresh() {
  if (!session.get()) return
  try {
    const [summary, nodes] = await Promise.all([api('/fleet/summary'), api('/nodes')])

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

    // Detail is fetched per node for headroom and yields, which the list
    // endpoint does not carry. Fine at fleet sizes where a person is looking at
    // a table; a summary endpoint would be needed beyond that.
    const details = new Map()
    await Promise.all(nodes.map(async (n) => {
      try { details.set(n.id, await api(`/nodes/${n.id}/detail`)) } catch { /* skip */ }
    }))
    renderNodes(nodes, details)
  } catch (err) {
    toast(err.message, true)
  }
}

function fmt(v) { return v === null || v === undefined ? '—' : Number(v).toFixed(1) }
function escape(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
}

$('#session').value = session.get()
$('#session').addEventListener('change', (e) => { session.set(e.target.value.trim()); refresh() })
$('#drawer-close').addEventListener('click', () => { $('#drawer').hidden = true })
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') $('#drawer').hidden = true
})

refresh()
setInterval(refresh, REFRESH_MS)
