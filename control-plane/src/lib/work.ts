import type pg from 'pg'
import { type Db, tx } from './db.js'
import { filterRequestedKinds, type PresenceState, type WorkKind } from './policy.js'
import { poolsFor, type PoolSpec } from './pools.js'

/**
 * Lease duration. Sized from E4: model load is 1-3s and a harvest work unit is
 * seconds to minutes, so a lease only has to outlive a unit plus slack. Short
 * leases return work from a vanished node quickly, which is the failure the
 * spike coordinator could not recover from at all.
 */
export const LEASE_SECONDS = 120

/** A unit failing on every node is a broken payload, not an unlucky one. */
export const MAX_ATTEMPTS = 3

export interface Lease {
  unitId: string
  kind: WorkKind
  modelHash: string | null
  /// The scene a render unit belongs to.
  ///
  /// Carried on the lease rather than in the payload, so a unit cannot name the
  /// content it wants. A node renders the scene the job says, at the frame the
  /// item says, and the two come from different places on purpose.
  sceneId: string | null
  /// Which job this unit belongs to, so a node can ask what content the job
  /// needs and, when the job ends, know what it may delete.
  jobId: string
  items: unknown[]
  leaseExpiresAt: string
  /// What this work is and where it came from, carried down to the node.
  ///
  /// The machine's owner is entitled to know what their hardware is doing, and
  /// "embed" is not an answer. It also makes synthetic work visible as
  /// synthetic on the machine running it, rather than only in the console of
  /// whoever submitted it.
  jobLabel: string | null
  jobSource: string
}

export type NoWorkReason = 'empty' | 'none-of-these-kinds' | 'node-paused' | 'user-paused'
  | 'no-pool'

/**
 * Lease one unit for a node.
 *
 * FOR UPDATE SKIP LOCKED is the load-bearing detail: two nodes polling at the
 * same instant must not be handed the same unit, and a node must not block
 * waiting for a row another node is already taking.
 */
export async function leaseWork(
  db: Db,
  node: {
    id: string; state: string; presence_state: string | null
    paused_until: Date | null; user_paused?: boolean
    // Pool membership is decided from these, so they travel with the node
    // rather than being re-read per lease.
    tier: string; hostname: string; chip: string | null
    memory_gb: string | number | null
  },
  requested: WorkKind[],
): Promise<Lease | { reason: NoWorkReason }> {
  // Checked before the administrative pause and reported separately, because
  // the two are not the same thing and an operator looking at an idle machine
  // needs to know which one is in force. This one they cannot lift.
  if (node.user_paused) return { reason: 'user-paused' }
  if (node.state === 'paused' || (node.paused_until && node.paused_until > new Date())) {
    return { reason: 'node-paused' }
  }

  const kinds = filterRequestedKinds(node.presence_state as PresenceState | null, requested)
  if (kinds.length === 0) return { reason: 'none-of-these-kinds' }

  // Pool membership decided here, in one place, and handed to SQL as a list of
  // ids. Writing the same rule again as a SQL predicate would be two
  // implementations of one policy, and the copy that drifts is the one deciding
  // whether gang work lands on a preemptible machine.
  const { rows: allPools } = await db.query(`SELECT id, tier, membership FROM pools`)
  const eligible = poolsFor(node, allPools as PoolSpec[]).map((p) => p.id)
  if (eligible.length === 0) return { reason: 'no-pool' }

  return tx(db, async (c: pg.PoolClient) => {
    const { rows } = await c.query(
      `SELECT u.id, u.job_id, u.kind, u.payload, j.model_hash, j.scene_id, j.label, j.source
         FROM work_units u
         JOIN jobs j ON j.id = u.job_id
        WHERE u.state = 'pending'
          AND u.kind = ANY($1::text[])
          AND u.attempts < $2
          AND j.pool_id = ANY($3::uuid[])
        ORDER BY u.position
        LIMIT 1
        FOR UPDATE OF u SKIP LOCKED`,
      [kinds, MAX_ATTEMPTS, eligible],
    )
    const row = rows[0]
    if (!row) {
      const { rows: elsewhere } = await c.query(
        `SELECT u.kind, j.pool_id FROM work_units u JOIN jobs j ON j.id = u.job_id
          WHERE u.state = 'pending' LIMIT 1`,
      )
      if (elsewhere.length === 0) return { reason: 'empty' as const }
      // There is work, but not for this node. Which of the two reasons applies
      // decides whether an operator looks at the node or at the pool.
      const barred = !eligible.includes(elsewhere[0]!.pool_id as string)
      return { reason: barred ? ('no-pool' as const) : ('none-of-these-kinds' as const) }
    }

    const { rows: leased } = await c.query(
      `UPDATE work_units
          SET state = 'leased',
              lease_node_id = $1,
              lease_expires_at = now() + ($2 || ' seconds')::interval,
              attempts = attempts + 1
        WHERE id = $3
      RETURNING lease_expires_at`,
      [node.id, LEASE_SECONDS, row.id],
    )
    await c.query(`UPDATE jobs SET state = 'running' WHERE id = (
                     SELECT job_id FROM work_units WHERE id = $1) AND state = 'pending'`, [row.id])

    return {
      unitId: row.id as string,
      kind: row.kind as WorkKind,
      modelHash: (row.model_hash as string | null) ?? null,
      sceneId: (row.scene_id as string | null) ?? null,
      jobId: row.job_id as string,
      items: row.payload as unknown[],
      leaseExpiresAt: (leased[0]!.lease_expires_at as Date).toISOString(),
      jobLabel: (row.label as string | null) ?? null,
      jobSource: (row.source as string) ?? 'api',
    }
  })
}

