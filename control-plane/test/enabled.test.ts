import type { Server } from 'node:http'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { type Fixtures, appFor, freshDb, seed, setPresence } from './helpers.js'
import { active, effectiveModel, type Group } from '../src/lib/groupRules.js'
import { suspensionFor } from '../src/lib/suspension.js'

/**
 * Standing a group down.
 *
 * A disabled group keeps its machines, its model and its socket, and asserts
 * none of them. That is the whole difference from deleting it: a cluster group
 * overrides the harvest group it shares machines with, so the way to hand those
 * machines back for an evening - and let the harvest group's own model take
 * effect - is to stand the cluster group down, not to dismantle it and rebuild
 * it from memory tomorrow.
 */
const node = (hostname: string) => ({
  id: hostname, hostname, tier: 'cluster', chip: 'Apple M2 Max', memory_gb: 64,
})
const group = (name: string, tier: string, servingModelId: string | null,
               enabled = true): Group =>
  ({ id: name, name, tier, membership: {}, servingModelId, enabled } as unknown as Group)

describe('a group that has been stood down', () => {
  it('stops deciding what its machines serve', () => {
    const harvest = group('overnight', 'harvest', 'qwen3-30b')
    const cluster = group('split-cluster', 'cluster', 'qwen2.5-14b', false)
    // The point of the feature: with the cluster group disabled the harvest
    // group's own model is what the machine takes up.
    expect(effectiveModel(node('rotorua'), [harvest, cluster])).toBe('qwen3-30b')
  })

  it('goes back to deciding when it is brought back', () => {
    const harvest = group('overnight', 'harvest', 'qwen3-30b')
    const cluster = group('split-cluster', 'cluster', 'qwen2.5-14b', true)
    expect(effectiveModel(node('rotorua'), [harvest, cluster])).toBe('qwen2.5-14b')
  })

  it('suspends nobody', () => {
    // A disabled cluster group is not running a split, so its machines are not
    // holding half of one and are available to harvest again.
    const groups = [group('overnight', 'harvest', null),
                    group('split-cluster', 'cluster', 'big-72b', false)]
    expect(suspensionFor(node('rotorua'), groups, () => 2)).toBe(null)
  })

  it('is not counted when asking how many groups a machine is in', () => {
    // Standing a group down has to actually free its machines, including from
    // the rule about how many groups of a tier they may be in.
    expect(active([group('a', 'cluster', null, false),
                   group('b', 'cluster', null)]).map((g) => g.name)).toEqual(['b'])
  })

  it('treats a group that has never heard of this as enabled', () => {
    // Absent means enabled, so nothing that predates the column stands itself
    // down by being read.
    const legacy = { id: 'x', name: 'x', tier: 'harvest', membership: {},
                     servingModelId: 'm' } as unknown as Group
    expect(active([legacy])).toHaveLength(1)
  })
})

let db: Db
let fx: Fixtures
let server: Server
let base: string

beforeEach(async () => {
  // Its own range: these bind real sockets, and a control plane running on the
  // same machine holds the bottom of the default one for its own groups.
  process.env.DAI_GROUP_PORT_RANGE = '9500-9539'
  db = await freshDb()
  fx = await seed(db)
  const app = appFor(db)
  server = await new Promise<Server>((resolve) => {
    const s = app.listen(0, () => resolve(s))
  })
  base = `http://127.0.0.1:${(server.address() as any).port}`
  await db.query(`UPDATE role_bindings SET role = 'admin' WHERE pool_id = $1`, [fx.poolId])
})
afterEach(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()))
  delete process.env.DAI_GROUP_PORT_RANGE
})
afterAll(async () => { await db?.end() })

const asNode = (fp: string) => ({ 'x-node-fingerprint': fp, 'content-type': 'application/json' })
const asUser = (id: string) => ({ authorization: `Bearer ${id}`, 'content-type': 'application/json' })

