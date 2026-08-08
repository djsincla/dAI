import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { LeaseConflict, leaseWork, reapExpiredLeases, reportResult } from '../src/lib/work.js'
import { filterRequestedKinds, permittedKinds } from '../src/lib/policy.js'
import { type Fixtures, freshDb, seed, setPresence, submitJob } from './helpers.js'

let db: Db
let fx: Fixtures

beforeEach(async () => {
  db = await freshDb()
  fx = await seed(db)
})
afterAll(async () => { await db?.end() })

async function node(overrides: Partial<Record<string, unknown>> = {}) {
  const { rows } = await db.query(
    `SELECT id, state, presence_state, paused_until FROM nodes WHERE id=$1`, [fx.nodeId])
  return { ...rows[0], ...overrides } as any
}

describe('lease expiry', () => {
  /**
   * The gap that made the spike coordinator lose work: it held in-flight units
   * in memory with no timeout, so a node dropping off the network stranded them
   * permanently. Observed live when a laptop went flat mid-run.
   */
  it('returns work from a node that vanished', async () => {
    await submitJob(db, fx.poolId, 'generate', 8)
    const lease = await leaseWork(db, await node(), ['generate'])
    expect(lease).toHaveProperty('unitId')

    // Node disappears. Nothing is reported, ever.
    await db.query(`UPDATE work_units SET lease_expires_at = now() - interval '1 second'
                     WHERE state='leased'`)

    expect(await reapExpiredLeases(db)).toBe(1)
    const again = await leaseWork(db, await node(), ['generate'])
    expect(again).toHaveProperty('unitId')
  })

  it('does not reap a lease that is still live', async () => {
    await submitJob(db, fx.poolId, 'generate', 8)
    await leaseWork(db, await node(), ['generate'])
    expect(await reapExpiredLeases(db)).toBe(0)
  })

  it('fails a unit that has exhausted its attempts rather than cycling forever', async () => {
    await submitJob(db, fx.poolId, 'generate', 8)
    for (let i = 0; i < 3; i++) {
      await leaseWork(db, await node(), ['generate'])
      await db.query(`UPDATE work_units SET lease_expires_at = now() - interval '1s'
                       WHERE state='leased'`)
      await reapExpiredLeases(db)
    }
    const { rows } = await db.query(`SELECT state, attempts FROM work_units`)
    expect(rows[0].state).toBe('failed')
  })

  it('rejects a late result from a node whose lease was reaped', async () => {
    await submitJob(db, fx.poolId, 'generate', 8)
    const lease = (await leaseWork(db, await node(), ['generate'])) as any
    await db.query(`UPDATE work_units SET lease_expires_at = now() - interval '1s'`)
    await reapExpiredLeases(db)

    // Without this check the vanished node's result would double-count against
    // a unit another node has since taken.
    await expect(
      reportResult(db, fx.nodeId, lease.unitId, { completed: [], seconds: 1 }),
    ).rejects.toBeInstanceOf(LeaseConflict)
  })
})

describe('kind negotiation', () => {
  it('never dispatches GPU work to a node with a user present', async () => {
    await submitJob(db, fx.poolId, 'generate', 8)
    for (const state of ['ACTIVE', 'PASSIVE', 'IDLE']) {
      await setPresence(db, fx.nodeId, state)
      const out = await leaseWork(db, await node(), ['generate'])
      expect(out, `state ${state}`).toEqual({ reason: 'none-of-these-kinds' })
    }
  })

  it('dispatches GPU work once the machine is locked', async () => {
    await submitJob(db, fx.poolId, 'generate', 8)
    await setPresence(db, fx.nodeId, 'LOCKED')
    expect(await leaseWork(db, await node(), ['generate'])).toHaveProperty('unitId')
  })

  it('serves ANE work in every presence state', async () => {
    await submitJob(db, fx.poolId, 'embed', 40)
    for (const state of ['ACTIVE', 'PASSIVE', 'IDLE', 'LOCKED', 'ABSENT']) {
      await setPresence(db, fx.nodeId, state)
      expect(await leaseWork(db, await node(), ['embed']), `state ${state}`)
        .toHaveProperty('unitId')
    }
  })

  it('ignores a kind the node asks for but its state forbids', async () => {
    // A buggy or compromised agent must not be able to talk the scheduler into
    // dispatching GPU work to a machine someone is using.
    await submitJob(db, fx.poolId, 'generate', 8)
    await setPresence(db, fx.nodeId, 'ACTIVE')
    expect(await leaseWork(db, await node(), ['embed', 'generate', 'render']))
      .toEqual({ reason: 'none-of-these-kinds' })
  })

  it('fails closed when presence is unknown', async () => {
    await submitJob(db, fx.poolId, 'generate', 8)
    await db.query(`UPDATE nodes SET presence_state = NULL WHERE id=$1`, [fx.nodeId])
    expect(await leaseWork(db, await node(), ['generate']))
      .toEqual({ reason: 'none-of-these-kinds' })
  })

  it('distinguishes an empty queue from an unservable one', async () => {
    await setPresence(db, fx.nodeId, 'LOCKED')
    expect(await leaseWork(db, await node(), ['generate'])).toEqual({ reason: 'empty' })
  })

  it('refuses work to a paused node regardless of state', async () => {
    await submitJob(db, fx.poolId, 'embed', 8)
    await db.query(`UPDATE nodes SET state='paused' WHERE id=$1`, [fx.nodeId])
    expect(await leaseWork(db, await node(), ['embed'])).toEqual({ reason: 'node-paused' })
  })
})

