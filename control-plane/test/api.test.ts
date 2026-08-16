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

describe('node detail, for a machine that has actually reported', () => {
  it('serialises timestamps as strings rather than 500ing', async () => {
    // pg returns timestamptz as a Date and the schema declares a string. The
    // response validator inspects the object before serialisation, so this
    // failed for every machine that had ever sent a heartbeat - which is to
    // say every real one. The seeded demo machines had a null here and passed,
    // so the fleet view showed headroom for the fake machines and a dash for
    // the real ones, and the 500 underneath was swallowed by the caller.
    await db.query(`UPDATE nodes SET last_heartbeat = now() WHERE id = $1`, [fx.nodeId])

    const r = await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/detail`,
      { headers: asUser(fx.ownerToken) })
    expect(r.status).toBe(200)
    const d = await r.json()
    expect(typeof d.lastHeartbeat).toBe('string')
    expect(d.hostname).toBe('rotorua')
  })

  it('lists a heartbeating machine without failing validation', async () => {
    await db.query(`UPDATE nodes SET last_heartbeat = now() WHERE id = $1`, [fx.nodeId])
    const r = await fetch(`${base}/admin/v1/nodes`, { headers: asUser(fx.ownerToken) })
    expect(r.status).toBe(200)
    expect(typeof (await r.json())[0].lastHeartbeat).toBe('string')
  })
})

describe('agent surface', () => {
  it('answers 401 for a malformed token, not 500', async () => {
    // Session tokens are uuids and the column is one, so anything else made
    // Postgres raise and surfaced as a 500. A 500 tells a client the server is
    // broken and to retry: an invalid credential sent one interactive client
    // into its retry loop instead of failing fast, which is the opposite of
    // what a wrong credential should do.
    for (const token of ['lm-studio', 'not-a-uuid', '../../etc/passwd', '']) {
      const r = await fetch(`${base}/v1/models`, {
        headers: { authorization: `Bearer ${token}` },
      })
      expect(r.status, `token: ${JSON.stringify(token)}`).toBe(401)
    }

    // A well-formed but unknown one is also 401, and always was.
    const unknown = await fetch(`${base}/v1/models`, {
      headers: { authorization: 'Bearer 00000000-0000-0000-0000-000000000000' },
    })
    expect(unknown.status).toBe(401)
  })

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

  it('refuses a node whose identity has been superseded', async () => {
    // The failure this whole allowlist exists for. Re-enrolment retires the
    // earlier row for the same hardware, but the daemon holding the earlier
    // certificate does not stop on its own, and that certificate still
    // verifies. Without a state check it authenticates forever, and the fleet
    // shows the newer row - which is the one that is not reporting.
    await db.query(
      `INSERT INTO nodes (hostname, state, cert_fingerprint)
       VALUES ('old-identity','superseded','fp-superseded')`)
    const r = await fetch(`${base}/agent/v1/policy`, { headers: asNode('fp-superseded') })
    expect(r.status).toBe(401)
    expect((await r.json()).detail).toMatch(/re-enroll/)
  })

  it('refuses a node whose state is not one this file knows about', async () => {
    // Fails closed. A state added to the schema and not to the allowlist must
    // lose access rather than silently keep it, because the opposite is how
    // 'superseded' went unnoticed.
    await db.query(
      `UPDATE nodes SET state='offline' WHERE cert_fingerprint='fp-superseded'`)
    await db.query(
      `ALTER TABLE nodes DROP CONSTRAINT IF EXISTS nodes_state_check`)
    await db.query(
      `INSERT INTO nodes (hostname, state, cert_fingerprint)
       VALUES ('from-the-future','quarantined','fp-future')`)
    const r = await fetch(`${base}/agent/v1/policy`, { headers: asNode('fp-future') })
    expect(r.status).toBe(401)
    expect((await r.json()).detail).toMatch(/quarantined/)
  })

  it('still admits a paused node, so that pausing is not a one way door', async () => {
    // A paused node keeps heartbeating; an admin resumes it by acting on the
    // record those heartbeats maintain. Locking it out here would strand it.
    await db.query(
      `INSERT INTO nodes (hostname, state, cert_fingerprint)
       VALUES ('resting','paused','fp-paused')`)
    const r = await fetch(`${base}/agent/v1/policy`, { headers: asNode('fp-paused') })
    expect(r.status).toBe(200)
  })

  it('still admits a node marked offline, so it can come back', async () => {
    await db.query(
      `INSERT INTO nodes (hostname, state, cert_fingerprint)
       VALUES ('returning','offline','fp-offline')`)
    const r = await fetch(`${base}/agent/v1/policy`, { headers: asNode('fp-offline') })
    expect(r.status).toBe(200)
  })

  it('sets what a group serves, and reports it back', async () => {
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes) VALUES ('org/m','mlx','generate',1)
       ON CONFLICT DO NOTHING`)
    const set = await fetch(`${base}/admin/v1/pools/${fx.poolId}/serving-model`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ modelId: 'org/m' }),
    })
    expect(set.status).toBe(204)

    const pools = await (await fetch(`${base}/admin/v1/pools`,
      { headers: asUser(fx.operatorToken) })).json()
    expect(pools.find((p: { id: string }) => p.id === fx.poolId).servingModelId).toBe('org/m')
  })

  it('refuses a model nothing in the catalogue knows about', async () => {
    // Otherwise a group declares it serves something no machine could ever load,
    // and the first sign is a node failing rather than the assignment refusing.
    const r = await fetch(`${base}/admin/v1/pools/${fx.poolId}/serving-model`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ modelId: 'org/never-imported' }),
    })
    expect(r.status).toBe(404)
  })

  it('lets a cluster group override the harvest group on a shared machine', async () => {
    // This used to be refused outright, which made the order an operator did
    // two legitimate things in decide whether they were allowed to: assigning a
    // model to a cluster group failed because somebody had given a harvest
    // group a different one weeks earlier.
    //
    // The tiers are not equal claims. A cluster group promises never to be
    // preempted and is the only place a split can run; a harvest group promises
    // that the machine may be taken away the moment somebody touches a
    // keyboard. Only one of those survives on a single machine.
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes) VALUES ('org/a','mlx','generate',1),
                                                                ('org/b','mlx','generate',1)
       ON CONFLICT DO NOTHING`)
    await db.query(
      `UPDATE nodes SET state='active', tiers=ARRAY['harvest','cluster']::text[] WHERE id=$1`,
      [fx.nodeId])
    await db.query(`UPDATE pools SET serving_model_id='org/a' WHERE id=$1`, [fx.poolId])

    const other = await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt)
       VALUES ('serving','cluster','gang','never') RETURNING id`)
    const otherId = other.rows[0].id as string

    const r = await fetch(`${base}/admin/v1/pools/${otherId}/serving-model`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ modelId: 'org/b' }),
    })
    expect(r.status).toBe(204)

    // And the machine is told the cluster group's model, not the harvest
    // group's, which is the whole point of resolving rather than refusing.
    const beat = await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED' }),
    })
    expect((await beat.json() as any).servingModel).toBe('org/b')
  })

  it('allows two groups that agree', async () => {
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes) VALUES ('org/same','mlx','generate',1)
       ON CONFLICT DO NOTHING`)
    await db.query(
      `UPDATE nodes SET state='active', tiers=ARRAY['harvest','cluster']::text[] WHERE id=$1`,
      [fx.nodeId])
    await db.query(`UPDATE pools SET serving_model_id='org/same' WHERE id=$1`, [fx.poolId])
    const other = await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt)
       VALUES ('serving2','cluster','gang','never') RETURNING id`)

    const r = await fetch(`${base}/admin/v1/pools/${other.rows[0].id}/serving-model`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ modelId: 'org/same' }),
    })
    expect(r.status).toBe(204)
  })

  it('refuses a group that cannot run the model, saying what is short', async () => {
    // Asked at assignment. The alternative is a request that hangs, weeks
    // later, found by whoever happens to send one.
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines)
       VALUES ('org/huge','mlx','generate',$1,2) ON CONFLICT (id) DO UPDATE
         SET size_bytes=EXCLUDED.size_bytes, machines=EXCLUDED.machines`,
      [Math.round(40.4 * 1073741824)])
    await db.query(
      `UPDATE nodes SET state='active', tiers=ARRAY['harvest','cluster']::text[],
                        metal_working_set_gb=37.4 WHERE id=$1`, [fx.nodeId])

    const r = await fetch(`${base}/admin/v1/pools/${fx.poolId}/serving-model`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ modelId: 'org/huge' }),
    })
    expect(r.status).toBe(409)
    const body = await r.json()
    // One machine in the group, model needs two.
    expect(body.detail).toContain('needs 2 machines')
  })

  it('accepts a model the group can actually run', async () => {
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines)
       VALUES ('org/small','mlx','generate',$1,1) ON CONFLICT (id) DO UPDATE
         SET size_bytes=EXCLUDED.size_bytes, machines=EXCLUDED.machines`,
      [Math.round(4 * 1073741824)])
    await db.query(
      `UPDATE nodes SET state='active', tiers=ARRAY['harvest','cluster']::text[],
                        metal_working_set_gb=37.4 WHERE id=$1`, [fx.nodeId])

    const r = await fetch(`${base}/admin/v1/pools/${fx.poolId}/serving-model`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ modelId: 'org/small' }),
    })
    expect(r.status).toBe(204)
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
      method: 'POST', headers: asUser(fx.operatorToken), body: JSON.stringify({ until: null }),
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
    const r = await fetch(`${base}/admin/v1/fleet/summary`, { headers: asUser(fx.operatorToken) })
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
    // 200 rather than 204: the beat now carries back what the control plane
    // wants from this node, because there is no other way to reach a machine
    // that dials out and never listens.
    expect(r.status).toBe(200)
    expect(await r.json()).toHaveProperty('renewRequested')
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
      headers: asUser(fx.operatorToken),
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
    // jobFinished rides along on every result so a node learns the job is over
    // at the moment it ends, rather than at the next poll: it is holding tens of
    // gigabytes of somebody else's scene, on somebody else's machine.
    expect(await r.json()).toEqual({ requeued: 5, jobFinished: false })
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
  it('records what work is and where it came from, and lists it', async () => {
    // A fleet view that can say a machine is busy but not what with is not an
    // answer for an operator, and is a worse one for the person whose machine
    // is running it. Synthetic work especially has to be visible as synthetic,
    // or its throughput reads as real activity.
    const r = await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({
        poolId: fx.poolId, kind: 'embed', batchSize: 2,
        label: 'Nightly corpus reindex', source: 'test-harness',
        items: [{ id: 1 }, { id: 2 }, { id: 3 }],
      }),
    })
    expect(r.status).toBe(201)
    const created = await r.json() as any
    expect(created.label).toBe('Nightly corpus reindex')
    expect(created.source).toBe('test-harness')
    // Taken from the authenticated session, not from anything the caller says.
    expect(created.submittedBy).toBeTruthy()

    const list = await (await fetch(`${base}/admin/v1/jobs`,
      { headers: asUser(fx.operatorToken) })).json() as any[]
    const found = list.find((j) => j.id === created.id)
    expect(found.label).toBe('Nightly corpus reindex')
    expect(found.source).toBe('test-harness')

    // And it reaches the node, so the machine's owner can be told something
    // more useful than "embed".
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', onACPower: true, thermalOk: true }),
    })
    const lease = await (await fetch(`${base}/agent/v1/work?kinds=embed`,
      { headers: asNode(fx.fingerprint) })).json() as any
    expect(lease.jobLabel).toBe('Nightly corpus reindex')
    expect(lease.jobSource).toBe('test-harness')
  })

  it('gives back what it was asked to compute', async () => {
    // The API could take work and never return it: units completed, output
    // stored, nothing able to read it. A work API that accepts a request and
    // cannot answer it is not finished, however good its dispatch is.
    const submitted = await (await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({
        poolId: fx.poolId, kind: 'embed', batchSize: 2,
        label: 'results round trip', source: 'test-harness',
        items: [{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }],
      }),
    })).json() as any

    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', onACPower: true, thermalOk: true }),
    })

    // Work the whole job the way an agent would.
    for (;;) {
      const lease = await (await fetch(`${base}/agent/v1/work?kinds=embed`,
        { headers: asNode(fx.fingerprint) })).json() as any
      if (!lease.unitId) break
      await fetch(`${base}/agent/v1/work/${lease.unitId}/result`, {
        method: 'POST', headers: asNode(fx.fingerprint),
        body: JSON.stringify({
          completed: (lease.items as any[]).map((i) => ({ id: i.id, vector: [0.1, 0.2] })),
          seconds: 0.5,
        }),
      })
    }

    const page = await (await fetch(
      `${base}/admin/v1/jobs/${submitted.id}/results`,
      { headers: asUser(fx.operatorToken) })).json() as any

    const items = page.units.flatMap((u: any) => u.items)
    expect(items).toHaveLength(4)
    expect(items[0].vector).toEqual([0.1, 0.2])
    // Which machine produced it, since being able to answer that is the point.
    expect(page.units[0].node).toBeTruthy()
    // Null rather than an empty next page, so a caller knows it has everything
    // without asking again to find out.
    expect(page.nextAfter).toBeNull()
  })

  it('pages results in submission order', async () => {
    const submitted = await (await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({
        poolId: fx.poolId, kind: 'embed', batchSize: 1,
        items: [{ id: 1 }, { id: 2 }, { id: 3 }],
      }),
    })).json() as any
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', onACPower: true, thermalOk: true }),
    })
    for (;;) {
      const lease = await (await fetch(`${base}/agent/v1/work?kinds=embed`,
        { headers: asNode(fx.fingerprint) })).json() as any
      if (!lease.unitId) break
      await fetch(`${base}/agent/v1/work/${lease.unitId}/result`, {
        method: 'POST', headers: asNode(fx.fingerprint),
        body: JSON.stringify({ completed: lease.items, seconds: 0.1 }),
      })
    }

    const first = await (await fetch(
      `${base}/admin/v1/jobs/${submitted.id}/results?limit=2`,
      { headers: asUser(fx.operatorToken) })).json() as any
    expect(first.units).toHaveLength(2)
    expect(first.nextAfter).not.toBeNull()

    const rest = await (await fetch(
      `${base}/admin/v1/jobs/${submitted.id}/results?limit=2&after=${first.nextAfter}`,
      { headers: asUser(fx.operatorToken) })).json() as any
    expect(rest.units).toHaveLength(1)
    expect(rest.nextAfter).toBeNull()

    const ids = [...first.units, ...rest.units].flatMap((u: any) => u.items.map((i: any) => i.id))
    expect(ids).toEqual([1, 2, 3])
  })

  it('requires operator on the pool to submit a job', async () => {
    const r = await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST',
      headers: asUser(fx.strangerToken),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'embed', items: [{ id: 1 }] }),
    })
    expect(r.status).toBe(403)
  })

  it('lets an operator submit', async () => {
    const r = await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST',
      headers: asUser(fx.operatorToken),
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
      { method: 'POST', headers: asUser(fx.operatorToken), body: '{}' })
    const resume = () => fetch(`${base}/admin/v1/nodes/${fx.nodeId}/resume`,
      { method: 'POST', headers: asUser(fx.operatorToken), body: '{}' })

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
      { method: 'POST', headers: asUser(fx.operatorToken), body: '{}' })
    await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/resume`,
      { method: 'POST', headers: asUser(fx.operatorToken), body: '{}' })

    const { rows } = await db.query('SELECT state, user_paused FROM nodes WHERE id=$1',
                                    [fx.nodeId])
    expect(rows[0].state).toBe('active')
    expect(rows[0].user_paused).toBe(true)
  })

  it('lets the machine owner pause their own node without any role binding', async () => {
    const r = await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/pause`, {
      method: 'POST', headers: asUser(fx.ownerToken), body: JSON.stringify({}),
    })
    expect(r.status).toBe(200)
    expect((await r.json()).state).toBe('paused')
  })

  it('refuses to let an unrelated user pause someone else\'s node', async () => {
    const r = await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/pause`, {
      method: 'POST', headers: asUser(fx.strangerToken), body: JSON.stringify({}),
    })
    expect(r.status).toBe(403)
  })

  it('stops dispatching to a paused node', async () => {
    await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'embed', items: [{ id: 1 }] }),
    })
    await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/pause`, {
      method: 'POST', headers: asUser(fx.ownerToken), body: JSON.stringify({}),
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
      method: 'POST', headers: asUser(fx.operatorToken),
    })
    expect(r.status).toBe(403)
  })
})

