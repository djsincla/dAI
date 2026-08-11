import { framesFor, outputsRoot, registerScene, sceneById } from '../lib/scenes.js'
import {
  attach, blobPath, expireOutputs, hashOf, outputPath, putBlob, retentionAfterCollection,
} from '../lib/attachments.js'
import { resolve as resolveOpenJD, frameOf, type JobTemplate } from '../lib/openjd.js'
import { safePath } from '../lib/repository.js'
import { existsSync } from 'node:fs'
import { Router } from 'express'
import { type Db, tx } from '../lib/db.js'
import { nodeMatchesPool, poolMode, poolsFor } from '../lib/pools.js'
import { bucketFor, clampWindow } from '../lib/window.js'
import { asHtml, asText, readLogs } from '../lib/logs.js'
import { registerAgentBuild } from '../lib/agentBuilds.js'
import { candidates, localCandidates } from '../lib/candidates.js'
import { importModel, startImport } from '../lib/import.js'
import { mayPauseNode, requireRole, userAuth } from '../lib/auth.js'
import { POLICY, type PresenceState } from '../lib/policy.js'
import type { Ca } from '../lib/ca.js'
import type { Broker } from '../lib/broker.js'

export function adminRoutes(db: Db, ca: Ca, broker: Broker): Router {
  const r = Router()
  r.use(userAuth(db))

  r.get('/nodes', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT id, hostname, chip, memory_gb, metal_working_set_gb, tier, state,
              owner_user_id, presence_state, last_heartbeat, capability_profiles,
              user_paused, user_paused_at, resident_models, model_context
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
      // What this node can answer with, and whether it could answer now.
      //
      // The fleet view could say a machine was busy and not what with, which is
      // a poor answer for an operator and no answer at all for the person whose
      // machine it is. Serving is separate from presence: a node holding the
      // channel open is available, and one mid-request is neither idle nor
      // gone.
      models: Object.keys({ ...(n.model_context ?? {}), ...(n.resident_models ?? {}) }),
      residentModels: Object.keys(n.resident_models ?? {}),
      serving: broker.isConnected(n.id),
      inFlight: broker.inFlightCounts.get(n.id) ?? 0,
      lastHeartbeat: n.last_heartbeat ? new Date(n.last_heartbeat).toISOString() : null,
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
  r.get('/fleet/summary', async (req, res) => {
    // The capacity graph is draggable between ten minutes and three days, so
    // the window and the bucket both come from the caller. Bucket derived from
    // the window rather than accepted separately: the two have to agree, and a
    // client that could set them independently could ask for ten second buckets
    // over three days and get twenty-six thousand rows.
    const windowS = clampWindow(Number(req.query.window ?? 86400))
    const bucketS = bucketFor(windowS)
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
      `SELECT to_timestamp(floor(extract(epoch FROM ps.at) / $1) * $1) AS hour,
              ps.presence_state,
              count(DISTINCT ps.node_id)::int AS nodes,
              COALESCE(sum(DISTINCT n.metal_working_set_gb), 0) AS gb
         FROM presence_samples ps
         JOIN nodes n ON n.id = ps.node_id
        WHERE ps.at > now() - make_interval(secs => $2)
        GROUP BY 1, 2
        ORDER BY 1`,
      [bucketS, windowS],
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

    // Machines waiting to be let in. Carried on the summary because it is the
    // one thing on the overview that blocks entirely on a human: a node that
    // enrolled and was never approved does nothing at all, and nothing else on
    // the page hints that it is there.
    const { rows: pending } = await db.query(
      `SELECT count(*)::int AS n FROM nodes WHERE state = 'pending'`)

    res.json({
      nodes: nodes.length,
      pendingNodes: pending[0]?.n ?? 0,
      eligibleForGpu: eligible,
      gpuCapacityGb: Math.round(gpuGb * 10) / 10,
      aneCapacityGb: Math.round(aneGb * 10) / 10,
      series: [...buckets.values()].map((b) => ({
        hour: b.hour,
        gpuGb: Math.round(b.gpuGb * 10) / 10,
        aneGb: Math.round(b.aneGb * 10) / 10,
      })),
      queues,
      windowSeconds: windowS,
      bucketSeconds: bucketS,
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
      // What this node can answer with, and whether it could answer now.
      //
      // The fleet view could say a machine was busy and not what with, which is
      // a poor answer for an operator and no answer at all for the person whose
      // machine it is. Serving is separate from presence: a node holding the
      // channel open is available, and one mid-request is neither idle nor
      // gone.
      models: Object.keys({ ...(n.model_context ?? {}), ...(n.resident_models ?? {}) }),
      residentModels: Object.keys(n.resident_models ?? {}),
      serving: broker.isConnected(n.id),
      inFlight: broker.inFlightCounts.get(n.id) ?? 0,
      onAcPower: n.on_ac_power, thermalOk: n.thermal_ok,
      lastHeartbeat: n.last_heartbeat ? new Date(n.last_heartbeat).toISOString() : null,
      capabilityProfiles: n.capability_profiles,
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
      `SELECT id, name, tier, schedule, preempt, priority,
              agent_channel, desired_agent_version
         FROM pools ORDER BY name`,
    )
    res.json(rows.map((p) => ({
      id: p.id, name: p.name, tier: p.tier, schedule: p.schedule,
      preempt: p.preempt, priority: p.priority,
      agentChannel: p.agent_channel,
      desiredAgentVersion: p.desired_agent_version ?? null,
    })))
  })

  /**
   * Create a group.
   *
   * Groups were invisible everywhere except the models page, which said a model
   * was pushed to "overnight-harvest" while nothing else on the fleet view
   * mentioned that such a thing existed.
   */
  r.post('/pools', async (req, res) => {
    const b = req.body as { name: string; tier?: 'harvest' | 'cluster' }
    try {
      const { rows } = await db.query(
        `INSERT INTO pools (name, tier, schedule, preempt)
         VALUES ($1, $2, $3, $4) RETURNING id, name, tier`,
        [b.name, b.tier ?? 'harvest',
         b.tier === 'cluster' ? 'gang' : 'independent-units',
         b.tier === 'cluster' ? 'never' : 'on-user-activity'],
      )
      const pool = rows[0]!
      // The creator can act on what they made. Without this a new group is one
      // nobody has standing on, including the person looking at it.
      const { rows: groups } = await db.query(
        `SELECT g.id FROM groups g JOIN group_members m ON m.group_id = g.id
          WHERE m.user_id = $1 LIMIT 1`, [req.user!.id])
      if (groups[0]) {
        await db.query(
          `INSERT INTO role_bindings (group_id, pool_id, role) VALUES ($1,$2,'admin')
           ON CONFLICT DO NOTHING`, [groups[0].id, pool.id])
      }
      await audit(db, req.user!.id, 'pool.create', pool.name, { tier: pool.tier })
      res.status(201).json({ id: pool.id, name: pool.name, tier: pool.tier })
    } catch (e) {
      if ((e as { code?: string }).code === '23505') {
        res.status(409).json({ error: 'conflict', detail: `a group called ${b.name} exists` })
        return
      }
      throw e
    }
  })

  /**
   * Put a machine in a group, or take it out.
   *
   * A group is either a list somebody picked or a rule machines match, never
   * both: a pool that was both would answer "who is in this group" with
   * something nobody could predict from looking at it. So adding the first
   * machine by hand converts a rule into a list, and that changes which
   * machines belong. It needs saying rather than doing quietly, which is what
   * `confirm` is for.
   */
  r.put('/pools/:poolId/nodes/:nodeId', async (req, res) => {
    const { poolId, nodeId } = req.params as { poolId: string; nodeId: string }
    if (!(await requireRole(db, req.user!.id, poolId, 'operator'))) {
      res.status(403).json({ error: 'forbidden', detail: 'operator role required on this pool' })
      return
    }
    const { rows } = await db.query(
      `SELECT id, tier, membership FROM pools WHERE id = $1`, [poolId])
    const pool = rows[0]
    if (!pool) { res.status(404).json({ error: 'not_found', detail: 'no such group' }); return }

    const { rows: nodeRows } = await db.query(
      `SELECT id, hostname, tier, chip, memory_gb FROM nodes WHERE id = $1`, [nodeId])
    const node = nodeRows[0]
    if (!node) { res.status(404).json({ error: 'not_found', detail: 'no such machine' }); return }
    if (pool.tier === 'cluster' && node.tier !== 'cluster') {
      // The one rule a hand-picked list cannot override. Gang work on a
      // preemptible machine dies the moment somebody touches that keyboard.
      res.status(409).json({
        error: 'conflict',
        detail: `${node.hostname} is a ${node.tier} machine and this is a cluster group`,
      })
      return
    }

    const membership = (pool.membership ?? {}) as Record<string, unknown>
    const ids = new Set((membership.nodeIds as string[] | undefined) ?? [])
    if (poolMode(pool as never) === 'rule' && !(req.body as { confirm?: boolean })?.confirm) {
      // Everything currently matching by rule would stop matching. Whoever is
      // about to do that should be told how many machines it is.
      const { rows: all } = await db.query(
        `SELECT id, hostname, tier, chip, memory_gb FROM nodes WHERE state = 'active'`)
      const matching = all.filter((n) => nodeMatchesPool(n as never, pool as never))
      res.status(409).json({
        error: 'confirm_required',
        detail: `${pool.id} currently matches ${matching.length} machines by rule. `
          + 'Adding one by hand turns it into a list containing only what you put in it.',
        wouldDrop: matching.map((n) => n.hostname),
      })
      return
    }

    ids.add(nodeId)
    await db.query(
      `UPDATE pools SET membership = membership || jsonb_build_object('nodeIds', $2::jsonb)
        WHERE id = $1`, [poolId, JSON.stringify([...ids])])
    await audit(db, req.user!.id, 'pool.add', node.hostname, { poolId })
    res.status(204).end()
  })

  r.delete('/pools/:poolId/nodes/:nodeId', async (req, res) => {
    const { poolId, nodeId } = req.params as { poolId: string; nodeId: string }
    if (!(await requireRole(db, req.user!.id, poolId, 'operator'))) {
      res.status(403).json({ error: 'forbidden', detail: 'operator role required on this pool' })
      return
    }
    const { rows } = await db.query(`SELECT membership FROM pools WHERE id = $1`, [poolId])
    if (!rows[0]) { res.status(404).json({ error: 'not_found', detail: 'no such group' }); return }
    const ids = (((rows[0].membership ?? {}) as Record<string, unknown>).nodeIds as string[]
      | undefined) ?? []
    await db.query(
      `UPDATE pools SET membership = membership || jsonb_build_object('nodeIds', $2::jsonb)
        WHERE id = $1`, [poolId, JSON.stringify(ids.filter((i) => i !== nodeId))])
    await audit(db, req.user!.id, 'pool.remove', nodeId, { poolId })
    res.status(204).end()
  })

  /* --------------------------------------------------------- agent builds */

  /**
   * Which agent builds exist, and what each machine is actually running.
   *
   * Until this existed there was no way to know what a fleet was running. Two
   * deploys in one day left both machines on a build from hours earlier, and
   * finding that out meant comparing file sizes over ssh and guessing.
   */
  r.get('/agent/builds', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT b.version, b.sha256, b.size_bytes, b.notes, b.uploaded_at, u.email
         FROM agent_builds b LEFT JOIN users u ON u.id = b.uploaded_by
        ORDER BY b.uploaded_at DESC`)
    const { rows: running } = await db.query(
      `SELECT agent_version, agent_fingerprint, count(*)::int AS n
         FROM nodes WHERE state = 'active' GROUP BY 1, 2`)
    res.json({
      builds: rows.map((b) => ({
        version: b.version, sha256: b.sha256, sizeBytes: Number(b.size_bytes),
        notes: b.notes, uploadedAt: new Date(b.uploaded_at).toISOString(),
        uploadedBy: b.email ?? null,
        // Counted by fingerprint, not by version: a build number is what
        // somebody typed and the hash is what is running.
        nodesRunning: running
          .filter((n) => n.agent_fingerprint === b.sha256)
          .reduce((t, n) => t + n.n, 0),
      })),
      running: running.map((n) => ({
        version: (n.agent_version as string | null) ?? 'unknown',
        fingerprint: (n.agent_fingerprint as string | null) ?? null,
        nodes: n.n,
      })),
    })
  })

  /** Register a build from a file on this machine, hashing it on the way in. */
  r.post('/agent/builds', async (req, res) => {
    const b = req.body as { version: string; path: string; notes?: string }
    try {
      const built = await registerAgentBuild(db, b.version, b.path, b.notes ?? null,
        req.user!.id)
      await audit(db, req.user!.id, 'agent.build.register', b.version,
        { sha256: built.sha256, sizeBytes: built.sizeBytes })
      res.status(201).json(built)
    } catch (e) {
      const code = (e as { code?: string }).code
      if (code === '23505') {
        res.status(409).json({ error: 'conflict', detail: `${b.version} already registered` })
        return
      }
      res.status(400).json({ error: 'bad_request', detail: (e as Error).message })
    }
  })

  /**
   * Who owns the binary on a pool's machines, and which version they should run.
   *
   * `external` never pushes. It records what is expected and reports what is
   * seen, which is what makes this safe to run alongside an MDM: two systems
   * racing to own the same executable is worse than either owning it alone.
   */
  r.put('/pools/:poolId/agent', async (req, res) => {
    const { poolId } = req.params as { poolId: string }
    const b = req.body as { channel: 'managed' | 'external'; version?: string | null }
    if (!(await requireRole(db, req.user!.id, poolId, 'admin'))) {
      res.status(403).json({ error: 'forbidden', detail: 'admin role required on this pool' })
      return
    }
    if (b.version) {
      const { rows } = await db.query(`SELECT 1 FROM agent_builds WHERE version = $1`,
        [b.version])
      if (rows.length === 0) {
        res.status(404).json({ error: 'not_found', detail: `no such build: ${b.version}` })
        return
      }
    }
    await db.query(
      `UPDATE pools SET agent_channel = $2, desired_agent_version = $3 WHERE id = $1`,
      [poolId, b.channel, b.version ?? null])
    await audit(db, req.user!.id, 'agent.release', b.version ?? '(none)',
      { poolId, channel: b.channel })
    res.status(204).end()
  })

  /** Every machine, what it runs, what it should run, and who decides. */
  r.get('/agent/rollout', async (_req, res) => {
    const { rows: pools } = await db.query(
      `SELECT id, name, tier, membership, agent_channel, desired_agent_version FROM pools`)
    const { rows: nodes } = await db.query(
      `SELECT id, hostname, tier, chip, memory_gb, state, agent_version, agent_fingerprint
         FROM nodes WHERE state = 'active' ORDER BY hostname`)
    const { rows: builds } = await db.query(`SELECT version, sha256 FROM agent_builds`)
    const shaFor = new Map(builds.map((b) => [b.version as string, b.sha256 as string]))

    res.json(nodes.map((n) => {
      const mine = poolsFor(n as never, pools as never)
      // The strictest pool wins when a machine is in more than one: managed
      // beats external, because a machine somebody chose to manage should not
      // stop being managed by joining a second pool.
      const managed = mine.find((p) => (p as never as Record<string, string>).agent_channel === 'managed')
      const decider = managed ?? mine[0]
      const desired = decider
        ? ((decider as never as Record<string, string | null>).desired_agent_version ?? null)
        : null
      const expectedSha = desired ? shaFor.get(desired) ?? null : null
      return {
        nodeId: n.id, hostname: n.hostname,
        running: (n.agent_version as string | null) ?? 'unknown',
        fingerprint: (n.agent_fingerprint as string | null) ?? null,
        desired,
        channel: managed ? 'managed' : 'external',
        // Compared by hash where one is known. A node reporting the right
        // version number with the wrong bytes is the case worth catching, and
        // it is invisible to a string comparison.
        upToDate: desired === null ? null
          : expectedSha !== null && n.agent_fingerprint !== null
            ? n.agent_fingerprint === expectedSha
            : n.agent_version === desired,
      }
    }))
  })

  /** What each machine tried and how it ended, including rollbacks. */
  r.get('/agent/upgrades', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT u.at, u.from_version, u.to_version, u.state, u.detail, n.hostname
         FROM agent_upgrades u JOIN nodes n ON n.id = u.node_id
        ORDER BY u.at DESC LIMIT 100`)
    res.json(rows.map((r2) => ({
      at: new Date(r2.at).toISOString(), hostname: r2.hostname,
      fromVersion: r2.from_version, toVersion: r2.to_version,
      state: r2.state, detail: r2.detail,
    })))
  })

  /**
   * Every log, in one place, in three formats.
   *
   * Two tables answering different questions - what a machine has been doing,
   * and who told the fleet to do something - read together, because nobody
   * investigating an incident cares which table a line came from. A model push
   * and the fetches it caused are one story, and reading it used to mean opening
   * two things and interleaving them by eye.
   *
   * The text and HTML forms are exports rather than views: an artefact to grep,
   * attach to a ticket, or send to somebody who has no login here.
   */
  r.get('/logs', async (req, res) => {
    const query = {
      q: req.query.q as string | undefined,
      since: req.query.since as string | undefined,
      until: req.query.until as string | undefined,
      source: req.query.source as 'node' | 'fleet' | undefined,
      limit: req.query.limit ? Number(req.query.limit) : undefined,
    }
    const rows = await readLogs(db, query)
    const format = (req.query.format as string) ?? 'json'
    const stamp = new Date().toISOString()

    if (format === 'text') {
      // Attachment rather than inline: this is something to keep, and a browser
      // rendering it as a wall of text in a tab is not that.
      res.type('text/plain; charset=utf-8')
        .set('content-disposition', `attachment; filename="dai-log-${stamp}.txt"`)
        .send(asText(rows))
      return
    }
    if (format === 'html') {
      res.type('text/html; charset=utf-8')
        .set('content-disposition', `attachment; filename="dai-log-${stamp}.html"`)
        .send(asHtml(rows, { query, generatedAt: stamp }))
      return
    }
    res.json(rows)
  })

  /**
   * The model catalogue.
   *
   * Before this there was no catalogue: `jobs.model_hash` was free text matched
   * against whatever a node reported holding, so the fleet could say what a
   * machine had and never what it should have. Weights were staged by hand over
   * scp, unverified, and drift was invisible by construction.
   *
   * `nodesHolding` against `nodesWanting` is the number that matters. One says
   * what is true, the other what was asked for, and the gap between them is the
   * only thing an operator needs to look at.
   */
  r.get('/models', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT m.id, m.runtime, m.kind, m.size_bytes, m.context_length,
              m.quantization, m.family, m.imported_at,
              count(DISTINCT f.path)::int AS file_count,
              coalesce(array_agg(DISTINCT pm.pool_id)
                       FILTER (WHERE pm.pool_id IS NOT NULL), '{}') AS assigned_pools,
              (SELECT count(*)::int FROM nodes n
                WHERE n.state = 'active' AND n.stored_models ? m.id) AS nodes_holding
         FROM models m
         LEFT JOIN model_files f ON f.model_id = m.id
         LEFT JOIN pool_models pm ON pm.model_id = m.id
        GROUP BY m.id
        ORDER BY m.id`,
    )
    res.json(await Promise.all(rows.map((m) => modelRow(db, m))))
  })

  r.post('/models', async (req, res) => {
    const b = req.body as {
      id: string; runtime: string; kind: string; contextLength?: number | null
      quantization?: string | null; family?: string | null
      files: { path: string; sizeBytes: number; sha256: string }[]
    }
    // Import is explicit. Nothing reaches the catalogue by being discovered on
    // a node, because weights nobody chose are exactly what a fleet must not
    // then distribute to every other machine.
    const total = b.files.reduce((n, f) => n + Number(f.sizeBytes), 0)
    try {
      await tx(db, async (c) => {
        await c.query(
          `INSERT INTO models (id, runtime, kind, size_bytes, context_length,
                               quantization, family, imported_by)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
          [b.id, b.runtime, b.kind, total, b.contextLength ?? null,
           b.quantization ?? null, b.family ?? null, req.user!.id],
        )
        for (const f of b.files) {
          await c.query(
            `INSERT INTO model_files (model_id, path, size_bytes, sha256)
             VALUES ($1,$2,$3,$4)`,
            [b.id, f.path, f.sizeBytes, f.sha256],
          )
        }
      })
    } catch (e) {
      // A second import of the same id is a mistake worth naming rather than an
      // update: silently replacing hashes would change what every node is
      // reconciling toward without anyone asking for it.
      if ((e as { code?: string }).code === '23505') {
        res.status(409).json({ error: 'conflict', detail: `model ${b.id} is already registered` })
        return
      }
      throw e
    }
    const { rows } = await db.query(
      `SELECT m.id, m.runtime, m.kind, m.size_bytes, m.context_length, m.quantization,
              m.family, m.imported_at, count(f.path)::int AS file_count,
              '{}'::uuid[] AS assigned_pools, 0 AS nodes_holding
         FROM models m LEFT JOIN model_files f ON f.model_id = m.id
        WHERE m.id = $1 GROUP BY m.id`, [b.id])
    res.status(201).json(await modelRow(db, rows[0]))
  })

  /**
   * What could be added, and what adding it would cost.
   *
   * Local first, because a model already on this machine costs a copy and one
   * from the internet costs the building's uplink. A fleet whose premise is
   * that data does not leave the building should not have weights arriving from
   * outside it as a side effect of somebody clicking a name in a list.
   */
  r.get('/models/available', async (_req, res) => {
    const { rows } = await db.query(`SELECT id FROM models`)
    res.json(await candidates(new Set(rows.map((r2) => r2.id as string))))
  })

  /**
   * Import a model that is already on this machine.
   *
   * Hashes every file and copies it into the repository. Runs in the
   * background and reports through the catalogue, because hashing eighteen
   * gigabytes takes minutes and an HTTP request that waits for it will be cut
   * by something in between.
   */
  r.post('/models/import', async (req, res) => {
    const { id, path: given } = req.body as { id: string; path?: string }
    const existing = await db.query(`SELECT 1 FROM models WHERE id = $1`, [id])
    if (existing.rows.length > 0) {
      res.status(409).json({ error: 'conflict', detail: `${id} is already registered` })
      return
    }
    const found = (await localCandidates()).find((c) => c.id === id)
    const source = given ?? found?.path
    if (!source) {
      res.status(404).json({ error: 'not_found', detail: `${id} is not on this machine` })
      return
    }
    // Not awaited. The response says the work started; the import row says how
    // far it got, which is the only account that survives a reload of the page
    // or a restart of whatever opened it.
    const importId = await startImport(db, id, source, req.user!.id)
    await audit(db, req.user!.id, 'model.import', id, { source })
    void importModel(db, id, source, req.user!.id, importId).catch((e) => {
      console.error(`import ${id} failed:`, e)
    })
    res.status(202).json({ id, state: 'importing' })
  })

  /**
   * Imports running now, and the recent ones that failed.
   *
   * Successful imports drop off because the model itself is the record of those.
   * A failure has no other trace, and one that leaves none is indistinguishable
   * from an import nobody started.
   */
  r.get('/models/imports', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT id, model_id, state, files_done, files_total, bytes_done, error,
              started_at, finished_at
         FROM model_imports
        WHERE state = 'running'
           OR (state = 'failed' AND started_at > now() - interval '24 hours')
        ORDER BY started_at DESC`)
    res.json(rows.map((r2) => ({
      id: r2.id,
      modelId: r2.model_id,
      state: r2.state,
      filesDone: r2.files_done,
      filesTotal: r2.files_total,
      bytesDone: Number(r2.bytes_done),
      error: r2.error,
      startedAt: new Date(r2.started_at).toISOString(),
      finishedAt: r2.finished_at ? new Date(r2.finished_at).toISOString() : null,
    })))
  })

  r.get('/models/:modelId', async (req, res) => {
    const id = req.params.modelId!
    const { rows } = await db.query(
      `SELECT m.id, m.runtime, m.kind, m.size_bytes, m.context_length, m.quantization,
              m.family, m.imported_at, count(f.path)::int AS file_count,
              coalesce(array_agg(DISTINCT pm.pool_id)
                       FILTER (WHERE pm.pool_id IS NOT NULL), '{}') AS assigned_pools,
              (SELECT count(*)::int FROM nodes n
                WHERE n.state = 'active' AND n.stored_models ? m.id) AS nodes_holding
         FROM models m
         LEFT JOIN model_files f ON f.model_id = m.id
         LEFT JOIN pool_models pm ON pm.model_id = m.id
        WHERE m.id = $1 GROUP BY m.id`, [id])
    if (!rows[0]) { res.status(404).json({ error: 'not_found', detail: 'no such model' }); return }

    const { rows: files } = await db.query(
      `SELECT path, size_bytes, sha256 FROM model_files WHERE model_id=$1 ORDER BY path`, [id])
    res.json({
      ...(await modelRow(db, rows[0])),
      files: files.map((f) => ({
        path: f.path, sizeBytes: Number(f.size_bytes), sha256: f.sha256,
      })),
      placement: await placementOf(db, id),
      // Who told the fleet to hold this, and when. The assignment row alone
      // could not answer that: it is mutable, so unassigning erased the record
      // of ever having assigned it.
      history: await historyOf(db, id),
    })
  })

  r.delete('/models/:modelId', async (req, res) => {
    const { rowCount } = await db.query(`DELETE FROM models WHERE id=$1`, [req.params.modelId])
    if (!rowCount) { res.status(404).json({ error: 'not_found', detail: 'no such model' }); return }
    await audit(db, req.user!.id, 'model.remove', req.params.modelId!)
    res.status(204).end()
  })

  /**
   * Assignment: the declared half of the picture.
   *
   * Deliberately does not move bytes. A machine that is asleep, paused or in
   * use cannot be pushed to, and a mechanism that only works on a machine
   * someone is watching is not a fleet mechanism. Nodes reconcile toward this
   * when they are able, which means the declaration outlives the moment it
   * was made.
   */
  r.put('/pools/:poolId/models/:modelId', async (req, res) => {
    const { poolId, modelId } = req.params as { poolId: string; modelId: string }
    if (!(await requireRole(db, req.user!.id, poolId, 'operator'))) {
      res.status(403).json({ error: 'forbidden', detail: 'operator role required on this pool' })
      return
    }
    try {
      await db.query(
        `INSERT INTO pool_models (pool_id, model_id, assigned_by) VALUES ($1,$2,$3)
         ON CONFLICT (pool_id, model_id) DO NOTHING`,
        [poolId, modelId, req.user!.id],
      )
    } catch (e) {
      if ((e as { code?: string }).code === '23503') {
        res.status(404).json({ error: 'not_found', detail: 'no such pool or model' })
        return
      }
      throw e
    }
    await audit(db, req.user!.id, 'model.push', modelId, { poolId })
    res.status(204).end()
  })

  r.delete('/pools/:poolId/models/:modelId', async (req, res) => {
    const { poolId, modelId } = req.params as { poolId: string; modelId: string }
    if (!(await requireRole(db, req.user!.id, poolId, 'operator'))) {
      res.status(403).json({ error: 'forbidden', detail: 'operator role required on this pool' })
      return
    }
    await db.query(`DELETE FROM pool_models WHERE pool_id=$1 AND model_id=$2`, [poolId, modelId])
    await audit(db, req.user!.id, 'model.unpush', modelId, { poolId })
    res.status(204).end()
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

  r.get('/scenes', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT id, entry, size_bytes, frame_start, frame_end, renderer
         FROM scenes ORDER BY imported_at DESC`)
    res.json({
      scenes: (rows as any[]).map((s) => ({
        id: s.id, entry: s.entry, sizeBytes: Number(s.size_bytes),
        frameStart: s.frame_start, frameEnd: s.frame_end, renderer: s.renderer,
      })),
    })
  })

  r.post('/scenes', async (req, res) => {
    const b = req.body as {
      id: string; entry?: string | null
      frameStart?: number | null; frameEnd?: number | null
    }
    const result = await registerScene(db, { ...b, importedBy: req.user!.id })
    if ('error' in result) {
      res.status(400).json({ error: 'bad_request', detail: result.error })
      return
    }
    await db.query(
      `INSERT INTO audit_log (user_id, action, subject, detail)
       VALUES ($1,'scene.registered',$2,$3)`,
      [req.user!.id, b.id, JSON.stringify({ sizeBytes: result.scene.sizeBytes,
                                            files: result.scene.files.length })],
    )
    res.status(201).json(result.scene)
  })

  /**
   * Upload one piece of a job's content, named by its own hash.
   *
   * Content-addressed so a resubmission after a lighting tweak uploads the file
   * that changed rather than the bundle, and so two jobs sharing a texture
   * library store it once. A submitter asks what is already here, sends the
   * rest, and then submits the job.
   */
  r.put('/blobs/:sha256', async (req, res) => {
    const body = req.body as Buffer
    if (!Buffer.isBuffer(body) || body.length === 0) {
      res.status(400).json({ error: 'bad_request', detail: 'no bytes' })
      return
    }
    const stored = await putBlob(db, req.params.sha256!.toLowerCase(), body)
    if ('error' in stored) {
      res.status(400).json({ error: 'bad_request', detail: stored.error })
      return
    }
    res.json(stored)
  })

  /** Which of these the fleet already holds, so a submitter sends only the rest. */
  r.post('/blobs/missing', async (req, res) => {
    const wanted = ((req.body as { sha256s?: string[] })?.sha256s ?? [])
      .map((s) => String(s).toLowerCase())
    const { rows } = await db.query(
      `SELECT sha256 FROM attachment_blobs WHERE sha256 = ANY($1::text[])`, [wanted])
    const have = new Set((rows as { sha256: string }[]).map((r) => r.sha256))
    res.json({ missing: wanted.filter((s) => !have.has(s)) })
  })

  /**
   * Submit an Open Job Description job template.
   *
   * The point of speaking the standard is that a studio's existing submitter
   * works against this fleet without knowing what this fleet is.
   *
   * The one departure is documented in the library and enforced here: the
   * template's `onRun.command` is resolved to an adapter this fleet has, never
   * executed. These machines belong to the people sitting at them.
   */
  r.post('/jobs/openjd', async (req, res) => {
    const b = req.body as {
      poolId: string
      template: JobTemplate
      parameterValues?: Record<string, string | number>
      attachments?: { path: string; sha256: string; dataFlow?: 'IN' | 'OUT' | 'INOUT' }[]
      entryPath?: string
      source?: string
    }
    if (!(await requireRole(db, req.user!.id, b.poolId, 'operator'))) {
      res.status(403).json({ error: 'forbidden', detail: 'operator role required on this pool' })
      return
    }

    const resolved = resolveOpenJD(b.template, b.parameterValues ?? {})
    if ('error' in resolved) {
      res.status(400).json({ error: 'bad_request', detail: resolved.error })
      return
    }
    const attachments = b.attachments ?? []
    // The file the adapter opens, chosen once here rather than worked out on
    // each node: two machines guessing differently would render two different
    // scenes under one job and nothing downstream would say so.
    const entry = b.entryPath
      ?? attachments.filter((a) => a.path.toLowerCase().endsWith('.blend')).map((a) => a.path)[0]
    if (!entry) {
      res.status(400).json({ error: 'bad_request',
                             detail: 'no scene among the attachments; name one with entryPath' })
      return
    }
    if (!attachments.some((a) => a.path === entry)) {
      res.status(400).json({ error: 'bad_request', detail: `${entry} is not attached` })
      return
    }

    const { rows } = await db.query(
      `INSERT INTO jobs (pool_id, kind, submitted_by, label, source, openjd_template, entry_path)
       VALUES ($1,'render',$2,$3,$4,$5,$6) RETURNING id`,
      [b.poolId, req.user!.id, resolved.job.name, b.source ?? 'openjd',
       JSON.stringify(b.template), entry],
    )
    const jobId = rows[0]!.id as string

    const attached = await attach(db, jobId, attachments)
    if ('error' in attached) {
      // Removed rather than left as a job that can never run. A submission that
      // named content nobody uploaded would lease a machine, fetch, fail, and
      // repeat on the next machine.
      await db.query(`DELETE FROM jobs WHERE id=$1`, [jobId])
      res.status(400).json({ error: 'bad_request', detail: attached.error })
      return
    }

    // One frame per unit: a unit is the granularity at which work is thrown
    // away when somebody sits down at the machine, and one frame is minutes.
    let position = 0
    for (const step of resolved.job.steps) {
      for (const task of step.tasks) {
        const frame = frameOf(task)
        if (frame === null) {
          await db.query(`DELETE FROM jobs WHERE id=$1`, [jobId])
          res.status(400).json({ error: 'bad_request',
                                 detail: `step ${step.name} has no frame parameter` })
          return
        }
        await db.query(
          `INSERT INTO work_units (job_id, kind, payload, position) VALUES ($1,'render',$2,$3)`,
          [jobId, JSON.stringify([{ id: `${step.name}-${frame}`, frame,
                                    parameters: task.parameters }]), position],
        )
        position += 1000
      }
    }
    res.status(201).json(await jobSummary(db, jobId))
  })

  r.get('/jobs/:jobId/outputs', async (req, res) => {
    const { rows: job } = await db.query(`SELECT 1 FROM jobs WHERE id=$1`, [req.params.jobId])
    if (job.length === 0) {
      res.status(404).json({ error: 'not_found' })
      return
    }
    const { rows } = await db.query(
      `SELECT o.name, o.size_bytes, o.sha256, o.created_at, n.hostname
         FROM work_outputs o LEFT JOIN nodes n ON n.id = o.node_id
        WHERE o.job_id = $1 ORDER BY o.name`, [req.params.jobId])
    res.json({
      outputs: (rows as any[]).map((o) => ({
        name: o.name, sizeBytes: Number(o.size_bytes), sha256: o.sha256,
        renderedBy: o.hostname ?? null,
        createdAt: new Date(o.created_at).toISOString(),
      })),
    })
  })

  r.get('/jobs/:jobId/outputs/:name', async (req, res) => {
    const { jobId, name } = req.params as { jobId: string; name: string }
    // Checked against the catalogue before the disk, so this can only ever
    // serve a file some node actually reported producing.
    const { rows } = await db.query(
      `SELECT 1 FROM work_outputs WHERE job_id=$1 AND name=$2`, [jobId, name])
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found' })
      return
    }
    const full = outputPath(jobId, name)
    if (!full || !existsSync(full)) {
      res.status(404).json({ error: 'not_found', detail: 'recorded but not on disk' })
      return
    }
    // Collection starts the clock. The frames are the only thing anybody
    // wanted, and once they have been taken there is no reason for this fleet
    // to keep a copy of somebody else's work.
    await db.query(
      `UPDATE work_outputs SET collected_at = COALESCE(collected_at, now())
        WHERE job_id=$1 AND name=$2`, [jobId, name])
    res.setHeader('x-dai-retention-seconds', String(retentionAfterCollection()))
    res.sendFile(full)
  })

  r.post('/jobs', async (req, res) => {
    const b = req.body as {
      poolId: string; kind: 'embed' | 'generate' | 'render'
      modelHash?: string | null; batchSize?: number; items?: unknown[]
      sceneId?: string | null; frameStart?: number; frameEnd?: number; frameStep?: number
      samples?: number | null
      label?: string; source?: string
    }
    if (!(await requireRole(db, req.user!.id, b.poolId, 'operator'))) {
      res.status(403).json({ error: 'forbidden', detail: 'operator role required on this pool' })
      return
    }

    // A render job is described by a scene and a range of frames, not by a list
    // of items. The items are derived here, once, so that every node agrees
    // about what frame 12 means and no unit has to be trusted to say.
    let items = b.items ?? []
    let sceneId: string | null = null
    if (b.kind === 'render') {
      const scene = b.sceneId ? await sceneById(db, b.sceneId) : null
      if (!scene) {
        res.status(400).json({ error: 'bad_request', detail: 'render needs a known sceneId' })
        return
      }
      const range = framesFor(b.frameStart ?? scene.frameStart ?? 1,
                              b.frameEnd ?? scene.frameEnd ?? scene.frameStart ?? 1,
                              b.frameStep ?? 1,
                              { frameStart: scene.frameStart, frameEnd: scene.frameEnd })
      if ('error' in range) {
        res.status(400).json({ error: 'bad_request', detail: range.error })
        return
      }
      sceneId = scene.id
      // The frame number is the only thing from a submission that reaches a
      // command line, and it is a number by the time it is stored.
      items = range.frames.map((frame) => ({ frame, samples: b.samples ?? null }))
    }

    const batchSize = b.batchSize ?? (b.kind === 'render' ? 1 : 8)
    const { rows } = await db.query(
      `INSERT INTO jobs (pool_id, kind, model_hash, scene_id, submitted_by, label, source)
       VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
      [b.poolId, b.kind, b.modelHash ?? null, sceneId, req.user!.id,
       b.label ?? null, b.source ?? 'api'],
    )
    const jobId = rows[0]!.id as string

    // Units are batches of items. Position drives dispatch order and lets a
    // requeued remainder go back at the head.
    let position = 0
    for (let i = 0; i < items.length; i += batchSize) {
      await db.query(
        `INSERT INTO work_units (job_id, kind, payload, position) VALUES ($1,$2,$3,$4)`,
        [jobId, b.kind, JSON.stringify(items.slice(i, i + batchSize)), position],
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

/**
 * Desired against actual, per node.
 *
 * `wanted` comes from pool assignment through pool membership, `held` from what
 * the node last reported resident. Both are needed: a node that holds a model
 * nobody assigned is as interesting as one missing a model it should have, and
 * showing only the second makes hand-staged weights invisible.
 */
async function placementOf(db: Db, modelId: string) {
  const { rows: pools } = await db.query(
    `SELECT p.id, p.tier, p.membership FROM pools p
       JOIN pool_models pm ON pm.pool_id = p.id WHERE pm.model_id = $1`, [modelId])
  const { rows: nodes } = await db.query(
    `SELECT id, hostname, tier, chip, memory_gb, stored_models, resident_models
       FROM nodes WHERE state = 'active' ORDER BY hostname`)
  return nodes.map((n) => ({
    nodeId: n.id as string,
    hostname: n.hostname as string,
    wanted: poolsFor(n as never, pools as never).length > 0,
    // On disk, not in memory. `resident_models` empties whenever a model is
    // released, so using it here reported a machine holding 18GB of weights as
    // holding nothing and would have had an operator redistribute them.
    held: Object.prototype.hasOwnProperty.call(n.stored_models ?? {}, modelId),
    loaded: Object.prototype.hasOwnProperty.call(n.resident_models ?? {}, modelId),
  }))
}

/** One catalogue row, with the two counts that matter computed the same way. */
async function modelRow(db: Db, m: Record<string, unknown>) {
  const pools = (m.assigned_pools as string[]) ?? []
  const placement = pools.length > 0 ? await placementOf(db, m.id as string) : []
  return {
    id: m.id as string,
    runtime: m.runtime as string,
    kind: m.kind as string,
    sizeBytes: Number(m.size_bytes),
    contextLength: m.context_length === null ? null : Number(m.context_length),
    quantization: (m.quantization as string | null) ?? null,
    family: (m.family as string | null) ?? null,
    fileCount: Number(m.file_count),
    importedAt: m.imported_at ? new Date(m.imported_at as string).toISOString() : undefined,
    assignedPools: pools,
    nodesHolding: Number(m.nodes_holding ?? 0),
    nodesWanting: placement.filter((p) => p.wanted && !p.held).length,
  }
}

/**
 * Record a fleet-level action.
 *
 * Best effort on purpose: an audit write that fails must not fail the action it
 * describes, or a full disk turns "push a model" into an outage. It is logged
 * loudly instead, because an audit trail with silent holes is worse than one
 * that is known to be incomplete.
 */
/** What has been done to one model, most recent first. */
async function historyOf(db: Db, subject: string) {
  const { rows } = await db.query(
    `SELECT a.at, a.action, a.detail, u.email
       FROM audit_log a LEFT JOIN users u ON u.id = a.user_id
      WHERE a.subject = $1 ORDER BY a.at DESC LIMIT 20`, [subject])
  return rows.map((r) => ({
    at: new Date(r.at).toISOString(),
    action: r.action as string,
    by: (r.email as string | null) ?? null,
    detail: r.detail,
  }))
}

async function audit(
  db: Db, userId: string | null, action: string, subject: string,
  detail: Record<string, unknown> = {},
) {
  try {
    await db.query(
      `INSERT INTO audit_log (user_id, action, subject, detail) VALUES ($1,$2,$3,$4)`,
      [userId, action, subject, JSON.stringify(detail)],
    )
  } catch (e) {
    console.error(`audit write failed for ${action} ${subject}:`, e)
  }
}
