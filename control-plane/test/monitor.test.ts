import type { Server } from 'node:http'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { appFor, freshDb } from './helpers.js'

/**
 * A monitoring surface with no credential, restricted by address.
 *
 * The trade is deliberate: the alternative is a long-lived secret pasted into a
 * scraper's config, committed to whatever repository that lives in, and never
 * rotated. An address range is the better authenticator for a machine at a known
 * location doing one thing.
 *
 * That only holds if the range is set, so the surface refuses everything when it
 * is not. Nothing here is a secret on its own, but node names, machine counts
 * and which models the fleet holds are a map of the building.
 */
let db: Db
let server: Server
let base: string
const original = process.env.DAI_MONITOR_CIDRS

async function start() {
  db ??= await freshDb()
  server = await new Promise<Server>((r) => {
    const s = appFor(db).listen(0, () => r(s))
  })
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`
}

beforeEach(async () => { db = await freshDb() })
afterEach(async () => {
  await new Promise<void>((r) => server?.close(() => r()))
  if (original === undefined) delete process.env.DAI_MONITOR_CIDRS
  else process.env.DAI_MONITOR_CIDRS = original
})
afterAll(async () => { await db?.end() })

describe('when no address range is configured', () => {
  it('is switched off rather than open', async () => {
    // The failure this prevents: an unauthenticated endpoint that defaults to
    // open publishes a fleet inventory to anyone who can route to it.
    delete process.env.DAI_MONITOR_CIDRS
    await start()
    for (const path of ['/monitor/v1/health', '/monitor/v1/metrics']) {
      const r = await fetch(`${base}${path}`)
      expect(r.status, path).toBe(404)
    }
  })
})

describe('when a range is configured', () => {
  it('answers a permitted address without any credential', async () => {
    process.env.DAI_MONITOR_CIDRS = '127.0.0.1/32'
    await start()
    const r = await fetch(`${base}/monitor/v1/health`)
    expect(r.status).toBe(200)
    expect(await r.text()).toContain('ok')
  })

  it('refuses an address outside the range', async () => {
    process.env.DAI_MONITOR_CIDRS = '10.9.9.0/24'
    await start()
    const r = await fetch(`${base}/monitor/v1/health`)
    expect(r.status).toBe(403)
  })

  it('reports the fleet in a format a scraper already reads', async () => {
    process.env.DAI_MONITOR_CIDRS = '127.0.0.1/32'
    await start()
    await db.query(
      `INSERT INTO nodes (hostname, state, cert_fingerprint, presence_state, last_heartbeat)
       VALUES ('rotorua','active','fp-1','LOCKED', now()),
              ('orca','active','fp-2','ACTIVE', now() - interval '1 hour')`)

    const body = await (await fetch(`${base}/monitor/v1/metrics`)).text()
    expect(body).toContain('# TYPE dai_nodes_total gauge')
    expect(body).toMatch(/dai_nodes_total 2/)
    // Reporting recently, not merely "active" in the database. A node that is
    // active and silent for an hour is not capacity, and a metric that counted
    // it as such would hide an outage.
    expect(body).toMatch(/dai_nodes_reporting 1/)
    expect(body).toMatch(/dai_nodes_by_presence\{presence="LOCKED"\} 1/)
  })

  it('says unhealthy rather than ok when the database is unreachable', async () => {
    // /healthz answers whether the process is up. A process that is up and
    // cannot reach Postgres is serving nobody, and a check that cannot tell
    // those apart pages nobody when it matters.
    process.env.DAI_MONITOR_CIDRS = '127.0.0.1/32'
    await start()
    await db.end()
    const r = await fetch(`${base}/monitor/v1/health`)
    expect(r.status).toBe(503)
    expect(await r.text()).toContain('unhealthy')
    // Rebuilt for the afterEach teardown.
    db = await freshDb()
  })
})
