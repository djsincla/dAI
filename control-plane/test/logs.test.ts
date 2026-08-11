import type { Server } from 'node:http'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { type Fixtures, appFor, freshDb, seed } from './helpers.js'
import { asHtml, asText, type LogRow } from '../src/lib/logs.js'

/**
 * Reading the two logs as one.
 *
 * `activity_log` answers "what has this machine been doing" for the person who
 * owns it; `audit_log` answers "who told the fleet to do that" for whoever runs
 * it. Nobody investigating an incident cares which table a line came from: a
 * model push and the fetches it caused are one story, and reading it used to
 * mean opening two things and interleaving them by eye.
 */
let db: Db
let fx: Fixtures
let server: Server
let base: string

beforeEach(async () => {
  db = await freshDb()
  fx = await seed(db)
  server = await new Promise<Server>((resolve) => {
    const s = appFor(db).listen(0, () => resolve(s))
  })
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`

  await db.query(
    `INSERT INTO activity_log (node_id, at, event, detail)
     VALUES ($1, now() - interval '2 hours', 'work.result', '{"unitId":"u-1","requeued":0}'),
            ($1, now() - interval '10 minutes', 'work.yield', '{"reason":"user returned"}')`,
    [fx.nodeId])
  await db.query(
    `INSERT INTO audit_log (user_id, at, action, subject, detail)
     VALUES ($1, now() - interval '1 hour', 'model.push',
             'mlx-community/Qwen2.5-Coder-32B-Instruct-4bit', '{"poolId":"p-1"}')`,
    [fx.operatorId])
})
afterEach(async () => { await new Promise<void>((r) => server.close(() => r())) })
afterAll(async () => { await db?.end() })

const asUser = (id: string) => ({ authorization: `Bearer ${id}` })
const get = (qs = '') =>
  fetch(`${base}/admin/v1/logs${qs}`, { headers: asUser(fx.ownerToken) })

describe('reading both logs together', () => {
  it('interleaves machine activity and fleet actions by time', () => {
    // The whole point. Ordered as one sequence, newest first, whichever table
    // each line came from.
    return get().then(async (r) => {
      const rows = await r.json() as LogRow[]
      expect(rows.map((l) => l.event))
        .toEqual(['work.yield', 'model.push', 'work.result'])
      expect(rows[1]!.source).toBe('fleet')
      expect(rows[1]!.actor).toBe('operator@example.com')
      expect(rows[0]!.node).toBe('rotorua')
    })
  })

  it('searches inside the detail payload, not only the event name', async () => {
    // A unit id or a model name lives in the payload and nowhere else, so a
    // search that only matched event names would never find the thing somebody
    // is actually holding in their hand.
    const rows = await (await get('?q=u-1')).json() as LogRow[]
    expect(rows).toHaveLength(1)
    expect(rows[0]!.event).toBe('work.result')
  })

  it('searches the machine and the person', async () => {
    expect(await (await get('?q=rotorua')).json()).toHaveLength(2)
    // Encoded, because the request validator rejects reserved characters in a
    // query value and an email address is full of them. The same strictness
    // once turned a two-kind lease request into a 400 that nobody saw.
    const email = encodeURIComponent('operator@example.com')
    expect(await (await get(`?q=${email}`)).json()).toHaveLength(1)
  })

  it('filters by time range', async () => {
    const since = new Date(Date.now() - 30 * 60 * 1000).toISOString()
    const rows = await (await get(`?since=${encodeURIComponent(since)}`)).json() as LogRow[]
    expect(rows.map((l) => l.event)).toEqual(['work.yield'])
  })

  it('filters to one source when asked', async () => {
    const rows = await (await get('?source=fleet')).json() as LogRow[]
    expect(rows).toHaveLength(1)
    expect(rows[0]!.source).toBe('fleet')
  })

  it('applies the limit across both logs, not to each', async () => {
    // Limiting each half separately would return the newest N of each rather
    // than the newest N overall, which reads as missing entries exactly when a
    // burst of one kind is what you are chasing.
    const rows = await (await get('?limit=2')).json() as LogRow[]
    expect(rows.map((l) => l.event)).toEqual(['work.yield', 'model.push'])
  })

  it('refuses to be asked for an unbounded number of rows', async () => {
    const r = await get('?limit=999999')
    expect(r.status).toBe(400)
  })
})

describe('exports', () => {
  const rows: LogRow[] = [{
    at: '2026-08-10T12:00:00.000Z', source: 'node', node: 'orca', actor: null,
    event: 'work.result', detail: { unitId: 'u-1' },
  }]

  it('writes text that survives grep and a paste into a ticket', () => {
    const text = asText(rows)
    expect(text).toBe('2026-08-10T12:00:00.000Z\torca\twork.result\t{"unitId":"u-1"}\n')
    // One line per entry, whatever is in the detail.
    expect(text.trimEnd().split('\n')).toHaveLength(1)
  })

  it('writes html that renders with the control plane switched off', () => {
    // An export that only works while the server is up is not an export. This
    // is the artefact somebody attaches to an incident report.
    const html = asHtml(rows, { query: {}, generatedAt: '2026-08-10T12:00:00.000Z' })
    expect(html).not.toMatch(/<link|<script|src=|href=/)
    expect(html).toContain('work.result')
  })

  it('escapes content rather than trusting it', async () => {
    // Event names and payloads come from agents. An export that is opened in a
    // browser must not execute what a node put in a log line.
    const nasty: LogRow[] = [{
      at: '2026-08-10T12:00:00.000Z', source: 'node', node: '<script>alert(1)</script>',
      actor: null, event: 'x', detail: { a: '</td><script>alert(2)</script>' },
    }]
    const html = asHtml(nasty, { query: {}, generatedAt: 'now' })
    expect(html).not.toContain('<script>alert(1)</script>')
    expect(html).not.toContain('<script>alert(2)</script>')
    expect(html).toContain('&lt;script&gt;')
  })

  it('serves text and html as attachments', async () => {
    for (const [format, type] of [['text', 'text/plain'], ['html', 'text/html']]) {
      const r = await get(`?format=${format}`)
      expect(r.headers.get('content-type')).toContain(type!)
      expect(r.headers.get('content-disposition')).toContain('attachment')
    }
  })

  it('says what it was filtered by, so an export explains itself', async () => {
    // A log somebody keeps has to record which question it answered, or it
    // becomes an unlabelled fragment nobody can trust six months later.
    const r = await get('?format=html&q=rotorua')
    const html = await r.text()
    expect(html).toContain('matching "rotorua"')
  })
})