/**
 * Tiers, which say what a machine is offered for rather than what it is.
 *
 * A machine may be offered for both, and that is the decision this endpoint
 * exists to record: cluster membership means presence does not gate serving,
 * so an interactive request can land on the machine while its owner is using
 * it. Batch work stays presence-gated, and the owner's pause still wins.
 */
describe('what a machine is offered for', () => {
  let db: Db
  let fx: Fixtures
  let server: Server
  let base: string

  beforeEach(async () => {
    db = await freshDb()
    fx = await seed(db)
    const g = await db.query(`INSERT INTO groups (name) VALUES ('ops') RETURNING id`)
    await db.query(`INSERT INTO group_members VALUES ($1,$2)`, [g.rows[0].id, fx.operatorId])
    await db.query(`INSERT INTO role_bindings VALUES ($1,$2,'operator')`,
      [g.rows[0].id, fx.poolId])
    const app = appFor(db)
    server = await new Promise<Server>((r) => { const s = app.listen(0, () => r(s)) })
    base = `http://127.0.0.1:${(server.address() as any).port}`
  })
  afterEach(async () => { await new Promise<void>((r) => server.close(() => r())) })
  afterAll(async () => { await db?.end() })

  const setTiers = (tiers: string[]) =>
    fetch(`${base}/admin/v1/nodes/${fx.nodeId}/tiers`, {
      method: 'PUT',
      headers: { authorization: `Bearer ${fx.operatorToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({ tiers }),
    })

  it('puts a machine in both, and the derived tier follows', async () => {
    const r = await setTiers(['harvest', 'cluster'])
    expect(r.status).toBe(200)
    const node = await r.json()
    expect(node.tiers).toEqual(['harvest', 'cluster'])
    // The scheduler, the router and the agent all ask one question of `tier`,
    // and a machine offered for cluster work must answer it the same way a
    // dedicated box does. That is the whole meaning of being in both.
    expect(node.tier).toBe('cluster')
  })

  it('a harvest-only machine reads as harvest', async () => {
    expect((await (await setTiers(['harvest'])).json()).tier).toBe('harvest')
  })

  it('refuses to leave a machine offered for nothing', async () => {
    // It would still run, still heartbeat and never receive work, which is
    // indistinguishable from a broken agent.
    //
    // The refusal comes from the spec's own minItems rather than the handler,
    // which is the better of the two: the contract says a machine is offered
    // for at least one thing, so a client is told by the contract. The handler
    // keeps its own check for callers that reach it another way.
    const r = await setTiers([])
    expect(r.status).toBe(400)
    expect((await r.json()).detail).toContain('tiers')
  })

  it('refuses a tier it does not have', async () => {
    expect((await setTiers(['harvest', 'gpu-farm'])).status).toBe(400)
  })

  it('does not count a tier twice', async () => {
    const node = await (await setTiers(['cluster', 'cluster'])).json()
    expect(node.tiers).toEqual(['cluster'])
  })

  it('records the change, because it is one somebody should be able to find', async () => {
    await setTiers(['harvest', 'cluster'])
    const { rows } = await db.query(
      `SELECT detail FROM activity_log WHERE node_id=$1 AND event='node.tiers'`, [fx.nodeId])
    expect(rows[0].detail.tiers).toEqual(['harvest', 'cluster'])
  })

  it('is refused to somebody with no role anywhere', async () => {
    const { rows } = await db.query(
      `INSERT INTO users (email, username) VALUES ('nobody@example.com','nobody')
       RETURNING id`)
    const { rows: tok } = await db.query(
      `INSERT INTO auth_tokens (user_id, token_hash, kind, expires_at)
       VALUES ($1, encode(sha256('rolelesstoken'::bytea),'hex'), 'session', now() + interval '1 hour')
       RETURNING user_id`, [rows[0].id])
    expect(tok).toHaveLength(1)

    const r = await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/tiers`, {
      method: 'PUT',
      headers: { authorization: 'Bearer rolelesstoken', 'content-type': 'application/json' },
      body: JSON.stringify({ tiers: ['cluster'] }),
    })
    expect(r.status).toBe(403)
  })
})