export class LeaseConflict extends Error {}

/**
 * Record a result and requeue whatever the agent did not reach.
 *
 * The lease is checked inside the transaction, so a node whose lease already
 * expired and was reaped cannot double-count its work against a unit another
 * node has since taken.
 */
export async function reportResult(
  db: Db,
  nodeId: string,
  unitId: string,
  body: { completed: unknown[]; unfinished?: unknown[]; seconds: number; failed?: boolean },
): Promise<{ requeued: number }> {
  return tx(db, async (c: pg.PoolClient) => {
    const { rows } = await c.query(
      `SELECT id, job_id, kind, lease_node_id, state, attempts, position
         FROM work_units WHERE id = $1 FOR UPDATE`,
      [unitId],
    )
    const unit = rows[0]
    if (!unit) throw new LeaseConflict('no such unit')
    if (unit.state !== 'leased' || unit.lease_node_id !== nodeId) {
      throw new LeaseConflict('lease expired or held by another node')
    }

    const unfinished = body.unfinished ?? []
    const failed = body.failed === true

    if (failed && unit.attempts >= MAX_ATTEMPTS) {
      // Poison detection: stop cycling and say so, rather than retrying forever.
      await c.query(`UPDATE work_units SET state='failed', lease_node_id=NULL,
                       lease_expires_at=NULL WHERE id=$1`, [unitId])
    } else if (failed) {
      await c.query(`UPDATE work_units SET state='pending', lease_node_id=NULL,
                       lease_expires_at=NULL WHERE id=$1`, [unitId])
    } else {
      await c.query(
        `UPDATE work_units
            SET state='done', result=$1, completed_by=$3,
                lease_node_id=NULL, lease_expires_at=NULL
          WHERE id=$2`,
        [JSON.stringify({ completed: body.completed, seconds: body.seconds }),
         unitId, nodeId],
      )
    }

    if (unfinished.length > 0) {
      // Requeue at the head so a partially served unit is not stranded behind
      // the whole backlog. attempts starts at 0: the remainder was never tried.
      await c.query(
        `INSERT INTO work_units (job_id, kind, payload, position)
         VALUES ($1, $2, $3,
                 COALESCE((SELECT MIN(position) FROM work_units
                            WHERE job_id = $1 AND state = 'pending'), $4) - 1)`,
        [unit.job_id, unit.kind, JSON.stringify(unfinished), unit.position],
      )
    }

    await c.query(
      `UPDATE jobs SET state = 'complete'
        WHERE id = $1
          AND NOT EXISTS (SELECT 1 FROM work_units
                           WHERE job_id = $1 AND state IN ('pending','leased'))`,
      [unit.job_id],
    )

    return { requeued: unfinished.length }
  })
}

/**
 * Return units whose lease has expired.
 *
 * This is the gap that made the spike coordinator lose work: it held in-flight
 * units in memory with no timeout, so when a node dropped off the network its
 * units were stranded permanently. Observed live when a laptop went flat
 * mid-run.
 */
export async function reapExpiredLeases(db: Db): Promise<number> {
  const { rowCount } = await db.query(
    `UPDATE work_units
        SET state = CASE WHEN attempts >= $1 THEN 'failed' ELSE 'pending' END,
            lease_node_id = NULL,
            lease_expires_at = NULL
      WHERE state = 'leased'
        AND lease_expires_at < now()`,
    [MAX_ATTEMPTS],
  )
  return rowCount ?? 0
}

export function startReaper(db: Db, intervalMs = 15_000): NodeJS.Timeout {
  const timer = setInterval(() => {
    reapExpiredLeases(db).catch((err) => console.error('reaper failed', err))
    // The other half of not holding anything indefinitely. Releasing a job's
    // inputs happens the moment its last unit stops, which covers every job
    // that ends; this covers the ones that do not - frames nobody collected,
    // and blobs left behind by a job deleted out from under them.
    sweepExpired(db).catch((err) => console.error('expiry sweep failed', err))
  }, intervalMs)
  timer.unref()
  return timer
}

async function sweepExpired(db: Db): Promise<void> {
  const { expireOutputs, collectGarbage } = await import('./attachments.js')
  const expired = await expireOutputs(db)
  if (expired.deleted.length > 0) {
    console.log(`expired ${expired.deleted.length} output(s) past their retention`)
  }
  const collected = await collectGarbage(db)
  if (collected.blobsDeleted > 0) {
    console.log(`deleted ${collected.blobsDeleted} unreferenced blob(s)`)
  }
}
