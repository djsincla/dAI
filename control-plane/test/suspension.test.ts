import type { Server } from 'node:http'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { type Fixtures, appFor, freshDb, seed, setPresence } from './helpers.js'
import { costOfServing, suspensionFor, suspensions } from '../src/lib/suspension.js'
import type { Group } from '../src/lib/groupRules.js'

/**
 * A machine holding part of a split model is not available to its harvest group.
 *
 * The rule exists because a gang cannot be preempted and harvest membership is
 * the promise that a machine can be taken away. Getting it wrong in either
 * direction is expensive: leave the machine harvesting and a keyboard press
 * kills a job on N machines; suspend one that is not holding a split and the
 * fleet quietly loses capacity nobody asked it to give up.
 */
const node = (id: string, hostname: string, over: Record<string, unknown> = {}) => ({
  id, hostname, tier: 'cluster', chip: 'Apple M2 Max', memory_gb: 64, ...over,
})

const group = (id: string, name: string, tier: string,
               servingModelId: string | null = null,
               membership: Record<string, unknown> = {}): Group =>
  ({ id, name, tier, membership, servingModelId } as unknown as Group)

const splits = (modelId: string) => (modelId === 'big-72b' ? 2 : 1)

describe('when a machine stops being available to harvest', () => {
  it('suspends a machine whose cluster group serves a split model', () => {
    const s = suspensionFor(
      node('n1', 'rotorua'),
      [group('c1', 'split-cluster', 'cluster', 'big-72b'),
       group('h1', 'overnight-harvest', 'harvest', 'big-72b')],
      splits)

    expect(s).not.toBe(null)
    expect(s!.modelId).toBe('big-72b')
    expect(s!.machines).toBe(2)
    expect(s!.by.name).toBe('split-cluster')
    // Named, because the fleet view has to say which group lost the machine.
    expect(s!.from.map((g) => g.name)).toEqual(['overnight-harvest'])
  })

  it('leaves a machine alone when the model fits on one', () => {
    // The ordinary case, and by far the common one. A cluster group serving a
    // model that is not split preempts nobody and costs the harvest tier
    // nothing.
    expect(suspensionFor(
      node('n1', 'rotorua'),
      [group('c1', 'split-cluster', 'cluster', 'small-7b'),
       group('h1', 'overnight-harvest', 'harvest', 'small-7b')],
      splits)).toBe(null)
  })

  it('leaves a machine alone when its cluster group serves nothing', () => {
    expect(suspensionFor(
      node('n1', 'rotorua'),
      [group('c1', 'split-cluster', 'cluster', null),
       group('h1', 'overnight-harvest', 'harvest', null)],
      splits)).toBe(null)
  })

  it('does not suspend on account of a harvest group', () => {
    // A harvest group cannot serve half a model, so a split model named there
    // is not a reason to suspend anything - it is a different problem.
    expect(suspensionFor(
      node('n1', 'rotorua', { tier: 'harvest' }),
      [group('h1', 'overnight-harvest', 'harvest', 'big-72b')],
      splits)).toBe(null)
  })

  it('says so even for a machine in no harvest group', () => {
    // Nothing changes for that machine, but the fleet still reports what it is
    // doing, and a machine put into a harvest group tomorrow is accounted for.
    const s = suspensionFor(
      node('n1', 'rotorua'),
      [group('c1', 'split-cluster', 'cluster', 'big-72b')],
      splits)
    expect(s).not.toBe(null)
    expect(s!.from).toEqual([])
  })

  it('lists every machine a split takes out of harvesting', () => {
    // An N-way split costs N workstations, which is the number an operator is
    // trading away and therefore the number the fleet has to be able to state.
    const all = suspensions(
      [node('n1', 'rotorua'), node('n2', 'orca')],
      [group('c1', 'split-cluster', 'cluster', 'big-72b'),
       group('h1', 'overnight-harvest', 'harvest', 'big-72b')],
      splits)
    expect(all.map((s) => s.hostname).sort()).toEqual(['orca', 'rotorua'])
  })
})