/**
 * Readiness, over HTTP, against a real database.
 *
 * The logic is unit-tested; this covers the half that is not logic - the SQL
 * and the shape of the columns. `resident_models` and `model_context` are jsonb
 * objects in the database while the node listing flattens them to arrays, and
 * reading the wrong one gives a group that is permanently "fetching the
 * weights" with no way to tell that from the truth.
 */
describe('whether a split group is ready to serve', () => {
  const model = 'mlx-community/Qwen2.5-Coder-32B-Instruct-4bit'

  const readyNode = async (hostname: string, address: string | null) => {
    const { rows } = await db.query(
      // tiers, plural: tier is derived from it. A machine in a cluster group
      // is in the cluster tier, which is what makes it a member here.
      `INSERT INTO nodes (hostname, tiers, state, cert_fingerprint, last_heartbeat,
                          resident_models, model_context, pipeline_address)
       VALUES ($1, ARRAY['cluster']::text[], 'active', $2, now(),
               $3::jsonb, $3::jsonb, $4)
       RETURNING id`,
      [hostname, `fp-${hostname}`, JSON.stringify({ [model]: 32768 }), address])
    return rows[0]!.id as string
  }

  const splitPool = async () => {
    await db.query(
      `INSERT INTO models (id, size_bytes, machines, runtime, kind)
       VALUES ($1, $2, 2, 'mlx', 'generate')
       ON CONFLICT (id) DO UPDATE SET machines = 2`, [model, 18_400_000_000])
    const { rows } = await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, serving_model_id, enabled)
       VALUES ('split-cluster','cluster','gang','never',$1,true) RETURNING id`, [model])
    return rows[0]!.id as string
  }

  it('reads the jsonb columns, not the flattened listing', async () => {
    const poolId = await splitPool()
    await readyNode('orca', '192.168.99.1')
    await readyNode('rotorua', '192.168.99.2')

    const r = await fetch(`${base}/admin/v1/pools/${poolId}/readiness`,
      { headers: asUser(fx.operatorToken) })
    const body = await r.json() as any
    expect(r.status).toBe(200)
    expect(body.state).toBe('ready')
    expect(body.machines).toBe(2)
    expect(body.ranks.map((x: any) => x.rank).sort()).toEqual([0, 1])
    // The head is a machine that can be dialled, as the router requires.
    expect(body.ranks.find((x: any) => x.rank === 0).dialable).toBe(true)
  })

  it('blocks, and names the setting, when no machine can be dialled', async () => {
    const poolId = await splitPool()
    await readyNode('orca', null)
    await readyNode('rotorua', null)

    const r = await fetch(`${base}/admin/v1/pools/${poolId}/readiness`,
      { headers: asUser(fx.operatorToken) })
    const body = await r.json() as any
    expect(body.state).toBe('blocked')
    expect(JSON.stringify(body)).toContain('DAI_PIPELINE_INTERFACE')
  })

  it('is idle rather than broken when the group is stood down', async () => {
    const poolId = await splitPool()
    await db.query(`UPDATE pools SET enabled = false WHERE id = $1`, [poolId])
    await readyNode('orca', '192.168.99.1')

    const r = await fetch(`${base}/admin/v1/pools/${poolId}/readiness`,
      { headers: asUser(fx.operatorToken) })
    expect((await r.json() as any).state).toBe('idle')
  })

  it('404s for a group that does not exist', async () => {
    const r = await fetch(
      `${base}/admin/v1/pools/00000000-0000-0000-0000-000000000000/readiness`,
      { headers: asUser(fx.operatorToken) })
    expect(r.status).toBe(404)
  })
})


/**
 * The rank a machine is told before anything asks for it.
 *
 * Rank was decided per request at dispatch, which is too late to have built
 * anything - a cold gang pays the slowest machine's load before the first
 * token. Sent with the heartbeat, from the same assignment the router makes, so
 * the share a machine warms is the one it will be asked for.
 */
describe('the share a machine is told to hold', () => {
  const model = 'mlx-community/Qwen2.5-Coder-32B-Instruct-4bit'

  const clusterNode = async (hostname: string, address: string | null) => {
    const { rows } = await db.query(
      `INSERT INTO nodes (hostname, tiers, state, cert_fingerprint, last_heartbeat,
                          pipeline_address)
       VALUES ($1, ARRAY['cluster']::text[], 'active', $2, now(), $3)
       RETURNING id`, [hostname, `fp-${hostname}`, address])
    return rows[0]!.id as string
  }

  const splitGroup = async () => {
    await db.query(
      `INSERT INTO models (id, size_bytes, machines, runtime, kind)
       VALUES ($1, 1, 2, 'mlx', 'generate')
       ON CONFLICT (id) DO UPDATE SET machines = 2`, [model])
    await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, serving_model_id, enabled)
       VALUES ('split-cluster','cluster','gang','never',$1,true)`, [model])
  }

  const beat = (fp: string) =>
    fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fp),
      body: JSON.stringify({ presenceState: 'IDLE' }),
    })

  it('gives the output head to a machine that can be dialled', async () => {
    await splitGroup()
    await clusterNode('rotorua-split', null)
    await clusterNode('orca-split', '192.168.99.2')

    const head = await (await beat('fp-orca-split')).json() as any
    const feeder = await (await beat('fp-rotorua-split')).json() as any
    expect(head.rank).toBe(0)
    expect(head.size).toBe(2)
    expect(feeder.rank).toBe(1)
    // And the width, so the machine knows this is a share rather than a model.
    expect(head.machines).toBe(2)
  })

  it('sends no rank when nobody can be dialled', async () => {
    // A machine told a rank would build a share for a gang that cannot form.
    await splitGroup()
    await clusterNode('a-split', null)
    await clusterNode('b-split', null)

    const body = await (await beat('fp-a-split')).json() as any
    expect(body.rank).toBeUndefined()
    expect(body.size).toBeUndefined()
  })

  it('sends no rank when the group is bigger than the model needs', async () => {
    // The router forms a gang of exactly `machines` and picks which machines.
    // A prediction made ahead of that can only be right when there is nothing
    // to pick: with three machines and a two-machine model, every one of them
    // would warm rank r of three, the dispatch would say two, and all three
    // would rebuild - pre-warming quietly doing nothing while appearing to
    // work. Invisible on a two-machine fleet, which is why it is asserted.
    await splitGroup()
    await clusterNode('one-split', '192.168.99.11')
    await clusterNode('two-split', '192.168.99.12')
    await clusterNode('three-split', '192.168.99.13')

    const body = await (await beat('fp-one-split')).json() as any
    expect(body.machines).toBe(2)
    expect(body.rank).toBeUndefined()
    expect(body.size).toBeUndefined()
  })

  it('sends no rank for a model that runs on one machine', async () => {
    // Nothing to build ahead: the machine holds the whole model.
    await db.query(
      `INSERT INTO models (id, size_bytes, machines, runtime, kind)
       VALUES ('org/whole', 1, 1, 'mlx', 'generate') ON CONFLICT DO NOTHING`)
    await db.query(
      `UPDATE pools SET serving_model_id = 'org/whole' WHERE id = $1`, [fx.poolId])

    const body = await (await beat(fx.fingerprint)).json() as any
    expect(body.rank).toBeUndefined()
    expect(body.machines).toBe(1)
  })
})


