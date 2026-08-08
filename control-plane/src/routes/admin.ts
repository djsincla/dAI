import { Router } from 'express'
import type { Db } from '../lib/db.js'
import { mayPauseNode, requireRole, userAuth } from '../lib/auth.js'

export function adminRoutes(db: Db): Router {
  const r = Router()
  r.use(userAuth(db))

  r.get('/nodes', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT id, hostname, chip, memory_gb, metal_working_set_gb, tier, state,
              owner_user_id, presence_state, last_heartbeat, capability_profiles
         FROM nodes ORDER BY hostname`,
    )
    res.json(rows.map((n) => ({
      id: n.id,
      hostname: n.hostname,
      chip: n.chip,
      memoryGb: n.memory_gb === null ? null : Number(n.memory_gb),
      metalWorkingSetGb: n.metal_working_set_gb === null ? null : Number(n.metal_working_set_gb),
      tier: n.tier,
      state: n.state,
      ownerUserId: n.owner_user_id,
      presenceState: n.presence_state,
      lastHeartbeat: n.last_heartbeat,
      capabilityProfiles: n.capability_profiles,
    })))
  })

  r.post('/nodes/:nodeId/approve', async (req, res) => {
    // Approval is an admin action anywhere in the fleet, not pool-scoped:
    // enrolling a node is what decides which pools it can ever join.
    const { rows: bindings } = await db.query(
      `SELECT 1 FROM role_bindings rb
         JOIN group_members gm ON gm.group_id = rb.group_id
        WHERE gm.user_id = $1 AND rb.role = 'admin' LIMIT 1`,
      [req.user!.id],
    )
    if (bindings.length === 0) {
      res.status(403).json({ error: 'forbidden', detail: 'admin role required' })
      return
    }

    const { rows } = await db.query(
      `UPDATE nodes SET state='active', enrolled_at=now()
        WHERE id=$1 AND state='pending'
      RETURNING id, hostname, tier, state`,
      [req.params.nodeId],
    )
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no pending node with that id' })
      return
    }
    await db.query(`INSERT INTO activity_log (node_id, event, detail) VALUES ($1,'node.approved',$2)`,
      [req.params.nodeId, JSON.stringify({ by: req.user!.id })])
    res.json(rows[0])
  })

  /**
   * Pausing is governed by ownership, not by role bindings. The owner of a
   * machine may always pause it and no admin can override that; operators and
   * admins may also pause, since draining a node is ordinary fleet work.
   */
  r.post('/nodes/:nodeId/pause', async (req, res) => {
    if (!(await mayPauseNode(db, req.user!.id, req.params.nodeId!))) {
      res.status(403).json({ error: 'forbidden', detail: 'not the owner and not an operator' })
      return
    }
    const until = (req.body as { until?: string | null })?.until ?? null
    const { rows } = await db.query(
      `UPDATE nodes SET state='paused', paused_until=$2 WHERE id=$1
       RETURNING id, hostname, tier, state`,
      [req.params.nodeId, until],
    )
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found' })
      return
    }
    await db.query(`INSERT INTO activity_log (node_id, event, detail) VALUES ($1,'node.paused',$2)`,
      [req.params.nodeId, JSON.stringify({ by: req.user!.id, until })])
    res.json(rows[0])
  })

  r.get('/pools', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT id, name, tier, schedule, preempt, priority FROM pools ORDER BY name`,
    )
    res.json(rows)
  })

  r.post('/jobs', async (req, res) => {
    const b = req.body as {
      poolId: string; kind: 'embed' | 'generate' | 'render'
      modelHash?: string | null; batchSize?: number; items: unknown[]
    }
    if (!(await requireRole(db, req.user!.id, b.poolId, 'operator'))) {
      res.status(403).json({ error: 'forbidden', detail: 'operator role required on this pool' })
      return
    }

    const batchSize = b.batchSize ?? 8
    const { rows } = await db.query(
      `INSERT INTO jobs (pool_id, kind, model_hash, submitted_by)
       VALUES ($1,$2,$3,$4) RETURNING id`,
      [b.poolId, b.kind, b.modelHash ?? null, req.user!.id],
    )
    const jobId = rows[0]!.id as string

    // Units are batches of items. Position drives dispatch order and lets a
    // requeued remainder go back at the head.
    let position = 0
    for (let i = 0; i < b.items.length; i += batchSize) {
      await db.query(
        `INSERT INTO work_units (job_id, kind, payload, position) VALUES ($1,$2,$3,$4)`,
        [jobId, b.kind, JSON.stringify(b.items.slice(i, i + batchSize)), position],
      )
      position += 1000 // leave gaps so requeues can slot in front
    }
    res.status(201).json(await jobSummary(db, jobId))
  })

  r.get('/jobs/:jobId', async (req, res) => {
    const summary = await jobSummary(db, req.params.jobId!)
    if (!summary) {
      res.status(404).json({ error: 'not_found' })
      return
    }
    res.json(summary)
  })

  return r
}

async function jobSummary(db: Db, jobId: string) {
  const { rows } = await db.query(
    `SELECT id, pool_id, kind, state FROM jobs WHERE id = $1`, [jobId])
  const job = rows[0]
  if (!job) return null
  const { rows: counts } = await db.query(
    `SELECT state, count(*)::int AS n FROM work_units WHERE job_id=$1 GROUP BY state`, [jobId])
  const c: Record<string, number> = { pending: 0, leased: 0, done: 0, failed: 0 }
  for (const row of counts as { state: string; n: number }[]) c[row.state] = row.n
  return { id: job.id, poolId: job.pool_id, kind: job.kind, state: job.state, counts: c }
}
