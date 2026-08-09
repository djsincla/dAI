import { Router } from 'express'
import type { Db } from '../lib/db.js'
import { mayPauseNode, requireRole, userAuth } from '../lib/auth.js'
import { POLICY, type PresenceState } from '../lib/policy.js'
import type { Ca } from '../lib/ca.js'

export function adminRoutes(db: Db, ca: Ca): Router {
  const r = Router()
  r.use(userAuth(db))

  r.get('/nodes', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT id, hostname, chip, memory_gb, metal_working_set_gb, tier, state,
              owner_user_id, presence_state, last_heartbeat, capability_profiles,
              user_paused, user_paused_at
         -- Superseded records are history, not fleet. They are the previous
         -- enrollment of a machine that is still here under a newer identity,
         -- so listing them shows the same hardware twice, which is the problem
         -- superseding them was meant to solve.
         FROM nodes WHERE state <> 'superseded' ORDER BY hostname`,
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
      userPaused: n.user_paused ?? false,
      userPausedAt: n.user_paused_at ? new Date(n.user_paused_at).toISOString() : null,
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

    const { rows: pending } = await db.query(
      `SELECT id, hostname, csr_pem, machine_id FROM nodes WHERE id=$1 AND state='pending'`,
      [req.params.nodeId],
    )
    if (pending.length === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no pending node with that id' })
      return
    }
    const node = pending[0] as any

    // Approval is where identity is minted. Until this point the node has a
    // queue position and nothing else.
    let signed
    try {
      signed = await ca.sign(node.csr_pem, node.id, node.hostname)
    } catch (err) {
      res.status(400).json({ error: 'bad_request',
                             detail: `cannot sign CSR: ${(err as Error).message}` })
      return
    }

    const { rows } = await db.query(
      `UPDATE nodes
          SET state='active', enrolled_at=now(),
              cert_pem=$2, cert_fingerprint=$3, cert_not_after=$4
        WHERE id=$1
      RETURNING id, hostname, tier, state`,
      [node.id, signed.certPem, signed.fingerprint, signed.notAfter],
    )
    // Retire any earlier record for the same hardware.
    //
    // A machine that is reinstalled or re-enrolled arrives as a new node with a
    // new key, and without this the old record stayed active-looking forever:
    // the fleet view showed two entries for one machine and counted its
    // capacity twice. Superseded rather than deleted, because the old
    // certificate was really issued and the history of what was signed is worth
    // keeping.
    if (node.machine_id) {
      const { rows: retired } = await db.query(
        `UPDATE nodes SET state='superseded'
          WHERE machine_id = $1 AND id <> $2 AND state <> 'superseded'
        RETURNING id`,
        [node.machine_id, node.id],
      )
      for (const old of retired) {
        await db.query(
          `INSERT INTO activity_log (node_id, event, detail)
           VALUES ($1,'node.superseded',$2)`,
          [old.id, JSON.stringify({ by: req.user!.id, replacedBy: node.id })])
      }
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

  /**
   * Lift an administrative pause.
   *
   * Its absence was a plain bug: pause could be applied and never removed, so
   * the button was a one-way door and the node stayed out of the fleet until
   * someone edited the database. Same authorisation as pause, since being able
   * to stop a machine and not start it again is not a meaningful safety
   * property.
   *
   * It does not touch user_paused. The machine owner's pause is theirs, and an
   * operator resuming a node they paused must not quietly also override the
   * person sitting at it.
   */
  r.post('/nodes/:nodeId/resume', async (req, res) => {
    if (!(await mayPauseNode(db, req.user!.id, req.params.nodeId!))) {
      res.status(403).json({ error: 'forbidden', detail: 'not the owner and not an operator' })
      return
    }
    const { rows } = await db.query(
      `UPDATE nodes SET state='active', paused_until=NULL
        WHERE id=$1 AND state='paused'
       RETURNING id, hostname, tier, state, user_paused`,
      [req.params.nodeId],
    )
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no paused node with that id' })
      return
    }
    await db.query(`INSERT INTO activity_log (node_id, event, detail) VALUES ($1,'node.resumed',$2)`,
      [req.params.nodeId, JSON.stringify({ by: req.user!.id })])
    res.json(rows[0])
  })

  /**
   * Fleet capacity, now and over the last 24 hours.
   *
   * Split by GPU and ANE because they are not interchangeable: GPU work is
   * confined to LOCKED and ABSENT, while ANE work runs in every state. The
   * overnight GPU swell as machines lock is the value proposition made visible,
   * and the flat ANE band underneath it is the daytime capacity E5 bought.
   *
   * Capacity is memFrac of each node's Metal working set, not of installed RAM:
   * Metal caps itself around 81% of unified memory.
   */
  r.get('/fleet/summary', async (_req, res) => {
    const { rows: nodes } = await db.query(
      `SELECT id, hostname, state, presence_state, metal_working_set_gb, user_paused,
              on_ac_power, thermal_ok
         -- Superseded excluded for the same reason as pending: it is not
         -- capacity. Counting a retired record would inflate the fleet by
         -- exactly the machines that were reinstalled.
         FROM nodes WHERE state NOT IN ('pending', 'superseded')`,
    )

    let gpuGb = 0
    let aneGb = 0
    let eligible = 0
    for (const n of nodes as any[]) {
      const usable = n.state === 'active' && n.on_ac_power !== false && n.thermal_ok !== false
      // A paused machine is not capacity. Counting it would overstate the
      // fleet by exactly the machines whose owners have opted out, which is the
      // number most worth being honest about.
      if (!usable || !n.presence_state || n.user_paused) continue
      const p = POLICY[n.presence_state as PresenceState]
      if (!p) continue
      const gb = Number(n.metal_working_set_gb ?? 0) * p.memFrac
      if (p.gpu && p.dutyMax > 0) { gpuGb += gb; eligible += 1 }
      if (p.ane) aneGb += gb
    }

    // Hourly buckets. A node counts toward GPU capacity in an hour if its
    // sampled state permitted GPU work then, which is what "can I schedule
    // tonight" actually depends on.
    const { rows: series } = await db.query(
      `SELECT date_trunc('hour', ps.at) AS hour,
              ps.presence_state,
              count(DISTINCT ps.node_id)::int AS nodes,
              COALESCE(sum(DISTINCT n.metal_working_set_gb), 0) AS gb
         FROM presence_samples ps
         JOIN nodes n ON n.id = ps.node_id
        WHERE ps.at > now() - interval '24 hours'
        GROUP BY 1, 2
        ORDER BY 1`,
    )

    const buckets = new Map<string, { hour: string; gpuGb: number; aneGb: number }>()
    for (const row of series as any[]) {
      const key = (row.hour as Date).toISOString()
      const b = buckets.get(key) ?? { hour: key, gpuGb: 0, aneGb: 0 }
      const p = POLICY[row.presence_state as PresenceState]
      if (p) {
        const gb = Number(row.gb) * p.memFrac
        if (p.gpu && p.dutyMax > 0) b.gpuGb += gb
        if (p.ane) b.aneGb += gb
      }
      buckets.set(key, b)
    }

    const { rows: queues } = await db.query(
      `SELECT kind, state, count(*)::int AS n FROM work_units GROUP BY 1,2`)

    res.json({
      nodes: nodes.length,
      eligibleForGpu: eligible,
      gpuCapacityGb: Math.round(gpuGb * 10) / 10,
      aneCapacityGb: Math.round(aneGb * 10) / 10,
      series: [...buckets.values()].map((b) => ({
        hour: b.hour,
        gpuGb: Math.round(b.gpuGb * 10) / 10,
        aneGb: Math.round(b.aneGb * 10) / 10,
      })),
      queues,
    })
  })

  /**
   * Per-node detail: the idle pattern and yield count a wrangler actually asks
   * about. "Can I count on this box tonight" and "how often does it interrupt",
   * the latter being the early warning that a policy is too aggressive.
   */
  r.get('/nodes/:nodeId/detail', async (req, res) => {
    const nodeId = req.params.nodeId!
    const { rows } = await db.query(
      `SELECT id, hostname, chip, memory_gb, metal_working_set_gb, tier, state,
              owner_user_id, presence_state, on_ac_power, thermal_ok,
              last_heartbeat, capability_profiles, allowed_cidrs,
              user_paused, user_paused_at
         FROM nodes WHERE id = $1`, [nodeId])
    if (rows.length === 0) { res.status(404).json({ error: 'not_found' }); return }
    const n = rows[0] as any

    const { rows: pattern } = await db.query(
      `SELECT EXTRACT(hour FROM at)::int AS hour, presence_state, count(*)::int AS n
         FROM presence_samples WHERE node_id = $1 AND at > now() - interval '7 days'
        GROUP BY 1,2 ORDER BY 1`, [nodeId])

    const { rows: yields } = await db.query(
      `SELECT count(*)::int AS n FROM activity_log
        WHERE node_id = $1 AND event = 'work.result'
          AND (detail->>'requeued')::int > 0
          AND at > now() - interval '7 days'`, [nodeId])

    const { rows: log } = await db.query(
      `SELECT at, event, detail FROM activity_log
        WHERE node_id = $1 ORDER BY at DESC LIMIT 50`, [nodeId])

    const policy = n.presence_state ? POLICY[n.presence_state as PresenceState] : null

    res.json({
      id: n.id, hostname: n.hostname, chip: n.chip,
      memoryGb: n.memory_gb === null ? null : Number(n.memory_gb),
      metalWorkingSetGb: n.metal_working_set_gb === null ? null : Number(n.metal_working_set_gb),
      tier: n.tier, state: n.state, ownerUserId: n.owner_user_id,
      presenceState: n.presence_state,
      userPaused: n.user_paused ?? false,
      userPausedAt: n.user_paused_at ? new Date(n.user_paused_at).toISOString() : null,
      onAcPower: n.on_ac_power, thermalOk: n.thermal_ok,
      lastHeartbeat: n.last_heartbeat, capabilityProfiles: n.capability_profiles,
      allowedCidrs: n.allowed_cidrs,
      // Headroom is what is takeable right now under policy, which is not the
      // same as the machine's total memory.
      headroomGb: policy
        ? Math.round(Number(n.metal_working_set_gb ?? 0) * policy.memFrac * 10) / 10
        : 0,
      policy,
      idlePattern: pattern,
      yields7d: (yields[0] as any)?.n ?? 0,
      // pg returns timestamptz as a Date. The schema declares strings, and a
      // generated client would deserialize accordingly, so serialize here
      // rather than letting JSON.stringify decide.
      activity: (log as any[]).map((e) => ({
        at: (e.at as Date).toISOString(), event: e.event, detail: e.detail,
      })),
    })
  })

  /**
   * Revoke a node's certificate.
   *
   * Checked on every request rather than cached, so a stolen laptop stops being
   * a fleet member immediately rather than at the next renewal.
   */
  r.post('/nodes/:nodeId/revoke', async (req, res) => {
    const { rows: admin } = await db.query(
      `SELECT 1 FROM role_bindings rb
         JOIN group_members gm ON gm.group_id = rb.group_id
        WHERE gm.user_id = $1 AND rb.role = 'admin' LIMIT 1`, [req.user!.id])
    if (admin.length === 0) {
      res.status(403).json({ error: 'forbidden', detail: 'admin role required' })
      return
    }
    const { rows } = await db.query(
      `UPDATE nodes SET revoked_at=now(), state='cordoned' WHERE id=$1
       RETURNING id, hostname, tier, state`, [req.params.nodeId])
    if (rows.length === 0) { res.status(404).json({ error: 'not_found' }); return }
    await db.query(`INSERT INTO activity_log (node_id, event, detail) VALUES ($1,'cert.revoked',$2)`,
      [req.params.nodeId, JSON.stringify({ by: req.user!.id })])
    res.json(rows[0])
  })

  r.get('/pools', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT id, name, tier, schedule, preempt, priority FROM pools ORDER BY name`,
    )
    res.json(rows)
  })

  /**
   * What is queued and what it is.
   *
   * There was no way to see this at all: the fleet view could say a machine was
   * busy but nothing said with what, or who asked for it. That is a poor answer
   * for an operator and a worse one for the person whose machine is running it.
   */
  r.get('/jobs', async (req, res) => {
    const { rows } = await db.query(
      `SELECT j.id, j.pool_id, j.kind, j.state, j.label, j.source, j.created_at,
              u.email AS submitted_by_email,
              count(w.id) FILTER (WHERE w.state = 'pending')::int AS pending,
              count(w.id) FILTER (WHERE w.state = 'leased')::int  AS leased,
              count(w.id) FILTER (WHERE w.state = 'done')::int    AS done,
              count(w.id) FILTER (WHERE w.state = 'failed')::int  AS failed
         FROM jobs j
         LEFT JOIN users u ON u.id = j.submitted_by
         LEFT JOIN work_units w ON w.job_id = j.id
        GROUP BY j.id, u.email
        ORDER BY j.created_at DESC
        LIMIT 50`,
    )
    res.json(rows.map((j: any) => ({
      id: j.id, poolId: j.pool_id, kind: j.kind, state: j.state,
      label: j.label, source: j.source,
      submittedBy: j.submitted_by_email ?? null,
      createdAt: j.created_at ? new Date(j.created_at).toISOString() : null,
      counts: { pending: j.pending, leased: j.leased, done: j.done, failed: j.failed },
    })))
  })

  /**
   * The results of a job.
   *
   * Without this the API could take work and never give it back: units were
   * completed, their output stored, and nothing could read it. A work API that
   * accepts a request and cannot answer it is not finished, however good its
   * dispatch is.
   *
   * Paged by position, which is submission order, so a caller can stream a
   * large job in pieces and knows where it stopped. Offsets would drift as
   * requeued remainders slot in ahead.
   */
  r.get('/jobs/:jobId/results', async (req, res) => {
    const jobId = req.params.jobId!
    const limit = Math.min(Number(req.query.limit ?? 100), 1000)
    const after = req.query.after === undefined ? -1 : Number(req.query.after)

    const { rows: job } = await db.query(`SELECT id, state FROM jobs WHERE id = $1`, [jobId])
    if (job.length === 0) { res.status(404).json({ error: 'not_found' }); return }

    const { rows } = await db.query(
      `SELECT w.id, w.position, w.state, w.result, n.hostname
         FROM work_units w
         LEFT JOIN nodes n ON n.id = w.completed_by
        WHERE w.job_id = $1 AND w.position > $2 AND w.state = 'done'
        ORDER BY w.position
        LIMIT $3`,
      [jobId, after, limit],
    )

    res.json({
      jobId,
      state: job[0]!.state,
      units: rows.map((u: any) => ({
        unitId: u.id,
        // Coerced because pg returns bigint as a string to avoid losing
        // precision, and the schema says integer. Passing it through unchanged
        // fails response validation with a message about the field rather than
        // the driver.
        position: Number(u.position),
        // Which machine produced it. The point of the whole arrangement is that
        // this is answerable.
        node: u.hostname ?? null,
        seconds: u.result?.seconds ?? null,
        items: u.result?.completed ?? [],
      })),
      // Null when the page was not full, which is how a caller knows it has
      // everything rather than having to ask again to find out.
      nextAfter: rows.length === limit ? Number(rows[rows.length - 1]!.position) : null,
    })
  })

  r.post('/jobs', async (req, res) => {
    const b = req.body as {
      poolId: string; kind: 'embed' | 'generate' | 'render'
      modelHash?: string | null; batchSize?: number; items: unknown[]
      label?: string; source?: string
    }
    if (!(await requireRole(db, req.user!.id, b.poolId, 'operator'))) {
      res.status(403).json({ error: 'forbidden', detail: 'operator role required on this pool' })
      return
    }

    const batchSize = b.batchSize ?? 8
    const { rows } = await db.query(
      `INSERT INTO jobs (pool_id, kind, model_hash, submitted_by, label, source)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [b.poolId, b.kind, b.modelHash ?? null, req.user!.id,
       b.label ?? null, b.source ?? 'api'],
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
    `SELECT j.id, j.pool_id, j.kind, j.state, j.label, j.source, j.created_at,
            u.email AS submitted_by_email
       FROM jobs j LEFT JOIN users u ON u.id = j.submitted_by
      WHERE j.id = $1`, [jobId])
  const job = rows[0]
  if (!job) return null
  const { rows: counts } = await db.query(
    `SELECT state, count(*)::int AS n FROM work_units WHERE job_id=$1 GROUP BY state`, [jobId])
  const c: Record<string, number> = { pending: 0, leased: 0, done: 0, failed: 0 }
  for (const row of counts as { state: string; n: number }[]) c[row.state] = row.n
  return {
    id: job.id, poolId: job.pool_id, kind: job.kind, state: job.state,
    label: job.label, source: job.source,
    submittedBy: job.submitted_by_email ?? null,
    createdAt: job.created_at ? new Date(job.created_at).toISOString() : null,
    counts: c,
  }
}