describe('what an operator is told before they assign a split model', () => {
  it('names the cost in machines and groups', () => {
    const said = costOfServing('big-72b', 2,
      [node('n1', 'rotorua'), node('n2', 'orca')],
      [group('c1', 'split-cluster', 'cluster', 'big-72b'),
       group('h1', 'overnight-harvest', 'harvest', null)])

    expect(said).toContain('suspends 2 machines')
    expect(said).toContain('overnight-harvest')
    // And why, because the operator is trading capacity for a model that would
    // not otherwise run at all.
    expect(said).toContain('cannot be preempted')
  })

  it('says nothing when the model fits on one machine', () => {
    expect(costOfServing('small-7b', 1,
      [node('n1', 'rotorua')],
      [group('c1', 'split-cluster', 'cluster', null),
       group('h1', 'overnight-harvest', 'harvest', null)])).toBe('')
  })

  it('says nothing when no machine would lose harvest work', () => {
    // A dedicated cluster with nothing in a harvest group gives up nothing, and
    // warning about a cost that is not paid teaches an operator to skip the
    // warnings that matter.
    expect(costOfServing('big-72b', 2,
      [node('n1', 'rotorua')],
      [group('c1', 'split-cluster', 'cluster', 'big-72b')])).toBe('')
  })

  it('counts one machine as one', () => {
    const said = costOfServing('big-72b', 2, [node('n1', 'rotorua')],
      [group('c1', 'split-cluster', 'cluster', 'big-72b'),
       group('h1', 'overnight-harvest', 'harvest', null)])
    expect(said).toContain('suspends 1 machine from')
  })
})

/**
 * The same rule where it actually costs something: the lease path.
 *
 * A rule that is right in isolation and not consulted where work is handed out
 * is a rule the fleet does not have.
 */
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

describe('a machine holding part of a split model', () => {
  /** A harvest unit the seeded machine would otherwise be given. */
  async function waitingWork() {
    const r = await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'embed', items: [{ text: 'hello' }] }),
    })
    expect(r.status).toBe(201)
  }

  /** Put the machine in a cluster group that serves a two-machine model. */
  async function servingASplit() {
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines)
       VALUES ('big-72b', 'mlx', 'generate', 40000000000, 2)`)
    await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, serving_model_id)
       VALUES ('split-cluster', 'cluster', 'gang', 'never', 'big-72b')`)
    // A cluster group will not take a harvest-tier machine, so the machine has
    // to be in both tiers - which is the arrangement this whole rule is about.
    // `tier` is generated from `tiers`, so `tiers` is what gets written.
    await db.query(
      `UPDATE nodes SET tiers = ARRAY['harvest','cluster']::text[] WHERE id = $1`,
      [fx.nodeId])
  }

  it('is refused harvest work, and told why', async () => {
    await waitingWork()
    await setPresence(db, fx.nodeId, 'ABSENT')

    // Before: the machine takes the work, which is what makes the after
    // meaningful rather than a machine that was never going to get any.
    const before = await (await fetch(`${base}/agent/v1/work?kinds=embed`,
      { headers: asNode(fx.fingerprint) })).json() as any
    expect(before).toHaveProperty('unitId')

    await waitingWork()
    await servingASplit()

    const after = await (await fetch(`${base}/agent/v1/work?kinds=embed`,
      { headers: asNode(fx.fingerprint) })).json() as any
    // A reason rather than "empty": a node that is told there is no work looks
    // exactly like a fleet with nothing to do, and this is neither.
    expect(after).toEqual({ reason: 'holding-a-split' })
  })

  it('goes back to harvesting when the group stops serving it', async () => {
    // Suspended, not removed. The operator said this machine belongs to that
    // harvest group, and nothing here should make them say it twice.
    await servingASplit()
    await waitingWork()
    await setPresence(db, fx.nodeId, 'ABSENT')
    expect(await (await fetch(`${base}/agent/v1/work?kinds=embed`,
      { headers: asNode(fx.fingerprint) })).json()).toEqual({ reason: 'holding-a-split' })

    await db.query(`UPDATE pools SET serving_model_id = NULL WHERE tier = 'cluster'`)

    const back = await (await fetch(`${base}/agent/v1/work?kinds=embed`,
      { headers: asNode(fx.fingerprint) })).json() as any
    expect(back).toHaveProperty('unitId')
  })

  it('still takes work from the cluster group that is running the split', async () => {
    // Only the harvest promise is withdrawn. The cluster group's own work is
    // gang scheduled and never preempted, so it is coordinated with the split
    // rather than competing with it.
    await servingASplit()
    await setPresence(db, fx.nodeId, 'ABSENT')
    const cluster = await db.query(`SELECT id FROM pools WHERE tier = 'cluster'`)
    // Submitting to a group needs a role in it, which the seeded operator has
    // on the seeded pool and not on one this test invented.
    await db.query(
      `INSERT INTO role_bindings (group_id, pool_id, role)
       SELECT group_id, $1, 'operator' FROM role_bindings LIMIT 1`,
      [cluster.rows[0].id])
    const r = await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ poolId: cluster.rows[0].id, kind: 'embed',
                             items: [{ text: 'hello' }] }),
    })
    expect(r.status).toBe(201)

    const got = await (await fetch(`${base}/agent/v1/work?kinds=embed`,
      { headers: asNode(fx.fingerprint) })).json() as any
    expect(got).toHaveProperty('unitId')
  })
})