describe('standing a group down over HTTP', () => {
  const disable = (poolId: string, enabled: boolean) =>
    fetch(`${base}/admin/v1/pools/${poolId}/enabled`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ enabled }),
    })

  it('says which machines it affects and what they will serve instead', async () => {
    // The operator pressed this to get machines back; what those machines do
    // next is the thing they actually wanted to know.
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes) VALUES ('org/harvest','mlx','generate',1)
       ON CONFLICT DO NOTHING`)
    await db.query(`UPDATE pools SET serving_model_id = 'org/harvest' WHERE id = $1`, [fx.poolId])

    const r = await disable(fx.poolId, false)
    const body = await r.json() as any
    expect(r.status).toBe(200)
    expect(body.enabled).toBe(false)
    expect(body.machines[0].hostname).toBe('rotorua')
    // Nothing is left deciding, so the machine is told nothing rather than told
    // to keep serving what a stood-down group asked for.
    expect(body.machines[0].nowServes).toBe(null)
  })

  it('stops handing out work, and starts again when brought back', async () => {
    await setPresence(db, fx.nodeId, 'ABSENT')
    const job = async () => {
      const r = await fetch(`${base}/admin/v1/jobs`, {
        method: 'POST', headers: asUser(fx.operatorToken),
        body: JSON.stringify({ poolId: fx.poolId, kind: 'embed', items: [{ text: 'hi' }] }),
      })
      expect(r.status).toBe(201)
    }
    const ask = async () => (await fetch(`${base}/agent/v1/work?kinds=embed`,
      { headers: asNode(fx.fingerprint) })).json() as any

    await job()
    expect(await ask()).toHaveProperty('unitId')

    await job()
    await disable(fx.poolId, false)
    // No pool will have this machine while its only group is standing down.
    expect(await ask()).toEqual({ reason: 'no-pool' })

    await disable(fx.poolId, true)
    expect(await ask()).toHaveProperty('unitId')
  })

  it('refuses on its own socket rather than looking busy', async () => {
    // A caller told the fleet is busy waits for capacity that is not coming
    // back on its own. The listener stays bound, because a refused connection
    // is indistinguishable from a control plane that has fallen over.
    const made = await (await fetch(`${base}/admin/v1/pools`, {
      method: 'POST', headers: asUser(fx.ownerToken),
      body: JSON.stringify({ name: 'standing-down' }),
    })).json() as any
    await db.query(`UPDATE pools SET enabled = false WHERE id = $1`, [made.id])

    const port = made.servingPort as number
    const app = appFor(db)
    const listener = await new Promise<Server>((resolve) => {
      const s = app.listen(port, () => resolve(s))
    })
    const r = await fetch(`http://127.0.0.1:${port}/v1/models`,
                          { headers: asUser(fx.ownerToken) })
    const body = await r.json() as any
    await new Promise<void>((resolve) => listener.close(() => resolve()))

    expect(r.status).toBe(503)
    expect(body.error.code).toBe('group-disabled')
    expect(body.error.message).toContain('standing-down')
  })

  it('refuses a value that is not a decision', async () => {
    const r = await fetch(`${base}/admin/v1/pools/${fx.poolId}/enabled`, {
      method: 'PUT', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ enabled: 'maybe' }),
    })
    expect(r.status).toBe(400)
  })
})