/**
 * A stood-down group claims no machines, on the surfaces the agent asks.
 *
 * poolsFor drops a disabled group and cannot do that without the column. Two
 * agent queries selected id, tier and membership and not enabled, which made
 * every group look live to the filter. Harmless in both cases only by accident -
 * each had a second filter downstream - and the same omission has already
 * produced three separate faults, found and fixed one at a time.
 */
describe('what a stood-down group offers an agent', () => {
  it('does not name the build a disabled group wanted', async () => {
    // The fault this shape caused before: two managed groups, one stood down
    // holding an older version, and the fleet pinned to a build nobody had
    // asked for since.
    await db.query(
      `INSERT INTO agent_builds (version, sha256, size_bytes)
       VALUES ('8.8.8', repeat('b',64), 1) ON CONFLICT DO NOTHING`)
    await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, agent_channel,
                          desired_agent_version, enabled)
       VALUES ('stale-desired','harvest','independent-units','on-user-activity',
               'managed','8.8.8', false)`)

    const r = await fetch(`${base}/agent/v1/agent/desired`,
      { headers: asNode(fx.fingerprint) })
    const body = await r.json() as any
    expect(body.version).not.toBe('8.8.8')
  })

  it('does not assign models from a disabled group', async () => {
    await db.query(
      `INSERT INTO models (id, size_bytes, machines, runtime, kind)
       VALUES ('org/ghost', 1, 1, 'mlx', 'generate') ON CONFLICT DO NOTHING`)
    const { rows } = await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, serving_model_id, enabled)
       VALUES ('ghost-group','harvest','independent-units','on-user-activity',
               'org/ghost', false)
       RETURNING id`)
    expect(rows[0]).toBeDefined()

    const r = await fetch(`${base}/agent/v1/models/assigned`,
      { headers: asNode(fx.fingerprint) })
    const assigned = await r.json() as any[]
    expect(assigned.some((m) => m.id === 'org/ghost')).toBe(false)
  })
})