describe('assigning a split model to a group', () => {
  async function splitModel() {
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines, min_memory_gb)
       VALUES ('big-72b', 'mlx', 'generate', 40000000000, 2, 10)`)
    const p = await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt)
       VALUES ('split-cluster', 'cluster', 'gang', 'never') RETURNING id`)
    await db.query(
      `UPDATE nodes SET tiers = ARRAY['harvest','cluster']::text[],
                        metal_working_set_gb = 51.8 WHERE id = $1`, [fx.nodeId])
    // A two-machine model needs two machines before anything else is asked, so
    // the group has to be able to run it for the question of what it costs to
    // arise at all.
    await db.query(
      `INSERT INTO nodes (hostname, chip, memory_gb, metal_working_set_gb, state,
                          cert_fingerprint, presence_state, tiers)
       VALUES ('orca','Apple M4 Pro',48,38.0,'active','fp-node-2','LOCKED',
               ARRAY['harvest','cluster']::text[])`)
    await db.query(
      `INSERT INTO role_bindings (group_id, pool_id, role)
       SELECT group_id, $1, 'admin' FROM role_bindings LIMIT 1`, [p.rows[0].id])
    return p.rows[0].id as string
  }

  it('says what it will cost before it does it', async () => {
    const poolId = await splitModel()
    const r = await fetch(`${base}/admin/v1/pools/${poolId}/serving-model`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ modelId: 'big-72b' }),
    })
    const body = await r.json() as any
    expect(r.status).toBe(409)
    expect(body.error).toBe('confirm_required')
    // The number of machines and the group losing them, because that is what
    // the operator is trading and they cannot weigh it otherwise.
    expect(body.detail).toContain('suspends 2 machines')
    expect(body.detail).toContain('overnight-harvest')

    // And nothing happened.
    const after = await db.query(
      `SELECT serving_model_id FROM pools WHERE id = $1`, [poolId])
    expect(after.rows[0].serving_model_id).toBe(null)
  })

  it('goes ahead once the cost has been accepted', async () => {
    const poolId = await splitModel()
    const r = await fetch(`${base}/admin/v1/pools/${poolId}/serving-model`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ modelId: 'big-72b', confirm: true }),
    })
    expect(r.status).toBe(204)
    const after = await db.query(
      `SELECT serving_model_id FROM pools WHERE id = $1`, [poolId])
    expect(after.rows[0].serving_model_id).toBe('big-72b')
  })

  it('does not ask about a model that fits on one machine', async () => {
    // The common case. A confirmation nobody needs is one everybody learns to
    // click through, including on the day it matters.
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines)
       VALUES ('small-7b', 'mlx', 'generate', 4000000000, 1)`)
    const r = await fetch(`${base}/admin/v1/pools/${fx.poolId}/serving-model`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ modelId: 'small-7b' }),
    })
    expect(r.status).toBe(204)
  })
})