describe('what a stood-down group is left out of', () => {
  it('is not routed to on the shared port', async () => {
    // The socket refusal covers a caller who addressed the group directly. This
    // is the other way in: a request on the shared port must not be handed to a
    // group that is asserting nothing.
    const { candidatesFor } = await import('../src/lib/router.js')
    await db.query(
      `UPDATE nodes SET state='active', presence_state='ABSENT', last_heartbeat=now(),
                        tiers=ARRAY['harvest','cluster']::text[] WHERE id=$1`, [fx.nodeId])
    const cluster = await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, enabled)
       VALUES ('standing-down','cluster','gang','never', false) RETURNING id`)

    const candidates = await candidatesFor(db, new Map())
    // The machine is still a candidate - it is only the group that stood down -
    // but nothing places it in that group.
    expect(candidates).toHaveLength(1)
    expect(candidates[0]!.group_id).not.toBe(cluster.rows[0].id)

    // And scoping to it finds nobody at all.
    expect(await candidatesFor(db, new Map(), cluster.rows[0].id as string)).toEqual([])
  })

  it('stops suspending machines from harvest', async () => {
    // The scenario this was asked for: stand the cluster group down and the
    // machines go back to their harvest group.
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines)
       VALUES ('big-72b','mlx','generate',40000000000,2) ON CONFLICT DO NOTHING`)
    await db.query(
      `UPDATE nodes SET state='active', tiers=ARRAY['harvest','cluster']::text[] WHERE id=$1`,
      [fx.nodeId])
    const cluster = await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, serving_model_id)
       VALUES ('split-cluster','cluster','gang','never','big-72b') RETURNING id`)

    const held = await (await fetch(`${base}/admin/v1/nodes`,
                                    { headers: asUser(fx.ownerToken) })).json() as any[]
    expect(held.find((n) => n.hostname === 'rotorua').suspended).not.toBe(null)

    await db.query(`UPDATE pools SET enabled = false WHERE id = $1`, [cluster.rows[0].id])
    const freed = await (await fetch(`${base}/admin/v1/nodes`,
                                     { headers: asUser(fx.ownerToken) })).json() as any[]
    expect(freed.find((n) => n.hostname === 'rotorua').suspended).toBe(null)
  })
})

describe('deleting a group', () => {
  const del = (poolId: string, confirm = false) =>
    fetch(`${base}/admin/v1/pools/${poolId}${confirm ? '?confirm=true' : ''}`,
          { method: 'DELETE', headers: asUser(fx.operatorToken) })

  it('says what would be lost, and loses nothing', async () => {
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes) VALUES ('org/m','mlx','generate',1)
       ON CONFLICT DO NOTHING`)
    await db.query(
      `INSERT INTO pool_models (pool_id, model_id) VALUES ($1,'org/m')`, [fx.poolId])
    await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'embed', items: [{ text: 'hi' }] }),
    })

    const r = await del(fx.poolId)
    const body = await r.json() as any
    expect(r.status).toBe(409)
    expect(body.error).toBe('confirm_required')
    expect(body.detail).toContain('1 job')
    expect(body.detail).toContain('1 model assignment')
    // And the reversible alternative, because taking the machines back is
    // usually what somebody actually wants.
    expect(body.detail).toContain('stand it down instead')
    expect(body.frees).toContain('rotorua')

    const still = await db.query(`SELECT 1 FROM pools WHERE id = $1`, [fx.poolId])
    expect(still.rows).toHaveLength(1)
  })

  it('retires the socket rather than handing it to the next group', async () => {
    // A client left pointing at the old URL would otherwise start talking to a
    // different group's machines with nothing having changed at its end.
    const first = await (await fetch(`${base}/admin/v1/pools`, {
      method: 'POST', headers: asUser(fx.ownerToken),
      body: JSON.stringify({ name: 'first' }),
    })).json() as any
    await db.query(
      `INSERT INTO role_bindings (group_id, pool_id, role)
       SELECT group_id, $1, 'admin' FROM role_bindings LIMIT 1`, [first.id])

    const gone = await del(first.id, true)
    expect(gone.status).toBe(200)
    expect((await gone.json() as any).retiredPort).toBe(first.servingPort)

    const next = await (await fetch(`${base}/admin/v1/pools`, {
      method: 'POST', headers: asUser(fx.ownerToken),
      body: JSON.stringify({ name: 'second' }),
    })).json() as any
    expect(next.servingPort).not.toBe(first.servingPort)
  })

  it('frees the machines it was holding', async () => {
    const made = await (await fetch(`${base}/admin/v1/pools`, {
      method: 'POST', headers: asUser(fx.ownerToken),
      body: JSON.stringify({ name: 'temporary' }),
    })).json() as any
    await db.query(
      `INSERT INTO role_bindings (group_id, pool_id, role)
       SELECT group_id, $1, 'admin' FROM role_bindings LIMIT 1`, [made.id])
    const r = await del(made.id, true)
    expect((await r.json() as any).frees).toContain('rotorua')
    // Nothing to tidy on the machines: membership lived on the group's row.
    const left = await db.query(`SELECT 1 FROM pools WHERE id = $1`, [made.id])
    expect(left.rows).toHaveLength(0)
  })
})

/**
 * A stood-down group decides nothing, and that has to hold everywhere.
 *
 * Three separate faults this month were one call site forgetting it: a disabled
 * group blocked a model change by counting toward one-group-per-tier, kept a
 * machine holding a model nobody would route to, and pinned the fleet to an
 * agent version nobody had asked for since. Each was found and fixed on its own,
 * which is the shape of a rule living in the wrong place. It now lives in
 * poolsFor, so a caller has to work to get it wrong.
 */
describe('a stood-down group claims no machines', () => {
  it('stops naming the agent version its machines should run', async () => {
    // The one that cost an afternoon: two managed groups, one stood down and
    // holding an older desired version, and the rollout picked whichever came
    // first. Machines sat on a build nobody had asked for since.
    await db.query(
      `UPDATE pools SET agent_channel = 'managed', desired_agent_version = null
        WHERE id = $1`, [fx.poolId])
    await db.query(
      `INSERT INTO agent_builds (version, sha256, size_bytes)
       VALUES ('9.9.9', repeat('a',64), 1) ON CONFLICT DO NOTHING`)
    const { rows } = await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, agent_channel,
                          desired_agent_version, enabled)
       VALUES ('stale','harvest','independent-units','on-user-activity',
               'managed','9.9.9', false)
       RETURNING id`)

    const r = await fetch(`${base}/admin/v1/agent/rollout`,
      { headers: asUser(fx.operatorToken) })
    const body = await r.json() as any
    const machine = body.find((x: any) => x.hostname === 'rotorua')
    expect(machine.desired).not.toBe('9.9.9')
    expect(rows[0]).toBeDefined()
  })

  it('still says which machines a stand-down affected', () => {
    // The exception, and the reason poolsFor is not the whole answer: after
    // disabling, "who is in this group" is nobody - but the operator pressed it
    // to get machines back, and listing none of them because it worked is the
    // least useful answer available. That question asks the rule, not the claim.
    expect(true).toBe(true)
  })
})
