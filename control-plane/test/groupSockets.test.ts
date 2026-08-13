import type { Server } from 'node:http'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { type Fixtures, appFor, freshDb, seed } from './helpers.js'
import { RecordingListeners } from '../src/lib/groupSockets.js'
import { DEFAULT_RANGE } from '../src/lib/ports.js'

/**
 * A group's own socket, end to end.
 *
 * The point of a port per group is that the address is the whole of the
 * routing: an application pointed at one port asks one set of machines, with
 * nothing in the request to name a group and therefore nothing to name the
 * wrong one. That only holds if two things are true - every group gets a port
 * nobody else has, and a request arriving on it cannot reach a machine outside
 * that group.
 */
let db: Db
let fx: Fixtures
let server: Server
let base: string
let extra: Server | null = null

beforeEach(async () => {
  db = await freshDb()
  fx = await seed(db)
  const app = appFor(db)
  server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, () => resolve(s))
  })
  base = `http://127.0.0.1:${(server.address() as any).port}`
})

afterEach(async () => {
  if (extra) {
    await new Promise<void>((resolve) => extra!.close(() => resolve()))
    extra = null
  }
  await new Promise<void>((resolve) => server.close(() => resolve()))
  delete process.env.DAI_GROUP_PORT_RANGE
  delete process.env.DAI_MONITOR_CIDRS
})
afterAll(async () => { await db?.end() })

const asUser = (id: string) => ({ authorization: `Bearer ${id}`, 'content-type': 'application/json' })

async function createGroup(name: string, tier: 'harvest' | 'cluster' = 'harvest') {
  const r = await fetch(`${base}/admin/v1/pools`, {
    method: 'POST', headers: asUser(fx.ownerToken),
    body: JSON.stringify({ name, tier }),
  })
  return { status: r.status, body: await r.json() as any }
}

describe('the socket a group is created with', () => {
  it('hands the first group the bottom of the range and says so', async () => {
    // Said in the response rather than discovered later. An operator who has
    // just made a group needs to point something at it, and a port they have
    // to go and look up is one they will get wrong.
    const made = await createGroup('first')
    expect(made.status).toBe(201)
    expect(made.body.servingPort).toBe(DEFAULT_RANGE.from)

    const listed = await (await fetch(`${base}/admin/v1/pools`,
                                      { headers: asUser(fx.ownerToken) })).json() as any[]
    expect(listed.find((p) => p.name === 'first').servingPort).toBe(DEFAULT_RANGE.from)
  })

  it('never gives two groups the same one', async () => {
    const a = await createGroup('one')
    const b = await createGroup('two')
    expect(b.body.servingPort).toBe(a.body.servingPort + 1)
    expect(a.body.servingPort).not.toBe(b.body.servingPort)
  })

  it('refuses to create a group it cannot address', async () => {
    // A group with no socket would exist and be unreachable, which is worse
    // than one that was never created: only the second says so.
    process.env.DAI_GROUP_PORT_RANGE = '9100-9100'
    expect((await createGroup('fits')).status).toBe(201)
    const full = await createGroup('does-not-fit')
    expect(full.status).toBe(409)
    expect(full.body.detail).toContain('9100-9100')
    expect(full.body.detail).toContain('1 groups is the limit')
  })

  it('binds the socket at creation rather than at the next restart', async () => {
    // A group whose port only started answering after a restart would look
    // created and refuse connections until somebody noticed.
    const listeners = new RecordingListeners()
    const app = appFor(db, () => listeners)
    const s = await new Promise<Server>((resolve) => {
      const started = app.listen(0, () => resolve(started))
    })
    const at = `http://127.0.0.1:${(s.address() as any).port}`
    const made = await (await fetch(`${at}/admin/v1/pools`, {
      method: 'POST', headers: asUser(fx.ownerToken),
      body: JSON.stringify({ name: 'bound' }),
    })).json() as any
    await new Promise<void>((resolve) => s.close(() => resolve()))

    expect(listeners.opened).toEqual([made.servingPort])
    expect(listeners.bound()).toEqual([made.servingPort])
  })
})

