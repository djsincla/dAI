import type { Server } from 'node:http'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { type Fixtures, appFor, freshDb, seed, setPresence, submitJob } from './helpers.js'

let db: Db
let fx: Fixtures
let server: Server
let base: string

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
  await new Promise<void>((resolve) => server.close(() => resolve()))
})
afterAll(async () => { await db?.end() })

const asNode = (fp: string) => ({ 'x-node-fingerprint': fp, 'content-type': 'application/json' })
const asUser = (id: string) => ({ authorization: `Bearer ${id}`, 'content-type': 'application/json' })

describe('agent surface', () => {
  it('rejects a request with no client certificate', async () => {
    const r = await fetch(`${base}/agent/v1/policy`)
    expect(r.status).toBe(401)
  })

  it('rejects an unknown certificate', async () => {
    const r = await fetch(`${base}/agent/v1/policy`, { headers: asNode('fp-nobody') })
    expect(r.status).toBe(401)
  })

  it('rejects a node that has enrolled but not been approved', async () => {
    await db.query(
      `INSERT INTO nodes (hostname, state, cert_fingerprint) VALUES ('new','pending','fp-pending')`)
    const r = await fetch(`${base}/agent/v1/policy`, { headers: asNode('fp-pending') })
    expect(r.status).toBe(401)
  })

  it('serves the policy table to an approved node', async () => {
    const r = await fetch(`${base}/agent/v1/policy`, { headers: asNode(fx.fingerprint) })
    expect(r.status).toBe(200)
    const policy = await r.json()
    // The values the agent enforces locally must match what it is told.
    expect(policy.ACTIVE.gpu).toBe(false)
    expect(policy.IDLE.gpu).toBe(false)
    expect(policy.LOCKED.gpu).toBe(true)
    expect(policy.LOCKED.qos).toBe('standard')
    for (const state of Object.keys(policy)) expect(policy[state].ane).toBe(true)
  })

  it('accepts a request for more than one work kind', async () => {
    // Regression, and an expensive one. `kinds` was declared as a plain string
    // documented as comma-separated, which made the validator treat the comma
    // as a reserved character and reject the parameter's own example. Asking
    // for one kind worked, so every test passed; asking for two returned 400.
    // A node sat in LOCKED with GPU work queued, asking for it every five
    // seconds and being refused, and nothing on either side said so.
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', onACPower: true, thermalOK: true }),
    })

    for (const query of ['embed,generate', 'embed%2Cgenerate']) {
      const r = await fetch(`${base}/agent/v1/work?kinds=${query}`, {
        headers: asNode(fx.fingerprint),
      })
      expect(r.status, `kinds=${query}`).toBe(200)
    }
  })

  it('serves GPU work to a locked node and withholds it from an active one', async () => {
    // The property the whole product rests on, asserted over HTTP rather than
    // against the function underneath it, because that is where it broke.
    // Its own work, rather than whatever the fixture happens to leave behind:
    // a test that depends on another test's leftovers passes for the wrong
    // reason and fails for one too.
    await submitJob(db, fx.poolId, 'generate', 4, 2)

    const ask = async (presenceState: string) => {
      await fetch(`${base}/agent/v1/heartbeat`, {
        method: 'POST', headers: asNode(fx.fingerprint),
        body: JSON.stringify({ presenceState, onACPower: true, thermalOK: true }),
      })
      const r = await fetch(`${base}/agent/v1/work?kinds=embed,generate`, {
        headers: asNode(fx.fingerprint),
      })
      return r.json() as Promise<any>
    }

    expect((await ask('ACTIVE')).kind).toBeUndefined()
    expect((await ask('LOCKED')).kind).toBe('generate')
  })

  it('withholds work from a node its owner paused, and no admin can lift it', async () => {
    // The property the whole arrangement depends on. Isolation here is policy,
    // not hardware, so the only hard guarantee a machine's owner has is that
    // the off switch works. An admin who can clear it turns the agent into
    // something people work around instead of trust.
    await submitJob(db, fx.poolId, 'embed', 4, 2)
    const beat = (userPaused: boolean) =>
      fetch(`${base}/agent/v1/heartbeat`, {
        method: 'POST', headers: asNode(fx.fingerprint),
        body: JSON.stringify({ presenceState: 'LOCKED', onACPower: true,
                               thermalOk: true, userPaused }),
      })
    const ask = async () => {
      const r = await fetch(`${base}/agent/v1/work?kinds=embed,generate`,
                            { headers: asNode(fx.fingerprint) })
      return r.json() as Promise<any>
    }

    await beat(true)
    expect((await ask()).reason).toBe('user-paused')

    // An operator unpausing the node administratively must not touch it.
    await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/pause`, {
      method: 'POST', headers: asUser(fx.operatorId), body: JSON.stringify({ until: null }),
    })
    const { rows } = await db.query('SELECT user_paused, state FROM nodes WHERE id=$1',
                                    [fx.nodeId])
    expect(rows[0].user_paused).toBe(true)
    expect((await ask()).reason).toBe('user-paused')

    // Only the machine itself can lift it, by saying so on a heartbeat.
    await beat(false)
    const after = await db.query('SELECT user_paused FROM nodes WHERE id=$1', [fx.nodeId])
    expect(after.rows[0].user_paused).toBe(false)
  })

  it('leaves a user-paused machine out of fleet capacity', async () => {
    // Counting a paused machine would overstate the fleet by exactly the
    // machines whose owners have opted out, which is the number most worth
    // being honest about.
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'ABSENT', onACPower: true,
                             thermalOk: true, userPaused: true }),
    })
    const r = await fetch(`${base}/admin/v1/fleet/summary`, { headers: asUser(fx.operatorId) })
    const summary = await r.json() as any
    const gpu = summary.now?.gpuGb ?? summary.gpuGb ?? 0
    expect(gpu).toBe(0)
  })

  it('records heartbeat and stores capability per workload class', async () => {
    const r = await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST',
      headers: asNode(fx.fingerprint),
      body: JSON.stringify({
        presenceState: 'LOCKED',
        onAcPower: true,
        capabilitySamples: [
          { workloadClass: 'qwen2.5-1.5b', itemsPerSecond: 5.13 },
          { workloadClass: 'qwen2.5-7b', itemsPerSecond: 1.99 },
        ],
      }),
    })
    expect(r.status).toBe(204)
    const { rows } = await db.query(`SELECT capability_profiles FROM nodes WHERE id=$1`, [fx.nodeId])
    // A scalar would misallocate: the same machines differ 7.5% on 1.5B and
    // 26.3% on 7B.
    expect(rows[0].capability_profiles).toEqual({
      'qwen2.5-1.5b': 5.13, 'qwen2.5-7b': 1.99,
    })
  })

  it('rejects a malformed heartbeat against the schema', async () => {
    const r = await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST',
      headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'NAPPING' }),
    })
    expect(r.status).toBe(400)
  })

  it('enrolls into pending and issues nothing', async () => {
    await db.query(`INSERT INTO join_tokens (token) VALUES ('jt-good')`)
    const r = await fetch(`${base}/agent/v1/enroll`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        joinToken: 'jt-good', hostname: 'newmac', chip: 'Apple M4 Pro',
        memoryGb: 48, metalWorkingSetGb: 37.4, osVersion: '26.5.1',
        csrPem: '-----BEGIN CERTIFICATE REQUEST-----fake',
      }),
    })
    expect(r.status).toBe(202)
    expect((await r.json()).state).toBe('pending')
  })

  it('refuses an invalid join token', async () => {
    const r = await fetch(`${base}/agent/v1/enroll`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        joinToken: 'jt-forged', hostname: 'evil', chip: 'x', memoryGb: 1,
        metalWorkingSetGb: 1, osVersion: '1', csrPem: 'x',
      }),
    })
    expect(r.status).toBe(401)
  })
})

describe('work dispatch over HTTP', () => {
  async function job(kind: string, items = 16) {
    const r = await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST',
      headers: asUser(fx.operatorId),
      body: JSON.stringify({
        poolId: fx.poolId, kind,
        items: Array.from({ length: items }, (_, i) => ({ id: i, prompt: `p${i}` })),
      }),
    })
    expect(r.status).toBe(201)
    return r.json()
  }

  it('serves embed work to a node with a user present, and no generate work', async () => {
    await job('embed')
    await job('generate')
    await setPresence(db, fx.nodeId, 'ACTIVE')

    const embed = await (await fetch(`${base}/agent/v1/work?kinds=embed`, {
      headers: asNode(fx.fingerprint) })).json()
    expect(embed).toHaveProperty('unitId')
    expect(embed.kind).toBe('embed')

    const gen = await (await fetch(`${base}/agent/v1/work?kinds=generate`, {
      headers: asNode(fx.fingerprint) })).json()
    expect(gen).toEqual({ reason: 'none-of-these-kinds' })
  })

  it('round-trips a partial result and reports the requeue count', async () => {
    await job('embed', 16)
    const lease = await (await fetch(`${base}/agent/v1/work?kinds=embed`, {
      headers: asNode(fx.fingerprint) })).json()

    const r = await fetch(`${base}/agent/v1/work/${lease.unitId}/result`, {
      method: 'POST',
      headers: asNode(fx.fingerprint),
      body: JSON.stringify({
        completed: lease.items.slice(0, 3), unfinished: lease.items.slice(3), seconds: 0.9,
      }),
    })
    expect(r.status).toBe(200)
    expect(await r.json()).toEqual({ requeued: 5 })
  })

  it('returns 409 for a result against an expired lease', async () => {
    await job('embed', 8)
    const lease = await (await fetch(`${base}/agent/v1/work?kinds=embed`, {
      headers: asNode(fx.fingerprint) })).json()
    await db.query(`UPDATE work_units SET state='pending', lease_node_id=NULL`)

    const r = await fetch(`${base}/agent/v1/work/${lease.unitId}/result`, {
      method: 'POST',
      headers: asNode(fx.fingerprint),
      body: JSON.stringify({ completed: [], seconds: 1 }),
    })
    expect(r.status).toBe(409)
  })
})

describe('authorization', () => {
  it('requires operator on the pool to submit a job', async () => {
    const r = await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST',
      headers: asUser(fx.strangerId),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'embed', items: [{ id: 1 }] }),
    })
    expect(r.status).toBe(403)
  })

  it('lets an operator submit', async () => {
    const r = await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST',
      headers: asUser(fx.operatorId),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'embed', items: [{ id: 1 }] }),
    })
    expect(r.status).toBe(201)
  })

  /**
   * Not a permission check. An operator who could force work onto someone's Mac
   * makes the agent malware in that person's mental model, so ownership grants
   * pause rights that no role can remove.
   */
  it('lets an operator lift a pause they applied', async () => {
    // Pause could be applied and never removed, so the button was a one-way
    // door: the node stayed out of the fleet until somebody edited the
    // database.
    const pause = () => fetch(`${base}/admin/v1/nodes/${fx.nodeId}/pause`,
      { method: 'POST', headers: asUser(fx.operatorId), body: '{}' })
    const resume = () => fetch(`${base}/admin/v1/nodes/${fx.nodeId}/resume`,
      { method: 'POST', headers: asUser(fx.operatorId), body: '{}' })

    await pause()
    let { rows } = await db.query('SELECT state FROM nodes WHERE id=$1', [fx.nodeId])
    expect(rows[0].state).toBe('paused')

    const r = await resume()
    expect(r.status).toBe(200)
    rows = (await db.query('SELECT state, paused_until FROM nodes WHERE id=$1',
                           [fx.nodeId])).rows
    expect(rows[0].state).toBe('active')
    expect(rows[0].paused_until).toBeNull()
  })

  it('resuming a node does not lift the pause its owner set', async () => {
    // An operator restarting a machine they paused must not quietly also
    // override the person sitting at it.
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', onACPower: true,
                             thermalOk: true, userPaused: true }),
    })
    await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/pause`,
      { method: 'POST', headers: asUser(fx.operatorId), body: '{}' })
    await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/resume`,
      { method: 'POST', headers: asUser(fx.operatorId), body: '{}' })

    const { rows } = await db.query('SELECT state, user_paused FROM nodes WHERE id=$1',
                                    [fx.nodeId])
    expect(rows[0].state).toBe('active')
    expect(rows[0].user_paused).toBe(true)
  })

  it('lets the machine owner pause their own node without any role binding', async () => {
    const r = await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/pause`, {
      method: 'POST', headers: asUser(fx.ownerId), body: JSON.stringify({}),
    })
    expect(r.status).toBe(200)
    expect((await r.json()).state).toBe('paused')
  })

  it('refuses to let an unrelated user pause someone else\'s node', async () => {
    const r = await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/pause`, {
      method: 'POST', headers: asUser(fx.strangerId), body: JSON.stringify({}),
    })
    expect(r.status).toBe(403)
  })

  it('stops dispatching to a paused node', async () => {
    await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorId),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'embed', items: [{ id: 1 }] }),
    })
    await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/pause`, {
      method: 'POST', headers: asUser(fx.ownerId), body: JSON.stringify({}),
    })
    const out = await (await fetch(`${base}/agent/v1/work?kinds=embed`, {
      headers: asNode(fx.fingerprint) })).json()
    expect(out).toEqual({ reason: 'node-paused' })
  })

  it('requires an admin binding to approve a node', async () => {
    await db.query(
      `INSERT INTO nodes (hostname, state, cert_fingerprint) VALUES ('new','pending','fp-new')`)
    const { rows } = await db.query(`SELECT id FROM nodes WHERE cert_fingerprint='fp-new'`)
    const r = await fetch(`${base}/admin/v1/nodes/${rows[0].id}/approve`, {
      method: 'POST', headers: asUser(fx.operatorId),
    })
    expect(r.status).toBe(403)
  })
})
