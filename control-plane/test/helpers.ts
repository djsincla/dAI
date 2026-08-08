import type { Express } from 'express'
import { createPool, type Db, reset } from '../src/lib/db.js'
import { createApp } from '../src/server.js'

export const DATABASE_URL =
  process.env.DATABASE_URL ?? 'postgres://dai:dai@localhost:5433/dai'

/**
 * A real Postgres, not a mock. The behaviour under test is mostly concurrency
 * and expiry semantics, which a fake would model incorrectly in exactly the
 * places that matter.
 */
export async function freshDb(): Promise<Db> {
  const db = createPool(DATABASE_URL)
  await reset(db)
  return db
}

export function appFor(db: Db): Express {
  process.env.DAI_TRUST_FINGERPRINT_HEADER = '1'
  return createApp(db)
}

export interface Fixtures {
  poolId: string
  ownerId: string
  operatorId: string
  strangerId: string
  nodeId: string
  fingerprint: string
}

/** A fleet with one pool, one node, and three people with different standing. */
export async function seed(db: Db): Promise<Fixtures> {
  const pool = await db.query(
    `INSERT INTO pools (name, tier, schedule, preempt)
     VALUES ('overnight-harvest','harvest','independent-units','on-user-activity')
     RETURNING id`,
  )
  const poolId = pool.rows[0].id as string

  const mk = async (email: string) =>
    (await db.query(`INSERT INTO users (email) VALUES ($1) RETURNING id`, [email])).rows[0]
      .id as string
  const ownerId = await mk('owner@example.com')
  const operatorId = await mk('operator@example.com')
  const strangerId = await mk('stranger@example.com')

  const grp = await db.query(`INSERT INTO groups (name) VALUES ('wranglers') RETURNING id`)
  const groupId = grp.rows[0].id as string
  await db.query(`INSERT INTO group_members (group_id, user_id) VALUES ($1,$2)`, [
    groupId, operatorId,
  ])
  await db.query(`INSERT INTO role_bindings (group_id, pool_id, role) VALUES ($1,$2,'operator')`, [
    groupId, poolId,
  ])

  const fingerprint = 'fp-node-1'
  const node = await db.query(
    `INSERT INTO nodes (hostname, chip, memory_gb, metal_working_set_gb, state,
                        cert_fingerprint, owner_user_id, presence_state)
     VALUES ('rotorua','Apple M2 Max',64,51.8,'active',$1,$2,'LOCKED')
     RETURNING id`,
    [fingerprint, ownerId],
  )

  return { poolId, ownerId, operatorId, strangerId, nodeId: node.rows[0].id, fingerprint }
}

export async function setPresence(db: Db, nodeId: string, state: string): Promise<void> {
  await db.query(`UPDATE nodes SET presence_state = $2 WHERE id = $1`, [nodeId, state])
}

export async function submitJob(
  db: Db,
  poolId: string,
  kind: string,
  count: number,
  batchSize = 8,
): Promise<string> {
  const job = await db.query(
    `INSERT INTO jobs (pool_id, kind) VALUES ($1,$2) RETURNING id`, [poolId, kind])
  const jobId = job.rows[0].id as string
  let position = 0
  for (let i = 0; i < count; i += batchSize) {
    const items = Array.from({ length: Math.min(batchSize, count - i) }, (_, k) => ({
      id: i + k,
      prompt: `item ${i + k}`,
    }))
    await db.query(
      `INSERT INTO work_units (job_id, kind, payload, position) VALUES ($1,$2,$3,$4)`,
      [jobId, kind, JSON.stringify(items), position],
    )
    position += 1000
  }
  return jobId
}