/**
 * A setting nobody can set is worse than a fleet constant.
 *
 * The column, the resolution and the directive all shipped before anything
 * could read or write it: an operator could neither see the window nor change
 * it, so every group was on the default whether that suited it or not.
 */
describe('how long a group keeps a model when nothing is asking', () => {
  const set = (poolId: string, seconds: number | null) =>
    fetch(`${base}/admin/v1/pools/${poolId}/idle-unload`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ seconds }),
    })

  it('sets a window and shows it back', async () => {
    expect((await set(fx.poolId, 60)).status).toBe(200)
    const pools = await (await fetch(`${base}/admin/v1/pools`,
      { headers: asUser(fx.operatorToken) })).json() as any[]
    expect(pools.find((p) => p.id === fx.poolId).idleUnloadSeconds).toBe(60)
  })

  it('null restores the fleet default', async () => {
    // Distinct from zero, which is refused. Null means "whatever the fleet
    // says"; a group that had been given a number needs a way back.
    await set(fx.poolId, 60)
    expect((await set(fx.poolId, null)).status).toBe(200)
    const pools = await (await fetch(`${base}/admin/v1/pools`,
      { headers: asUser(fx.operatorToken) })).json() as any[]
    expect(pools.find((p) => p.id === fx.poolId).idleUnloadSeconds).toBeNull()
  })

  it('refuses a window that would release between the turns of a conversation', async () => {
    // Zero would unload after every request, which is the behaviour that cost
    // 37 seconds a request the last time a loop released too eagerly.
    expect((await set(fx.poolId, 0)).status).toBe(400)
    expect((await set(fx.poolId, -30)).status).toBe(400)
    expect((await set(fx.poolId, 1.5 as never)).status).toBe(400)
  })

  it('404s for a group that does not exist', async () => {
    const r = await set('00000000-0000-0000-0000-000000000000', 60)
    expect(r.status).toBe(404)
  })

  it('reaches the machine as a directive', async () => {
    // The whole point: set on the group, resolved by the same winner that
    // decides the model, and sent as intent rather than topology.
    await set(fx.poolId, 90)
    await db.query(
      `INSERT INTO models (id, size_bytes, machines, runtime, kind)
       VALUES ('org/idle', 1, 1, 'mlx', 'generate') ON CONFLICT DO NOTHING`)
    await db.query(
      `UPDATE pools SET serving_model_id = 'org/idle' WHERE id = $1`, [fx.poolId])

    const beat = await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'IDLE' }),
    })
    expect((await beat.json() as any).idleUnloadSeconds).toBe(90)
  })
})