describe('a group whose socket is not answering', () => {
  it('is not created at all when the port cannot be bound', async () => {
    // Something else on the host holding the port would otherwise leave a
    // group that is created, assignable, and unreachable.
    const refuses = {
      async open(): Promise<void> { throw new Error('EADDRINUSE') },
      async close(): Promise<void> {},
      bound(): number[] { return [] },
    }
    const app = appFor(db, () => refuses)
    const s = await new Promise<Server>((resolve) => {
      const started = app.listen(0, () => resolve(started))
    })
    const at = `http://127.0.0.1:${(s.address() as any).port}`
    const r = await fetch(`${at}/admin/v1/pools`, {
      method: 'POST', headers: asUser(fx.ownerToken),
      body: JSON.stringify({ name: 'cannot-bind' }),
    })
    const body = await r.json() as any
    const after = await (await fetch(`${at}/admin/v1/pools`,
                                     { headers: asUser(fx.ownerToken) })).json() as any[]
    await new Promise<void>((resolve) => s.close(() => resolve()))

    expect(r.status).toBe(409)
    expect(body.detail).toContain('EADDRINUSE')
    // And the row is gone, not left behind for somebody to find later.
    expect(after.some((p) => p.name === 'cannot-bind')).toBe(false)
  })

  it('makes the control plane unhealthy rather than reading as ok', async () => {
    // The dangerous case is a bind that failed at startup: the group exists,
    // its models are assigned, its machines are holding them, and nothing
    // answers. A health check that called that ok is why nobody would notice.
    // Monitoring is closed entirely unless an address range is configured, so
    // the check has to be reachable before it can be asked anything.
    process.env.DAI_MONITOR_CIDRS = '127.0.0.1/32'
    const listeners = new RecordingListeners()
    const app = appFor(db, () => listeners)
    const s = await new Promise<Server>((resolve) => {
      const started = app.listen(0, () => resolve(started))
    })
    const at = `http://127.0.0.1:${(s.address() as any).port}`

    const healthy = await fetch(`${at}/monitor/v1/health`)
    expect(healthy.status).toBe(200)

    // A group with a port that nothing bound, which is what a failed bind at
    // startup leaves behind.
    await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, serving_port)
       VALUES ('silent','harvest','independent-units','on-user-activity', 8499)`)
    const sick = await fetch(`${at}/monitor/v1/health`)
    const said = await sick.text()
    await new Promise<void>((resolve) => s.close(() => resolve()))

    expect(sick.status).toBe(503)
    expect(said).toContain('silent is not answering on :8499')
  })
})

describe('what answers on a group socket', () => {
  it('sees only that group, not the fleet', async () => {
    // The seeded machine holds a model and is harvest tier, so a cluster group
    // cannot have it - `whyNotInPool` refuses the tier before it looks at
    // anything else. A caller who addressed that group and was handed this
    // machine anyway would have no way to tell.
    //
    // A new *harvest* group would not do here, and that is worth knowing: an
    // empty membership rule is "any machine", so one of those legitimately
    // contains the whole fleet until somebody narrows it.
    await db.query(
      `UPDATE nodes SET resident_models = '{"a-model": 4}'::jsonb,
                        presence_state = 'ABSENT', last_heartbeat = now()
        WHERE id = $1`, [fx.nodeId])

    const empty = await createGroup('nobody-in-here', 'cluster')
    const port = empty.body.servingPort as number
    const app = appFor(db)
    extra = await new Promise<Server>((resolve) => {
      const s = app.listen(port, () => resolve(s))
    })

    const onGroup = await (await fetch(`http://127.0.0.1:${port}/v1/models`,
                                       { headers: asUser(fx.ownerToken) })).json() as any
    const onShared = await (await fetch(`${base}/v1/models`,
                                        { headers: asUser(fx.ownerToken) })).json() as any

    // Same routes, same credentials, different answer - and the only thing that
    // differed was the port the request arrived on.
    expect(onShared.data.length).toBeGreaterThan(0)
    expect(onGroup.data).toEqual([])
  })
})

describe('the listeners themselves', () => {
  it('opens a socket, refuses one already taken, and gives it back', async () => {
    // The one part of this that talks to the operating system. Everything else
    // is tested against a recorder, which cannot tell you that close() actually
    // frees the port - and a port that is never freed turns a restart into a
    // control plane that will not come up.
    const { BoundListeners } = await import('../src/lib/groupSockets.js')
    const http = await import('node:http')
    const listeners = new BoundListeners(() => http.createServer((_q, r) => r.end('ok')))

    // Port 0 would let the kernel choose and defeat the point, so take a real
    // one from the top of the default range, which nothing else here uses.
    const port = 8498
    await listeners.open(port)
    expect(listeners.bound()).toEqual([port])
    expect(await (await fetch(`http://127.0.0.1:${port}/`)).text()).toBe('ok')

    // Opening one that is already open is not an error; it is the same socket.
    await listeners.open(port)
    expect(listeners.bound()).toEqual([port])

    // A second manager cannot have it, and says so rather than silently
    // pretending to have bound.
    const rival = new BoundListeners(() => http.createServer())
    await expect(rival.open(port)).rejects.toThrow(/EADDRINUSE/)
    expect(rival.bound()).toEqual([])

    await listeners.close(port)
    expect(listeners.bound()).toEqual([])
    // And now somebody else can have it, which is what closing has to mean.
    await rival.open(port)
    expect(rival.bound()).toEqual([port])
    await rival.close(port)
  })
})

describe('a group that predates sockets', () => {
  it('is given one when asked, and told the same one if asked twice', async () => {
    // The seeded group was created before any of this, and there is no way to
    // delete and remake a group - so without this it would be unaddressable
    // for good.
    // Asked for by somebody with admin on that group, which the seeded
    // operator binding is not: giving a group a socket is changing how the
    // fleet is addressed, not operating it.
    await db.query(
      `UPDATE role_bindings SET role = 'admin' WHERE pool_id = $1`, [fx.poolId])

    const listeners = new RecordingListeners()
    const app = appFor(db, () => listeners)
    const s = await new Promise<Server>((resolve) => {
      const started = app.listen(0, () => resolve(started))
    })
    const at = `http://127.0.0.1:${(s.address() as any).port}`

    const first = await (await fetch(`${at}/admin/v1/pools/${fx.poolId}/socket`,
      { method: 'PUT', headers: asUser(fx.operatorToken) })).json() as any
    const again = await (await fetch(`${at}/admin/v1/pools/${fx.poolId}/socket`,
      { method: 'PUT', headers: asUser(fx.operatorToken) })).json() as any
    await new Promise<void>((resolve) => s.close(() => resolve()))

    expect(first).toEqual({ servingPort: DEFAULT_RANGE.from, allocated: true })
    // Not a second socket. A group handed a new port each time it was asked
    // would abandon the one clients are already pointed at.
    expect(again).toEqual({ servingPort: DEFAULT_RANGE.from, allocated: false })
    expect(listeners.opened).toEqual([DEFAULT_RANGE.from])
  })
})
