import { framesFor, outputsRoot, registerScene, sceneById } from '../lib/scenes.js'
import {
  attach, blobPath, expireOutputs, hashOf, outputPath, putBlob, retentionAfterCollection,
} from '../lib/attachments.js'
import { resolve as resolveOpenJD, frameOf, type JobTemplate } from '../lib/openjd.js'
import { repositoryRoot, safePath, verifyModel } from '../lib/repository.js'
import { COMPLETE_ENOUGH, holdsModel } from '../lib/possession.js'
import { coupledWith, effectiveModel, violations, type Group } from '../lib/groupRules.js'
import { splitReadiness, type RankFacts } from '../lib/splitReadiness.js'
import { runnability, shapeOf, whyGroupCannotHost } from '../lib/shape.js'
import { costOfServing, suspensions } from '../lib/suspension.js'
import { allocate, capacity, rangeFrom } from '../lib/ports.js'
import type { GroupListeners } from '../lib/groupSockets.js'
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
import { newEnrollmentToken } from '../lib/ca.js'
import type { Broker } from '../lib/broker.js'

/**
 * `listeners` is a getter rather than the thing itself: the routes are built
 * while the process is still deciding what it will bind, so capturing the
 * manager here would capture nothing.
 */
export function adminRoutes(db: Db, ca: Ca, broker: Broker,
                            listeners?: () => GroupListeners | undefined): Router {
  const r = Router()
  r.use(userAuth(db))

  r.get('/nodes', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT id, hostname, chip, memory_gb, metal_working_set_gb, tier, tiers, state,
              owner_user_id, presence_state, last_heartbeat, capability_profiles,
              model_sync_faults, last_model_sync, agent_version, agent_fingerprint,
              pipeline_address,
              user_paused, user_paused_at, resident_models, model_context
         -- Superseded records are history, not fleet. They are the previous
         -- enrollment of a machine that is still here under a newer identity,
         -- so listing them shows the same hardware twice, which is the problem
         -- superseding them was meant to solve.
         FROM nodes WHERE state <> 'superseded' ORDER BY hostname`,
    )

    // Which machines are out of harvesting because their cluster group is
    // serving a split model. A machine sitting idle for this reason has to read
    // as suspended and not as merely quiet: it is doing exactly what it was
    // told to, and an operator who cannot tell the difference goes looking for
    // a fault that is not there.
    const { rows: pools } = await db.query(
      `SELECT id, name, tier, membership, serving_model_id, enabled FROM pools`)
    const { rows: split } = await db.query(`SELECT id, machines FROM models WHERE machines > 1`)
    const machines = new Map((split as { id: string; machines: number }[])
      .map((m) => [m.id, Number(m.machines)]))
    const groups = (pools as any[]).map((p) => ({
      ...p, servingModelId: (p.serving_model_id as string | null) ?? null,
    })) as unknown as Group[]
    const held = new Map(
      suspensions(rows as never, groups, (id) => machines.get(id) ?? 1)
        .map((s) => [s.nodeId, s]))

    res.json(rows.map((n) => ({
      id: n.id,
      hostname: n.hostname,
      chip: n.chip,
      memoryGb: n.memory_gb === null ? null : Number(n.memory_gb),
      metalWorkingSetGb: n.metal_working_set_gb === null ? null : Number(n.metal_working_set_gb),
      tier: n.tier, tiers: n.tiers,
      state: n.state,
      ownerUserId: n.owner_user_id,
      // Surfaced beside the node rather than buried in its log. A machine that
      // has quietly stopped fetching what it was assigned is indistinguishable
      // from one that is up to date, and the count of nodes still wanting a
      // model never moves either way.
      syncFaults: n.model_sync_faults ?? {},
      lastModelSync: n.last_model_sync,
      // What this machine is running. The version is a claim the binary makes
      // about itself and can be wrong or absent; the fingerprint is the hash of
      // the executable and is the only evidence of what is actually deployed.
      // Both are shown, because a fleet that cannot name what it runs cannot be
      // audited - and on this fleet every node reported a placeholder while two
      // different binaries were in service.
      agentVersion: n.agent_version ?? null,
      agentFingerprint: n.agent_fingerprint ?? null,
      // Where a peer dials this machine for a split, which is not where the
      // control plane sees it connect from.
      pipelineAddress: n.pipeline_address ?? null,
      // Why this machine is not available to harvest, when it is not. Null for
      // every machine that is, which is nearly all of them.
      suspended: held.get(n.id as string)
        ? {
            modelId: held.get(n.id as string)!.modelId,
            machines: held.get(n.id as string)!.machines,
            by: held.get(n.id as string)!.by.name,
            from: held.get(n.id as string)!.from.map((g) => g.name),
          }
        : null,
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

  /**
   * Whether this operator may let machines into the fleet.
   *
   * Fleet-level rather than pool-scoped, the same check approval already makes:
   * enrolling a node is what decides which pools it can ever join, and minting
   * the token that lets one enrol is the same decision one step earlier.
   */
  async function mayAdmitMachines(userId: string): Promise<boolean> {
    const { rows } = await db.query(
      `SELECT 1 FROM role_bindings rb
         JOIN group_members gm ON gm.group_id = rb.group_id
        WHERE gm.user_id = $1 AND rb.role = 'admin' LIMIT 1`, [userId])
    return rows.length > 0
  }

  /**
   * Mint a join token.
   *
   * Starting a fleet was the one operation that was not api-first: `join_tokens`
   * was read at enrolment and written by nothing, so the documented way to add
   * the first machine to a new site was an INSERT typed into psql.
   *
   * Returned once and never again. The row keeps only what is needed to list and
   * revoke it - a credential nobody can enumerate is a credential nobody can
   * take away.
   *
   * A leaked token is a nuisance rather than a compromise: enrolment stores the
   * CSR without signing it, and signing happens at approval, so the worst it
   * buys is a pending row for a human to refuse.
   */
  r.post('/join-tokens', async (req, res) => {
    if (!(await mayAdmitMachines(req.user!.id))) {
      res.status(403).json({ error: 'forbidden', detail: 'admin role required' })
      return
    }
    const b = req.body as { expiresInHours?: number | null; note?: string }
    // A day by default. A token minted and forgotten is a live credential, and
    // the default matters more than the knob because most will never set one.
    const hours = b.expiresInHours ?? 24
    if (!Number.isFinite(hours) || hours <= 0 || hours > 24 * 30) {
      res.status(400).json({
        error: 'bad_request',
        detail: 'expiresInHours must be above zero and no more than 720 (30 days)',
      })
      return
    }
    const token = newEnrollmentToken()
    await db.query(
      `INSERT INTO join_tokens (token, expires_at) VALUES ($1, now() + ($2 || ' hours')::interval)`,
      [token, String(hours)])
    await audit(db, req.user!.id, 'join-token.mint', token.slice(0, 8),
      { expiresInHours: hours, note: b.note ?? null })
    res.status(201).json({ token, expiresInHours: hours })
  })

  /** Every join token, without the secret. */
  r.get('/join-tokens', async (req, res) => {
    if (!(await mayAdmitMachines(req.user!.id))) {
      res.status(403).json({ error: 'forbidden', detail: 'admin role required' })
      return
    }
    const { rows } = await db.query(
      `SELECT token, expires_at, used_at FROM join_tokens ORDER BY expires_at DESC`)
    res.json((rows as { token: string; expires_at: string; used_at: string | null }[])
      .map((t) => ({
        // Enough to recognise the one you just minted, and not enough to enrol
        // with. Returning the whole token here would make a list endpoint a way
        // of collecting credentials.
        prefix: t.token.slice(0, 8),
        expiresAt: t.expires_at ? new Date(t.expires_at).toISOString() : null,
        usedAt: t.used_at ? new Date(t.used_at).toISOString() : null,
        spent: t.used_at !== null,
      })))
  })

  /** Revoke one, by the prefix the list shows. */
  r.delete('/join-tokens/:prefix', async (req, res) => {
    if (!(await mayAdmitMachines(req.user!.id))) {
      res.status(403).json({ error: 'forbidden', detail: 'admin role required' })
      return
    }
    const { prefix } = req.params as { prefix: string }
    const { rowCount } = await db.query(
      `DELETE FROM join_tokens WHERE left(token, 8) = $1`, [prefix.slice(0, 8)])
    if (rowCount === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no join token with that prefix' })
      return
    }
    await audit(db, req.user!.id, 'join-token.revoke', prefix.slice(0, 8), {})
    res.status(204).end()
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
      `SELECT id, hostname, chip, memory_gb, metal_working_set_gb, tier, tiers, state,
              owner_user_id, presence_state, on_ac_power, thermal_ok,
              last_heartbeat, capability_profiles, allowed_cidrs,
              user_paused, user_paused_at, agent_version, agent_fingerprint,
              model_sync_faults, last_model_sync, cert_not_after, renew_requested_at
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
      // The version is what the binary says it is; the fingerprint is what it
      // actually hashes to. Only the second survives somebody replacing a
      // binary by hand, which is how this fleet ran two different builds while
      // every node reported the same placeholder.
      agentVersion: n.agent_version ?? null,
      agentFingerprint: n.agent_fingerprint ?? null,
      // When this node's certificate stops working, and whether somebody has
      // already asked for a new one. Both are here because the renewal control
      // is useless without them: a button with no expiry beside it invites
      // pressing it to find out, and one that does not show an outstanding
      // request invites pressing it again every time the page is opened.
      certNotAfter: n.cert_not_after ? new Date(n.cert_not_after).toISOString() : null,
      renewRequestedAt: n.renew_requested_at
        ? new Date(n.renew_requested_at).toISOString() : null,
      syncFaults: n.model_sync_faults ?? {},
      lastModelSync: n.last_model_sync,
      memoryGb: n.memory_gb === null ? null : Number(n.memory_gb),
      metalWorkingSetGb: n.metal_working_set_gb === null ? null : Number(n.metal_working_set_gb),
      tier: n.tier, tiers: n.tiers, state: n.state, ownerUserId: n.owner_user_id,
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
  /**
   * Which kinds of work this machine is offered for.
   *
   * Plural, and a machine may be in both. That is a real choice rather than a
   * label: cluster membership means presence does not gate serving, so an
   * interactive request can land on the machine while somebody is using it.
   * Batch work stays presence-gated either way, and the owner's pause still
   * overrides everything.
   *
   * Guarded the way pausing is - operator or admin somewhere in the fleet -
   * because a node is not in a pool until somebody puts it in one, so there is
   * no pool to check a role against. That is the same gap the review found on
   * approve and revoke, and it wants a fleet-level role rather than another
   * one-off.
   */
  r.put('/nodes/:nodeId/tiers', async (req, res) => {
    if (!(await mayPauseNode(db, req.user!.id, req.params.nodeId!))) {
      res.status(403).json({ error: 'forbidden', detail: 'not yours to change' })
      return
    }
    const wanted = (req.body as { tiers?: string[] })?.tiers ?? []
    const unique = [...new Set(wanted)]
    if (unique.length === 0) {
      res.status(400).json({ error: 'bad_request',
                             detail: 'a machine must be offered for at least one kind of work' })
      return
    }
    if (unique.some((t) => t !== 'harvest' && t !== 'cluster')) {
      res.status(400).json({ error: 'bad_request', detail: 'tiers are harvest and cluster' })
      return
    }

    const { rows } = await db.query(
      `UPDATE nodes SET tiers = $2::text[] WHERE id = $1
       RETURNING id, hostname, tier, tiers, state`,
      [req.params.nodeId, unique],
    )
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found' })
      return
    }
    await db.query(
      `INSERT INTO activity_log (node_id, event, detail) VALUES ($1,'node.tiers',$2)`,
      [req.params.nodeId, JSON.stringify({ tiers: unique, by: req.user!.id })],
    )
    res.json(rows[0])
  })

  /**
   * Ask a node to renew its certificate.
   *
   * Asked rather than done, because it cannot be done from here or from any
   * shell. The Enclave key signs only inside the node's launchd daemon - a
   * session whose keybag is not the daemon's fails with "unable to sign
   * digest", which is what `dai-agent renew` does over ssh even as root. The
   * daemon renews on its own at two thirds of certificate life, so without this
   * a machine that needs a new certificate today waits weeks.
   *
   * Three reasons to want one, and only the first is routine: a node enrolled
   * before the fleet had a node CA and cannot join a split without one; a
   * certificate suspected of having leaked; a CA that has been replaced.
   *
   * The flag rides down on the next heartbeat and is cleared when the renewal
   * arrives, so what is recorded is a request that was met.
   */
  r.post('/nodes/:nodeId/renew', async (req, res) => {
    const { rows } = await db.query(
      `UPDATE nodes SET renew_requested_at = now()
        WHERE id = $1 AND state IN ('active','paused','offline')
      RETURNING hostname`, [req.params.nodeId])
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no such node, or it cannot renew' })
      return
    }
    await audit(db, req.user!.id, 'node.renew-requested', rows[0].hostname as string, {})
    // 202: the node has not renewed, it has been asked. It will on its next
    // beat, and saying 204 here would claim something that has not happened.
    res.status(202).json({ hostname: rows[0].hostname, asked: true })
  })

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
              agent_channel, desired_agent_version, serving_model_id, serving_port,
              enabled, idle_unload_seconds, prompt_cache_gb
         FROM pools ORDER BY name`,
    )
    res.json(rows.map((p) => ({
      id: p.id, name: p.name, tier: p.tier, schedule: p.schedule,
      preempt: p.preempt, priority: p.priority,
      agentChannel: p.agent_channel,
      desiredAgentVersion: p.desired_agent_version ?? null,
      // What this group's machines run, as against what they hold.
      servingModelId: p.serving_model_id ?? null,
      // The socket this group answers on. Shown rather than kept internal: it
      // is the address somebody points an application at, and a port an
      // operator has to go and look up in a database is one they will get
      // wrong. Null for a group created before groups had sockets.
      servingPort: p.serving_port === null ? null : Number(p.serving_port),
      // Whether this group is asserting any of the above. A disabled group is
      // configuration at rest: everything here is still true of it and none of
      // it is in force.
      enabled: p.enabled !== false,
      // How long these machines hold a model once nothing is being asked of
      // them. Null means the fleet default, and a cluster group is never sent
      // one at all - dedicated means loaded.
      idleUnloadSeconds: p.idle_unload_seconds === null
        ? null : Number(p.idle_unload_seconds),
      promptCacheGb: p.prompt_cache_gb === null || p.prompt_cache_gb === undefined
        ? null : Number(p.prompt_cache_gb),
    })))
  })

  /**
   * How long this group's machines keep a model when nothing is asking.
   *
   * Not really a setting about weights. Unloading clears the prompt cache with
   * them and that is the expensive half: a loop that released too eagerly once
   * turned a 0.5s warm request into 37.5s, an 18s reload and a full prefill on
   * every one. Read it as how long to keep a conversation warm.
   *
   * Null restores the fleet default. Meaningless on a cluster group, which is
   * dedicated and holds its model for as long as it stands - accepted rather
   * than refused there, because an operator moving a group between tiers should
   * not have a setting silently rejected on the way.
   */
  r.put('/pools/:poolId/idle-unload', async (req, res) => {
    const { poolId } = req.params as { poolId: string }
    const seconds = (req.body as { seconds?: number | null })?.seconds ?? null

    if (seconds !== null && (!Number.isInteger(seconds) || seconds < 1)) {
      res.status(400).json({
        error: 'bad_request',
        detail: 'seconds must be a whole number of seconds, or null for the default',
      })
      return
    }
    const { rowCount } = await db.query(
      `UPDATE pools SET idle_unload_seconds = $2 WHERE id = $1`, [poolId, seconds])
    if (rowCount === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no such group' })
      return
    }
    await audit(db, req.user!.id, 'pool.idle-unload', poolId, { seconds })
    res.json({ idleUnloadSeconds: seconds })
  })

  /**
   * How much prompt cache this group's machines may hold.
   *
   * Bounds conversations kept warm, not weights. A machine used to hold exactly
   * one prefix, so two clients evicted each other every turn and both paid a full
   * prefill - 363 s on a 19,243-token conversation - while the cache still
   * occupied the memory. Two callers were worse off than one.
   *
   * The machine clamps this against its own memory: the group says what it is
   * for, and the machine knows what it actually has.
   */
  r.put('/pools/:poolId/prompt-cache', async (req, res) => {
    const { poolId } = req.params as { poolId: string }
    const gb = (req.body as { gb?: number | null })?.gb ?? null

    // Zero is allowed and negative is not. Zero means "keep nothing warm", which
    // is a legitimate choice for a machine with no memory to spare - unlike a
    // zero idle window, which unloads after every request and is refused.
    if (gb !== null && (!Number.isFinite(gb) || gb < 0)) {
      res.status(400).json({
        error: 'bad_request',
        detail: 'gb must be a number of gigabytes at or above zero, '
          + 'or null for the fleet default',
      })
      return
    }
    const { rowCount } = await db.query(
      `UPDATE pools SET prompt_cache_gb = $2 WHERE id = $1`, [poolId, gb])
    if (rowCount === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no such group' })
      return
    }
    await audit(db, req.user!.id, 'pool.prompt-cache', poolId, { gb })
    res.json({ promptCacheGb: gb })
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
      // The socket, allocated here rather than at first use. A group that
      // exists but cannot be addressed is a group somebody has to be told
      // about separately, and the whole point of a port per group is that
      // there is nothing to tell: the address is the routing.
      const range = rangeFrom(process.env.DAI_GROUP_PORT_RANGE)
      const { rows: held } = await db.query(
        `SELECT serving_port FROM pools WHERE serving_port IS NOT NULL`)
      const { rows: retired } = await db.query(`SELECT port, at FROM retired_sockets`)
      const chosen = allocate(held.map((r) => Number(r.serving_port)),
                              retired as { port: number; at: string }[], range)
      const port = chosen?.port ?? null
      if (port === null) {
        res.status(409).json({
          error: 'conflict',
          detail: `every socket in ${range.from}-${range.to} is taken; `
            + `${capacity(range)} groups is the limit until one is deleted `
            + 'or DAI_GROUP_PORT_RANGE is widened',
        })
        return
      }
      // A reused port stops being retired. Leaving the row would hold it back
      // from the group that is now using it the next time somebody allocates.
      if (chosen?.reused) {
        await db.query(`DELETE FROM retired_sockets WHERE port = $1`, [port])
      }
      const { rows } = await db.query(
        `INSERT INTO pools (name, tier, schedule, preempt, serving_port)
         VALUES ($1, $2, $3, $4, $5) RETURNING id, name, tier, serving_port`,
        [b.name, b.tier ?? 'harvest',
         b.tier === 'cluster' ? 'gang' : 'independent-units',
         b.tier === 'cluster' ? 'never' : 'on-user-activity', port],
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
      await audit(db, req.user!.id, 'pool.create', pool.name,
                  { tier: pool.tier, servingPort: pool.serving_port })
      // Bound now, so the port in this response is one that answers. A group
      // whose socket only appeared on the next restart would be a group that
      // looked created and refused connections.
      //
      // And if it cannot be bound, the group does not exist. Something else on
      // the host holding that port would otherwise leave a group that is
      // created, assignable, and unreachable - which is worse than a creation
      // that refused, because only the refusal says so.
      try {
        await listeners?.()?.open(Number(pool.serving_port))
      } catch (err) {
        await db.query(`DELETE FROM pools WHERE id = $1`, [pool.id])
        res.status(409).json({
          error: 'conflict',
          detail: `port ${pool.serving_port} could not be bound, so ${b.name} was not `
            + `created: ${(err as Error).message}`,
        })
        return
      }
      res.status(201).json({ id: pool.id, name: pool.name, tier: pool.tier,
                             servingPort: Number(pool.serving_port) })
    } catch (e) {
      if ((e as { code?: string }).code === '23505') {
        res.status(409).json({ error: 'conflict', detail: `a group called ${b.name} exists` })
        return
      }
      throw e
    }
  })

  /**
   * Delete a group.
   *
   * Everything scoped to it goes with it: its jobs and their work units, which
   * models it was pushing, and who had a role on it. Its machines are freed,
   * because membership lives on this row - there is nothing to tidy up on them.
   *
   * Said before it is done, because none of that is recoverable and the machines
   * are the only part an operator is usually thinking about. Standing the group
   * down is the reversible version, and the message says so.
   *
   * The socket is retired rather than freed. A client left pointing at the old
   * URL would otherwise start talking to a different group's machines without
   * anything having changed at its end.
   */
  r.delete('/pools/:poolId', async (req, res) => {
    const { poolId } = req.params as { poolId: string }
    if (!(await requireRole(db, req.user!.id, poolId, 'admin'))) {
      res.status(403).json({ error: 'forbidden', detail: 'admin role required on this pool' })
      return
    }
    const { rows } = await db.query(
      `SELECT name, tier, serving_port, membership FROM pools WHERE id = $1`, [poolId])
    const pool = rows[0] as {
      name: string; tier: string; serving_port: number | null; membership: unknown
    } | undefined
    if (!pool) { res.status(404).json({ error: 'not_found', detail: 'no such group' }); return }

    const { rows: counts } = await db.query(
      `SELECT (SELECT count(*)::int FROM jobs WHERE pool_id = $1) AS jobs,
              (SELECT count(*)::int FROM pool_models WHERE pool_id = $1) AS models`, [poolId])
    const { jobs, models } = counts[0] as { jobs: number; models: number }
    const { rows: nodes } = await db.query(
      `SELECT id, hostname, tier, chip, memory_gb FROM nodes WHERE state = 'active'`)
    const freed = (nodes as never[])
      .filter((n: never) => poolsFor(n, [pool] as never).length > 0)
      .map((n: { hostname: string }) => n.hostname)

    if ((req.query.confirm as string) !== 'true') {
      const goes = [
        jobs > 0 ? `${jobs} job${jobs === 1 ? '' : 's'} and their work` : null,
        models > 0 ? `${models} model assignment${models === 1 ? '' : 's'}` : null,
        'every role anybody holds on it',
      ].filter(Boolean).join(', ')
      res.status(409).json({
        error: 'confirm_required',
        detail: `deleting ${pool.name} also deletes ${goes}, and none of it comes back. `
          + `${freed.length} machine${freed.length === 1 ? '' : 's'} would be freed`
          + `${pool.serving_port ? `, and port ${pool.serving_port} retired rather than reused` : ''}`
          + '. To take its machines back without losing any of this, stand it down instead.',
        frees: freed,
      })
      return
    }

    if (pool.serving_port !== null) {
      await db.query(
        `INSERT INTO retired_sockets (port, was) VALUES ($1, $2) ON CONFLICT (port) DO NOTHING`,
        [pool.serving_port, pool.name])
      await listeners?.()?.close(Number(pool.serving_port))
    }
    await db.query(`DELETE FROM pools WHERE id = $1`, [poolId])
    await audit(db, req.user!.id, 'pool.delete', pool.name,
                { jobs, models, freed, retiredPort: pool.serving_port })
    res.json({ name: pool.name, frees: freed, retiredPort: pool.serving_port })
  })

  /**
   * Stand a group down, or bring it back.
   *
   * A disabled group keeps everything it was configured with and asserts none
   * of it: it decides nothing about what its machines serve, suspends nobody,
   * hands out no work, and refuses on its own socket. Its machines, its model
   * and its port are all still there.
   *
   * That is what makes it different from deleting. A cluster group overrides
   * the harvest group it shares machines with, so the way to hand those
   * machines back - and let the harvest group's own model take effect - is to
   * stand the cluster group down for the evening, not to dismantle it and
   * rebuild it from memory tomorrow.
   */
  r.put('/pools/:poolId/enabled', async (req, res) => {
    const { poolId } = req.params as { poolId: string }
    const wanted = (req.body as { enabled?: boolean })?.enabled
    if (typeof wanted !== 'boolean') {
      res.status(400).json({ error: 'bad_request', detail: 'enabled must be true or false' })
      return
    }
    if (!(await requireRole(db, req.user!.id, poolId, 'admin'))) {
      res.status(403).json({ error: 'forbidden', detail: 'admin role required on this pool' })
      return
    }
    const { rows } = await db.query(
      `UPDATE pools SET enabled = $2 WHERE id = $1 RETURNING name, enabled`, [poolId, wanted])
    const pool = rows[0] as { name: string; enabled: boolean } | undefined
    if (!pool) { res.status(404).json({ error: 'not_found', detail: 'no such group' }); return }
    await audit(db, req.user!.id, wanted ? 'pool.enable' : 'pool.disable', pool.name, {})

    // What the fleet will do about it, said rather than left to be noticed. A
    // disabled cluster group hands its machines back, and the model they take
    // up next is whatever their harvest group asks for - which is usually the
    // reason somebody pressed this.
    const { rows: pools } = await db.query(
      `SELECT id, name, tier, membership, serving_model_id, enabled FROM pools`)
    const groups = (pools as any[]).map((p) => ({
      ...p, servingModelId: p.serving_model_id ?? null,
    })) as unknown as Group[]
    const { rows: nodes } = await db.query(
      `SELECT id, hostname, tier, chip, memory_gb FROM nodes WHERE state = 'active'`)
    // Whose machines these are, asked of the rule rather than of the claim.
    //
    // poolsFor drops a stood-down group, which is right everywhere it decides
    // something - and wrong here, where the question is "who did this just
    // affect". The operator pressed stand-down to get machines back, and
    // listing none of them because it worked is the least useful possible
    // answer. So membership is asked with the group treated as standing.
    const target = { ...pools.find((p) => p.id === poolId), enabled: true }
    const affected = (nodes as never[])
      .filter((n: never) => poolsFor(n, [target] as never).length > 0)
      .map((n: { hostname: string }) => ({
        hostname: n.hostname,
        nowServes: effectiveModel(n as never, groups),
      }))
    res.json({ name: pool.name, enabled: pool.enabled, machines: affected })
  })

  /**
   * Give a group a socket of its own.
   *
   * For the groups that predate sockets. The schema deliberately does not
   * backfill them - binding listeners nobody asked for, during an upgrade, on a
   * machine nobody is watching, is how a control plane comes back up holding
   * ports somebody else wanted. So it is asked for, once, per group.
   *
   * Idempotent: a group that already has one is told which, rather than being
   * given a second and abandoning the first while clients are pointed at it.
   */
  r.put('/pools/:poolId/socket', async (req, res) => {
    const { poolId } = req.params as { poolId: string }
    if (!(await requireRole(db, req.user!.id, poolId, 'admin'))) {
      res.status(403).json({ error: 'forbidden', detail: 'admin role required on this pool' })
      return
    }
    const { rows } = await db.query(
      `SELECT name, serving_port FROM pools WHERE id = $1`, [poolId])
    const pool = rows[0] as { name: string; serving_port: number | null } | undefined
    if (!pool) { res.status(404).json({ error: 'not_found', detail: 'no such group' }); return }
    if (pool.serving_port !== null) {
      res.json({ servingPort: Number(pool.serving_port), allocated: false })
      return
    }

    const range = rangeFrom(process.env.DAI_GROUP_PORT_RANGE)
    const { rows: held } = await db.query(
      `SELECT serving_port FROM pools WHERE serving_port IS NOT NULL`)
    const { rows: retired } = await db.query(`SELECT port, at FROM retired_sockets`)
    const chosen = allocate(held.map((r) => Number(r.serving_port)),
                            retired as { port: number; at: string }[], range)
    const port = chosen?.port ?? null
    if (port === null) {
      res.status(409).json({
        error: 'conflict',
        detail: `every socket in ${range.from}-${range.to} is taken; `
          + `${capacity(range)} groups is the limit until the range is widened`,
      })
      return
    }
    if (chosen?.reused) {
      await db.query(`DELETE FROM retired_sockets WHERE port = $1`, [port])
    }
    await db.query(`UPDATE pools SET serving_port = $2 WHERE id = $1`, [poolId, port])
    try {
      await listeners?.()?.open(port)
    } catch (err) {
      // Put it back rather than leaving the group recorded at a port that is
      // not answering, which is the state health exists to shout about.
      await db.query(`UPDATE pools SET serving_port = NULL WHERE id = $1`, [poolId])
      res.status(409).json({
        error: 'conflict',
        detail: `port ${port} could not be bound: ${(err as Error).message}`,
      })
      return
    }
    await audit(db, req.user!.id, 'pool.socket', pool.name, { servingPort: port })
    res.json({ servingPort: port, allocated: true })
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
  /**
   * What this group's machines run.
   *
   * Distinct from pushing a model to a group, which says what they should
   * hold. A machine holds many models and loads one, so this is the only part
   * that two groups sharing a machine are not allowed to disagree about.
   *
   * Refused with the machine named, because the alternative is an operator
   * discovering the coupling from a behaviour rather than a message - and the
   * coupling is transitive, so the group they are told about may not be one
   * they were thinking about.
   */
  r.put('/pools/:poolId/serving-model', async (req, res) => {
    const poolId = req.params.poolId!
    const modelId = (req.body as { modelId?: string | null })?.modelId ?? null

    const { rows: pools } = await db.query(
      `SELECT id, name, tier, membership, serving_model_id, enabled FROM pools`)
    const current = pools.find((p) => p.id === poolId)
    if (!current) { res.status(404).json({ error: 'not_found', detail: 'no such group' }); return }

    let model: { size_bytes: number; machines: number; min_memory_gb: number | null } | null = null
    if (modelId !== null) {
      const { rows: known } = await db.query(
        `SELECT size_bytes, machines, min_memory_gb FROM models WHERE id = $1`, [modelId])
      if (known.length === 0) {
        res.status(404).json({ error: 'not_found', detail: `no model called ${modelId}` })
        return
      }
      model = known[0] as never
    }

    const { rows: nodes } = await db.query(
      `SELECT id, hostname, tier, chip, memory_gb, metal_working_set_gb
         FROM nodes WHERE state = 'active'`)

    // Can this group actually run it? Asked here rather than at dispatch, where
    // the answer arrives as a request that hangs, weeks later, found by whoever
    // happens to send one.
    if (model) {
      const shape = shapeOf(model)
      const members = (nodes as never[])
        .filter((n: never) => poolsFor(n, [current] as never).length > 0)
        .map((n: { hostname: string; metal_working_set_gb: string | null }) => ({
          hostname: n.hostname,
          metalWorkingSetGb: n.metal_working_set_gb === null
            ? null : Number(n.metal_working_set_gb),
        }))
      const why = whyGroupCannotHost(members, shape)
      if (why) {
        res.status(409).json({
          error: 'conflict',
          detail: `${current.name} cannot run ${modelId}: ${why}`,
        })
        return
      }
    }

    // Checked against the state this would create, not against the change, so
    // every reason it cannot exist comes back at once.
    const proposed: Group[] = pools.map((p) => ({
      id: p.id, name: p.name, tier: p.tier, membership: p.membership,
      servingModelId: p.id === poolId ? modelId : p.serving_model_id,
      // Carried, not dropped. `active()` filters on `enabled !== false`, so a
      // group arriving here without the field reads as enabled - and a group
      // that was stood down went on counting against one-group-per-tier. The
      // symptom is a refusal naming a disabled group as a reason, which is a
      // rule nobody can satisfy without deleting something they meant to keep.
      enabled: p.enabled !== false,
    }))
    const broken = violations(nodes as never, proposed)
    if (broken.length > 0) {
      res.status(409).json({
        error: 'conflict',
        detail: broken.map((v) => v.detail).join('; '),
        violations: broken,
      })
      return
    }

    // What this will cost, before it costs it.
    //
    // An N-way split takes N workstations out of harvesting for as long as the
    // group serves it, because a gang cannot be preempted and harvest
    // membership is the promise that a machine can be taken away. The operator
    // is trading harvest capacity for a model that would not otherwise run at
    // all, which is a decision rather than a side effect - so it is said, and
    // then confirmed, in the same shape this codebase already uses for the
    // other change that quietly means more than it looks like.
    const machines = model === null ? 1 : Number((model as { machines: number }).machines)
    if (model && machines > 1
        && !(req.body as { confirm?: boolean })?.confirm) {
      const members = (nodes as never[]).filter(
        (n: never) => poolsFor(n, [current] as never).length > 0)
      const cost = costOfServing(modelId!, machines, members as never, pools as never)
      if (cost) {
        res.status(409).json({ error: 'confirm_required', detail: cost })
        return
      }
    }

    await db.query(`UPDATE pools SET serving_model_id = $2 WHERE id = $1`, [poolId, modelId])
    await audit(db, req.user!.id, 'pool.serving-model', current.name, { modelId })
    res.status(204).end()
  })

  /**
   * Which other groups are forced to agree with this one.
   *
   * Agreement spreads through shared machines, so a group can be constrained by
   * one it shares nothing with. Asked for rather than discovered.
   */
  /**
   * Whether this group could serve a request right now, and what is missing.
   *
   * Asked before anybody sends anything. Standing a split up meant enabling the
   * group and then waiting with nothing to look at while the weights arrived,
   * and the first sign it was not ready came from sending a request and reading
   * the refusal - a diagnostic disguised as a failure, minutes after an operator
   * could have acted on it.
   */
  /**
   * Tell a group to serve a model: how wide, hold the weights, run it.
   *
   * These are three writes in an order that matters, and until now every caller
   * did them separately. Declaring the width has to come first, because a group
   * cannot be given a model that runs across machines before the model says it
   * does - and the refusal for the other order names a rule rather than an
   * order, which reads as a fault.
   *
   * The middle one was simply missing. Serving a model and holding it are
   * different tables: `pools.serving_model_id` decides what a group's machines
   * run, `pool_models` decides what they fetch. Setting only the first leaves a
   * group waiting forever with nothing fetching anything, and it went unnoticed
   * because every model on this fleet had been pushed long before.
   *
   * Named for what it does rather than for splits. `machines: 1` is a dedicated
   * group holding a whole model - the same three writes, and the only difference
   * is that nobody dials anybody.
   *
   * Not a transaction, and worth saying so. The order is chosen so the
   * half-states are inert: a width nobody serves is a number, and weights nobody
   * serves is a download. It is idempotent, so running it again finishes it.
   */
  r.put('/pools/:poolId/serve', async (req, res) => {
    const { poolId } = req.params as { poolId: string }
    const b = req.body as { modelId?: string | null; machines?: number; confirm?: boolean }
    const modelId = b.modelId
    const machines = Math.max(1, Number(b.machines ?? 1))

    // Unpinning is the pin coming off and nothing else, so it is its own path.
    //
    // Explicitly null, not merely absent: "serve whatever you hold" and "you
    // forgot to say what to serve" are different requests, and one of them is a
    // mistake worth a 400.
    //
    // The weights stay, because they are what it will serve from - `pool_models`
    // is the staging set, and clearing it here would turn a change of policy
    // into ~18 GB per model to fetch again. Nothing is dropped, so pinning the
    // group back to any of these costs nothing.
    //
    // No confirmation either: standing the group up is where its machines left
    // harvesting, and this does not spend anything they had not already spent.
    if ('modelId' in b && b.modelId === null) {
      const { rows } = await db.query(
        `SELECT name, tier FROM pools WHERE id = $1`, [poolId])
      const group = rows[0] as { name: string; tier: string } | undefined
      if (!group) {
        res.status(404).json({ error: 'not_found', detail: 'no such group' }); return
      }
      if (group.tier !== 'cluster') {
        res.status(409).json({
          error: 'conflict',
          detail: `${group.name} is a ${group.tier} group. Only a cluster group can serve `
            + 'whatever it is staged with: a harvest machine can be taken back the moment '
            + 'somebody touches a keyboard, and a gang cannot be preempted mid-request.',
        })
        return
      }
      await db.query(`UPDATE pools SET serving_model_id = NULL WHERE id = $1`, [poolId])
      await audit(db, req.user!.id, 'pool.serve', poolId, { modelId: null })
      const { rows: staged } = await db.query(
        `SELECT model_id FROM pool_models WHERE pool_id = $1 ORDER BY model_id`, [poolId])
      res.json({
        group: group.name, modelId: null,
        serves: (staged as { model_id: string }[]).map((s) => s.model_id),
      })
      return
    }

    if (!modelId) {
      res.status(400).json({ error: 'bad_request', detail: 'modelId is required' })
      return
    }

    const { rows: pools } = await db.query(
      `SELECT id, name, tier, membership, serving_model_id, enabled
         FROM pools WHERE id = $1`, [poolId])
    const pool = pools[0] as { name: string; tier: string } | undefined
    if (!pool) { res.status(404).json({ error: 'not_found', detail: 'no such group' }); return }

    const { rows: known } = await db.query(
      `SELECT size_bytes, min_memory_gb FROM models WHERE id = $1`, [modelId])
    if (known.length === 0) {
      res.status(404).json({ error: 'not_found', detail: `no model called ${modelId}` })
      return
    }

    const { rows: nodes } = await db.query(
      `SELECT id, hostname, tier, chip, memory_gb, metal_working_set_gb
         FROM nodes WHERE state = 'active'`)
    const members = (nodes as never[]).filter(
      (n: never) => poolsFor(n, [pool] as never).length > 0)

    // Can these machines actually run it, at this width? Asked here rather than
    // at dispatch, where the answer arrives as a request that hangs.
    const shape = shapeOf({
      size_bytes: (known[0] as { size_bytes: number }).size_bytes,
      machines,
      min_memory_gb: (known[0] as { min_memory_gb: number | null }).min_memory_gb ?? null,
    })
    const why = whyGroupCannotHost(
      (members as { hostname: string; metal_working_set_gb: string | null }[]).map((n) => ({
        hostname: n.hostname,
        metalWorkingSetGb: n.metal_working_set_gb === null
          ? null : Number(n.metal_working_set_gb),
      })), shape)
    if (why) {
      res.status(409).json({
        error: 'conflict', detail: `${pool.name} cannot run ${modelId}: ${why}`,
      })
      return
    }

    // What it costs, before it costs it. A split takes those machines out of
    // harvesting for as long as it stands, which is a decision rather than a
    // side effect.
    if (!b.confirm) {
      const { rows: allPools } = await db.query(
        `SELECT id, name, tier, membership, serving_model_id, enabled FROM pools`)
      const cost = costOfServing(modelId, machines, members as never,
        (allPools as any[]).map((p) => ({
          ...p, servingModelId: p.serving_model_id ?? null,
          enabled: p.enabled !== false,
        })) as never)
      if (cost) {
        res.status(409).json({ error: 'confirm_required', detail: cost })
        return
      }
    }

    await db.query(`UPDATE models SET machines = $2 WHERE id = $1`, [modelId, machines])
    await db.query(
      `INSERT INTO pool_models (pool_id, model_id, assigned_by) VALUES ($1,$2,$3)
       ON CONFLICT DO NOTHING`, [poolId, modelId, req.user!.id])
    await db.query(
      `UPDATE pools SET serving_model_id = $2 WHERE id = $1`, [poolId, modelId])
    await audit(db, req.user!.id, 'pool.serve', poolId, { modelId, machines })

    res.json({
      group: pool.name, modelId, machines,
      perMachineGb: Number(shape.perMachineGb.toFixed(2)),
      machinesInGroup: members.length,
    })
  })

  r.get('/pools/:poolId/readiness', async (req, res) => {
    const { poolId } = req.params as { poolId: string }
    const { rows: pools } = await db.query(
      `SELECT id, name, tier, membership, serving_model_id, enabled
         FROM pools WHERE id = $1`, [poolId])
    const pool = pools[0] as {
      name: string; tier: string; serving_model_id: string | null; enabled: boolean
    } | undefined
    if (!pool) { res.status(404).json({ error: 'not_found', detail: 'no such group' }); return }

    const machines = pool.serving_model_id === null ? 1 : Number(
      ((await db.query(`SELECT machines FROM models WHERE id = $1`,
        [pool.serving_model_id])).rows[0] as { machines: number } | undefined)?.machines ?? 1)

    const { rows: nodes } = await db.query(
      `SELECT id, hostname, tier, chip, memory_gb, resident_models, model_context,
              pipeline_address, model_sync_faults, last_heartbeat
         FROM nodes WHERE state = 'active'`)

    // Whether this group's machines have been told to hold the model at all.
    //
    // Serving it and holding it are different tables: pools.serving_model_id
    // decides what they run, pool_models decides what they fetch. This read the
    // serving model and compared it against itself, so the branch that says
    // "nothing was ever asked for" could not fire - a group set to serve a model
    // nobody had pushed reported "fetching the weights" indefinitely, about
    // machines fetching nothing.
    const { rows: held } = await db.query(
      `SELECT 1 FROM pool_models WHERE pool_id = $1 AND model_id = $2`,
      [poolId, pool.serving_model_id])
    const toldToHold = held.length > 0 ? pool.serving_model_id : null

    // What a group that names no model can be asked for. The same table, read
    // as the whole set rather than checked for one row: staging is what it
    // serves from, not a step on the way to serving something else.
    const { rows: stagedRows } = pool.serving_model_id === null
      ? await db.query(
          `SELECT m.id, m.machines FROM models m
             JOIN pool_models pm ON pm.model_id = m.id
            WHERE pm.pool_id = $1`, [poolId])
      : { rows: [] as unknown[] }
    const staged = (stagedRows as { id: string; machines: number | null }[])
      .map((m) => ({ modelId: m.id, machines: Math.max(1, Number(m.machines ?? 1)) }))

    // The group's own machines, by the same membership rule everything else
    // uses, so this describes the group an operator is looking at rather than
    // the fleet.
    const members: RankFacts[] = (nodes as any[])
      .filter((n) => poolsFor(n as never, [pool] as never).length > 0)
      .map((n) => ({
        nodeId: n.id,
        hostname: n.hostname,
        // Heartbeat, not the reverse channel: a node reading a long prompt is
        // not parked, and calling it disconnected would report a working
        // machine as missing.
        connected: n.last_heartbeat != null
          && Date.now() - new Date(n.last_heartbeat).getTime() < 120_000,
        assigned: toldToHold,
        // On disk is what the node has fetched; model_context is written when a
        // model has been opened, which is the only evidence available that the
        // weights are actually here.
        onDisk: Object.keys((n.model_context ?? {}) as Record<string, unknown>),
        loaded: Object.keys((n.resident_models ?? {}) as Record<string, unknown>),
        pipelineAddress: n.pipeline_address ?? null,
        syncFault: Object.values((n.model_sync_faults ?? {}) as Record<string, string>)[0]
          ?? null,
      }))

    res.json({
      group: pool.name,
      tier: pool.tier,
      ...splitReadiness({
        enabled: pool.enabled !== false,
        model: pool.serving_model_id,
        machines,
        members,
        staged,
      }),
    })
  })

  r.get('/pools/:poolId/coupled', async (req, res) => {
    const { rows: pools } = await db.query(
      `SELECT id, name, tier, membership, serving_model_id, enabled FROM pools`)
    const groups: Group[] = pools.map((p) => ({
      id: p.id, name: p.name, tier: p.tier, membership: p.membership,
      servingModelId: p.serving_model_id,
      enabled: p.enabled !== false,
    }))
    const mine = groups.find((g) => g.id === req.params.poolId)
    if (!mine) { res.status(404).json({ error: 'not_found', detail: 'no such group' }); return }

    const { rows: nodes } = await db.query(
      `SELECT id, hostname, tier, chip, memory_gb FROM nodes WHERE state = 'active'`)
    res.json(coupledWith(mine, nodes as never, groups)
      .map((g) => ({ id: g.id, name: g.name, tier: g.tier, servingModelId: g.servingModelId })))
  })

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
      // enabled, because poolsFor drops a stood-down group and cannot do that
      // without the column. Omitting it let a disabled group keep naming the
      // agent version the whole fleet should run.
      `SELECT id, name, tier, membership, agent_channel, desired_agent_version,
              enabled
         FROM pools`)
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
              m.quantization, m.family, m.imported_at, m.machines, m.min_memory_gb,
              count(DISTINCT f.path)::int AS file_count,
              coalesce(array_agg(DISTINCT pm.pool_id)
                       FILTER (WHERE pm.pool_id IS NOT NULL), '{}') AS assigned_pools,
              -- Having the model, not having started to fetch it. The node
              -- reports gibibytes and the catalogue records bytes; a partial
              -- transfer reports the key from its first block, and counting
              -- that made the fleet claim distribution was complete at six
              -- percent.
              (SELECT count(*)::int FROM nodes n
                WHERE n.state = 'active'
                  AND (n.stored_models ->> m.id)::numeric * 1073741824
                      >= m.size_bytes::numeric * $1) AS nodes_holding
         FROM models m
         LEFT JOIN model_files f ON f.model_id = m.id
         LEFT JOIN pool_models pm ON pm.model_id = m.id
        GROUP BY m.id
        ORDER BY m.id`,
      [COMPLETE_ENOUGH],
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
  /**
   * How many machines a model runs across.
   *
   * Declared rather than derived: whether a 40GB model runs on one machine or
   * two is a decision about the fleet, not a property of the weights. Until
   * this existed the columns could be read and never written, which made shape
   * something only a migration could set.
   *
   * Refused when no group could run it. A model declared to need more machines
   * than the fleet has anywhere is not a plan, it is a request that will be
   * refused at every dispatch - and finding that out now is the whole point of
   * declaring shape at all.
   */
  r.put('/models/:modelId/shape', async (req, res) => {
    const id = decodeURIComponent(req.params.modelId!)
    const b = req.body as { machines?: number; minMemoryGb?: number | null }
    const machines = Math.max(1, Number(b.machines ?? 1))

    const { rows } = await db.query(
      `SELECT size_bytes FROM models WHERE id = $1`, [id])
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found', detail: `no model called ${id}` })
      return
    }

    const shape = shapeOf({
      size_bytes: rows[0].size_bytes as number,
      machines,
      min_memory_gb: b.minMemoryGb ?? null,
    })
    const groups = await runnableGroups(db, {
      id, size_bytes: rows[0].size_bytes, machines, min_memory_gb: b.minMemoryGb ?? null,
    })
    // Blocked everywhere is a shape nothing can run. Pending is fine - the
    // weights are on their way - and so is a group that is simply too small
    // while another is not.
    if (groups.length > 0 && groups.every((g) => g.state === 'blocked')) {
      res.status(409).json({
        error: 'conflict',
        detail: `no group can run ${id} across ${machines} machines: `
          + groups.map((g) => `${g.name}: ${g.detail}`).join('; '),
      })
      return
    }

    await db.query(
      `UPDATE models SET machines = $2, min_memory_gb = $3 WHERE id = $1`,
      [id, machines, b.minMemoryGb ?? null])
    await audit(db, req.user!.id, 'model.shape', id, { machines })
    res.json({ id, machines, perMachineGb: Number(shape.perMachineGb.toFixed(2)), runnableIn: groups })
  })

  r.get('/models/available', async (_req, res) => {
    const { rows } = await db.query(`SELECT id FROM models`)
    res.json(await candidates(new Set(rows.map((r2) => r2.id as string))))
  })

  /**
   * Whether the repository still holds what the catalogue promises.
   *
   * Answers the question nobody could ask before: this fleet's catalogue listed
   * a model with eleven files and 18.4GB, and the directory was not there. The
   * nodes serving it had fetched their copies earlier, so nothing was visibly
   * broken until a new machine tried to fetch it - and that machine might not
   * exist for months.
   *
   * Cheap by default so it can be run often, or wired to a check. `?deep=1`
   * hashes every byte, which is minutes for a large model and the right thing
   * to reach for when you suspect corruption rather than absence.
   */
  r.get('/models/verify', async (req, res) => {
    const deep = req.query.deep === '1' || req.query.deep === 'true'
    const root = repositoryRoot()
    const { rows: models } = await db.query(`SELECT id FROM models ORDER BY id`)

    const reports = []
    for (const m of models as { id: string }[]) {
      const { rows: files } = await db.query(
        `SELECT path, size_bytes, sha256 FROM model_files WHERE model_id=$1 ORDER BY path`,
        [m.id])
      reports.push(await verifyModel(root, m.id, files.map((f) => ({
        path: f.path as string,
        sizeBytes: Number(f.size_bytes),
        sha256: f.sha256 as string,
      })), deep))
    }

    const broken = reports.filter((x) => !x.ok)
    res.json({
      root,
      deep,
      models: reports.length,
      healthy: reports.length - broken.length,
      broken: broken.length,
      bytesMissing: broken.reduce((n, x) => n + x.bytesMissing, 0),
      reports,
    })
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
      placement: await placementOf(db, id, rows[0].size_bytes),
      // Which groups could actually run this, and for those that cannot,
      // whether that is a transfer still running or a group that never will.
      // Holding is per machine; running is a property of a group, and until
      // this existed nothing answered it.
      runnableIn: await runnableGroups(db, rows[0]),
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
    const scenes = attachments.filter((a) => a.path.toLowerCase().endsWith('.blend'))
    const entry = b.entryPath ?? (scenes.length === 1 ? scenes[0]!.path : undefined)
    if (!entry) {
      // Refused rather than resolved by a rule like "the first one". Picking
      // silently means rendering a different scene from the one the submitter
      // meant, and nothing downstream says so: the frames simply come out
      // wrong. The older scene catalogue got this right and this did not.
      const detail = scenes.length === 0
        ? 'no scene among the attachments; name one with entryPath'
        : `more than one scene attached, name one with entryPath: `
          + scenes.map((a) => a.path).sort().join(', ')
      res.status(400).json({ error: 'bad_request', detail })
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
async function placementOf(db: Db, modelId: string, sizeBytes?: unknown) {
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
    // Complete, not merely begun. See holdsModel: the key appears as soon as a
    // transfer writes its first block.
    held: holdsModel((n.stored_models ?? {})[modelId], sizeBytes),
    loaded: Object.prototype.hasOwnProperty.call(n.resident_models ?? {}, modelId),
  }))
}