describe('partial results', () => {
  /**
   * A harvest agent yields between items, not between units, and hands back
   * what it did not reach. Without this a yield costs a whole batch, which is
   * the expense E4's economics exist to avoid.
   */
  it('requeues the remainder at the head of the queue', async () => {
    await submitJob(db, fx.poolId, 'embed', 24, 8)
    const lease = (await leaseWork(db, await node(), ['embed'])) as any
    expect(lease.items).toHaveLength(8)

    const out = await reportResult(db, fx.nodeId, lease.unitId, {
      completed: lease.items.slice(0, 2),
      unfinished: lease.items.slice(2),
      seconds: 1.5,
    })
    expect(out.requeued).toBe(6)

    // The remainder comes back next, ahead of the untouched batches.
    const next = (await leaseWork(db, await node(), ['embed'])) as any
    expect(next.items).toHaveLength(6)
    expect((next.items[0] as any).id).toBe(2)
  })

  it('completes the job only when nothing is pending or leased', async () => {
    const jobId = await submitJob(db, fx.poolId, 'embed', 8, 8)
    const lease = (await leaseWork(db, await node(), ['embed'])) as any
    await reportResult(db, fx.nodeId, lease.unitId, {
      completed: lease.items, seconds: 1,
    })
    const { rows } = await db.query(`SELECT state FROM jobs WHERE id=$1`, [jobId])
    expect(rows[0].state).toBe('complete')
  })

  it('leaves the job running while a remainder is outstanding', async () => {
    const jobId = await submitJob(db, fx.poolId, 'embed', 8, 8)
    const lease = (await leaseWork(db, await node(), ['embed'])) as any
    await reportResult(db, fx.nodeId, lease.unitId, {
      completed: lease.items.slice(0, 1), unfinished: lease.items.slice(1), seconds: 1,
    })
    const { rows } = await db.query(`SELECT state FROM jobs WHERE id=$1`, [jobId])
    expect(rows[0].state).toBe('running')
  })
})

describe('concurrent dispatch', () => {
  it('never hands the same unit to two nodes', async () => {
    await submitJob(db, fx.poolId, 'embed', 80, 8)
    await db.query(
      `INSERT INTO nodes (hostname, state, cert_fingerprint, presence_state)
       VALUES ('orca','active','fp-node-2','LOCKED')`,
    )
    const { rows } = await db.query(
      `SELECT id, state, presence_state, paused_until FROM nodes ORDER BY hostname`)

    const leases = await Promise.all(
      Array.from({ length: 10 }, (_, i) => leaseWork(db, rows[i % 2] as any, ['embed'])),
    )
    const ids = leases.filter((l): l is any => 'unitId' in l).map((l) => l.unitId)
    expect(new Set(ids).size).toBe(ids.length)
  })
})

describe('policy table', () => {
  it('permits ANE everywhere and GPU only when unobserved', () => {
    for (const s of ['ACTIVE', 'PASSIVE', 'IDLE'] as const) {
      expect(permittedKinds(s)).toEqual(['embed'])
    }
    for (const s of ['LOCKED', 'ABSENT'] as const) {
      expect(permittedKinds(s)).toContain('generate')
      expect(permittedKinds(s)).toContain('render')
    }
  })

  it('treats render exactly like generate, since both are GPU work', () => {
    expect(filterRequestedKinds('IDLE', ['render'])).toEqual([])
    expect(filterRequestedKinds('ABSENT', ['render'])).toEqual(['render'])
  })
})