/**
 * Telling a group to serve a model, in the order that works.
 *
 * Three writes, and until now every caller did them separately. The middle one
 * was simply missing: serving a model and holding it are different tables, and
 * setting only pools.serving_model_id leaves a group waiting forever with
 * nothing fetching anything. It went unnoticed because every model on this
 * fleet had been pushed long before.
 */
describe('telling a group what to serve', () => {
  const model = 'org/serve-me'

  const known = () => db.query(
    `INSERT INTO models (id, size_bytes, machines, runtime, kind)
     VALUES ($1, 1000, 1, 'mlx', 'generate') ON CONFLICT (id) DO NOTHING`, [model])

  const serve = (poolId: string, body: object) =>
    fetch(`${base}/admin/v1/pools/${poolId}/serve`, {
      method: 'PUT', headers: asUser(fx.operatorToken), body: JSON.stringify(body),
    })

  it('writes all three, including the one that was missing', async () => {
    await known()
    const r = await serve(fx.poolId, { modelId: model, machines: 1 })
    expect(r.status).toBe(200)

    const { rows: pool } = await db.query(
      `SELECT serving_model_id FROM pools WHERE id = $1`, [fx.poolId])
    expect(pool[0].serving_model_id).toBe(model)

    // The step that was missing. Without it the machines are told to serve
    // something they were never told to fetch.
    const { rows: held } = await db.query(
      `SELECT 1 FROM pool_models WHERE pool_id = $1 AND model_id = $2`,
      [fx.poolId, model])
    expect(held).toHaveLength(1)

    const { rows: m } = await db.query(`SELECT machines FROM models WHERE id = $1`, [model])
    expect(Number(m[0].machines)).toBe(1)
  })

  it('is idempotent, because it is not a transaction', async () => {
    // Three statements with no transaction around them: a failure between them
    // leaves a group half-prepared, and running it again has to finish the job
    // rather than fail on what already succeeded.
    await known()
    expect((await serve(fx.poolId, { modelId: model, machines: 1 })).status).toBe(200)
    expect((await serve(fx.poolId, { modelId: model, machines: 1 })).status).toBe(200)
    const { rows } = await db.query(
      `SELECT count(*)::int AS n FROM pool_models WHERE pool_id=$1 AND model_id=$2`,
      [fx.poolId, model])
    expect(rows[0].n).toBe(1)
  })

  it('404s for a model nobody has imported', async () => {
    const r = await serve(fx.poolId, { modelId: 'org/not-here' })
    expect(r.status).toBe(404)
  })

  it('404s for a group that does not exist', async () => {
    await known()
    const r = await serve('00000000-0000-0000-0000-000000000000', { modelId: model })
    expect(r.status).toBe(404)
  })

  it('needs a model named', async () => {
    expect((await serve(fx.poolId, { machines: 2 })).status).toBe(400)
  })

  it('refuses a width the machines cannot hold', async () => {
    // Asked here rather than at dispatch, where the answer arrives as a request
    // that hangs, weeks later, found by whoever happens to send one.
    await db.query(
      `INSERT INTO models (id, size_bytes, machines, runtime, kind)
       VALUES ('org/enormous', 900000000000, 1, 'mlx', 'generate')
       ON CONFLICT (id) DO NOTHING`)
    const r = await serve(fx.poolId, { modelId: 'org/enormous', machines: 1 })
    expect(r.status).toBe(409)
    expect(JSON.stringify(await r.json())).toContain('cannot run')
  })
})

/**
 * Whether readiness can tell fetching from never having been asked.
 *
 * The route fed the check pools.serving_model_id and compared it against
 * itself, so the branch that says "nothing was ever asked for" could not fire.
 */
describe('readiness knows what the machines were told to hold', () => {
  it('says so when a group serves a model nobody pushed', async () => {
    const model = 'org/never-pushed'
    await db.query(
      `INSERT INTO models (id, size_bytes, machines, runtime, kind)
       VALUES ($1, 1000, 1, 'mlx', 'generate') ON CONFLICT DO NOTHING`, [model])
    const { rows } = await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, serving_model_id, enabled)
       VALUES ('unpushed','cluster','gang','never',$1,true) RETURNING id`, [model])
    await db.query(
      `INSERT INTO nodes (hostname, tiers, state, cert_fingerprint, last_heartbeat)
       VALUES ('lonely', ARRAY['cluster']::text[], 'active', 'fp-lonely', now())`)

    const r = await fetch(`${base}/admin/v1/pools/${rows[0].id}/readiness`,
      { headers: asUser(fx.operatorToken) })
    const body = await r.json() as any
    expect(JSON.stringify(body)).toContain('not been told')
  })
})