/**
 * Which groups can run a model, and what is stopping the ones that cannot.
 *
 * Possession is per machine and reported per machine. Whether a model can
 * actually be served is a question about a group: enough machines, each big
 * enough, each holding the weights. A fleet that can only answer the first
 * cannot tell an operator why a model they assigned is not being served.
 */
async function runnableGroups(db: Db, model: Record<string, unknown>) {
  const shape = shapeOf(model as never)
  const { rows: pools } = await db.query(
    `SELECT id, name, tier, membership FROM pools ORDER BY name`)
  const { rows: nodes } = await db.query(
    `SELECT id, hostname, tier, chip, memory_gb, metal_working_set_gb, stored_models
       FROM nodes WHERE state = 'active'`)

  return pools.map((p) => {
    const members = (nodes as never[])
      .filter((n: never) => poolsFor(n, [p] as never).length > 0)
      .map((n: {
        hostname: string
        metal_working_set_gb: string | null
        stored_models: Record<string, number> | null
      }) => ({
        hostname: n.hostname,
        metalWorkingSetGb: n.metal_working_set_gb === null
          ? null : Number(n.metal_working_set_gb),
        holds: holdsModel((n.stored_models ?? {})[model.id as string], model.size_bytes),
      }))
    const state = runnability(members, shape)
    return {
      groupId: p.id as string,
      name: p.name as string,
      tier: p.tier as string,
      machines: members.length,
      state: state.state,
      detail: 'detail' in state ? state.detail : null,
    }
  })
}

/** One catalogue row, with the two counts that matter computed the same way. */
async function modelRow(db: Db, m: Record<string, unknown>) {
  const pools = (m.assigned_pools as string[]) ?? []
  const placement = pools.length > 0
    ? await placementOf(db, m.id as string, m.size_bytes)
    : []
  return {
    id: m.id as string,
    runtime: m.runtime as string,
    kind: m.kind as string,
    sizeBytes: Number(m.size_bytes),
    contextLength: m.context_length === null ? null : Number(m.context_length),
    quantization: (m.quantization as string | null) ?? null,
    family: (m.family as string | null) ?? null,
    fileCount: Number(m.file_count),
    // What running this actually requires. A model that needs two machines and
    // is assigned to a group with one should be refused when somebody says so,
    // not when somebody sends a request.
    machines: Number(m.machines ?? 1),
    minMemoryGb: m.min_memory_gb == null ? null : Number(m.min_memory_gb),
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
