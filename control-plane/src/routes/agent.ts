import { Router } from 'express'
import { randomUUID } from 'node:crypto'
import type { Db } from '../lib/db.js'
import { agentAuth } from '../lib/auth.js'
import { POLICY, type WorkKind } from '../lib/policy.js'
import { LeaseConflict, leaseWork, reportResult } from '../lib/work.js'
import { clientIp, nodeNetworkAllowed } from '../lib/netacl.js'
import type { Broker } from '../lib/broker.js'
import { type Ca, newEnrollmentToken } from '../lib/ca.js'
import { existsSync, readFileSync } from 'node:fs'

const KINDS: WorkKind[] = ['embed', 'generate', 'render']

export function agentRoutes(db: Db, broker: Broker, ca: Ca): Router {
  const r = Router()

  /**
   * The CA a node needs in order to keep talking to us.
   *
   * This is the *server* CA, not the node CA. The node CA signs agent
   * identities and a node never needs it; the server CA is what lets a node
   * verify the control plane. Returning the wrong one produces a certificate
   * verification failure that reads like a connectivity problem, which is
   * exactly what happened the first time this was wired up.
   */
  const serverCaPath = process.env.TLS_CA
  const serverCaPem = serverCaPath && existsSync(serverCaPath)
    ? readFileSync(serverCaPath, 'utf8')
    : null

  /**
   * Enrollment never auto-trusts a token bearer. The node lands in `pending`
   * with its fingerprint and gets no certificate until an admin approves it,
   * because a leaked join token would otherwise be enough to join the fleet and
   * start receiving work.
   */
  r.post('/enroll', async (req, res) => {
    const b = req.body as {
      joinToken: string; hostname: string; chip: string; memoryGb: number
      metalWorkingSetGb: number; osVersion: string; csrPem: string
      machineId?: string | null
    }

    const { rows: tok } = await db.query(
      `SELECT token FROM join_tokens
        WHERE token = $1 AND (expires_at IS NULL OR expires_at > now())`,
      [b.joinToken],
    )
    if (tok.length === 0) {
      res.status(401).json({ error: 'unauthorized', detail: 'invalid or expired join token' })
      return
    }

    // The CSR is stored, not signed. Signing happens at approval, so a leaked
    // join token is a nuisance rather than a fleet compromise.
    const enrollmentToken = newEnrollmentToken()
    const { rows } = await db.query(
      `INSERT INTO nodes (hostname, chip, memory_gb, metal_working_set_gb, os_version,
                          state, csr_pem, enrollment_token, machine_id)
       VALUES ($1,$2,$3,$4,$5,'pending',$6,$7,$8)
       RETURNING id, state`,
      [b.hostname, b.chip, b.memoryGb, b.metalWorkingSetGb, b.osVersion,
       b.csrPem, enrollmentToken, b.machineId ?? null],
    )
    res.status(202).json({
      nodeId: rows[0]!.id,
      state: 'pending',
      // The node keeps this to collect its certificate once approved. It is the
      // only way back in before the node has an identity, which is why it is
      // single use.
      enrollmentToken,
    })
  })

  /**
   * Collect a certificate after approval.
   *
   * Cannot require mTLS: the node has no certificate yet, which is the whole
   * reason it is calling. The enrollment token stands in, and is cleared on
   * collection because a credential that can be replayed is one that will be.
   */
  r.get('/enroll/:nodeId', async (req, res) => {
    const token = req.header('x-enrollment-token')
    if (!token) {
      res.status(401).json({ error: 'unauthorized', detail: 'no enrollment token' })
      return
    }
    const { rows } = await db.query(
      `SELECT id, state, cert_pem, enrollment_token FROM nodes WHERE id = $1`,
      [req.params.nodeId],
    )
    const node = rows[0] as any
    if (!node || node.enrollment_token !== token) {
      res.status(401).json({ error: 'unauthorized', detail: 'invalid enrollment token' })
      return
    }
    if (node.state === 'pending' || !node.cert_pem) {
      res.status(202).json({ state: 'pending' })
      return
    }
    await db.query(`UPDATE nodes SET enrollment_token = NULL WHERE id = $1`, [node.id])
    res.json({
      state: 'active',
      certPem: node.cert_pem,
      // Lets a node refresh its pinned server CA over an authenticated channel
      // rather than only out of band, which matters when the server CA rotates.
      serverCaPem,
      nodeCaPem: ca.certPem,
    })
  })

  r.use(agentAuth(db))

  // Certificate pinning to a network. Runs after the certificate has identified
  // the node, so it answers "is this node calling from where it should be"
  // rather than "who is this". Catches key material used from somewhere else.
  r.use(async (req, res, next) => {
    if (await nodeNetworkAllowed(db, req.node!.id, clientIp(req))) {
      next()
      return
    }
    await db.query(
      `INSERT INTO activity_log (node_id, event, detail) VALUES ($1,'auth.wrong_network',$2)`,
      [req.node!.id, JSON.stringify({ ip: clientIp(req) })],
    )
    res.status(403).json({ error: 'forbidden', detail: 'node not permitted from this network' })
  })

  /**
   * What this node is, from the control plane's point of view.
   *
   * The agent needs its own tier to know whether presence gating applies: a
   * cluster node is a dedicated box that is never preempted, and applying the
   * harvest rules there would stop it serving the moment somebody touched a
   * keyboard attached to a server.
   */
  r.get('/me', async (req, res) => {
    const { rows } = await db.query(
      `SELECT id, hostname, tier, state FROM nodes WHERE id = $1`, [req.node!.id])
    res.json(rows[0])
  })

  r.get('/policy', (_req, res) => {
    res.json(POLICY)
  })

  r.post('/heartbeat', async (req, res) => {
    const b = req.body as {
      presenceState: string; onAcPower?: boolean; thermalOk?: boolean
      userPaused?: boolean
      capabilitySamples?: { workloadClass: string; itemsPerSecond: number }[]
      residentModels?: Record<string, number>
    }
    const node = req.node!

    // Capability is observed, never declared, and stored per workload class.
    // The same two machines differed 7.5% on a 1.5B model and 26.3% on a 7B, so
    // a single scalar would misallocate by 20-40% depending on the workload.
    const profiles: Record<string, number> = {}
    for (const s of b.capabilitySamples ?? []) profiles[s.workloadClass] = s.itemsPerSecond

    await db.query(
      `UPDATE nodes
          SET presence_state = $1, on_ac_power = $2, thermal_ok = $3,
              last_heartbeat = now(),
              user_paused = COALESCE($7, user_paused),
              -- Stamped on the transition only, so the UI can say how long a
              -- machine has been paused rather than just that it is.
              user_paused_at = CASE
                WHEN COALESCE($7, user_paused) AND NOT user_paused THEN now()
                WHEN NOT COALESCE($7, user_paused) THEN NULL
                ELSE user_paused_at END,
              capability_profiles = capability_profiles || $4::jsonb,
              -- Replaced rather than merged: a model the node has released is
              -- no longer resident, and routing to it would put a 1-3s load on
              -- the request path it was chosen to avoid.
              resident_models = $5::jsonb
        WHERE id = $6`,
      [b.presenceState, b.onAcPower ?? null, b.thermalOk ?? null,
       JSON.stringify(profiles), JSON.stringify(b.residentModels ?? {}), node.id,
       b.userPaused ?? null],
    )
    // Presence history feeds the capacity graph, which cannot be drawn from
    // current state alone.
    await db.query(
      `INSERT INTO presence_samples (node_id, presence_state, on_ac_power)
       VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`,
      [node.id, b.presenceState, b.onAcPower ?? null],
    )
    res.status(204).end()
  })

  /**
   * Reverse channel. The node dials out and parks here; the control plane
   * pushes an interactive request down the open connection.
   *
   * Outbound from the node, so no inbound firewall rules, no per-node
   * addressing and no NAT traversal, which is what made pull the right choice
   * for batch in the first place. Push from the scheduler, so routing takes
   * milliseconds rather than a poll interval.
   */
  r.get('/dispatch', async (req, res) => {
    const dispatch = await broker.waitForWork(req.node!.id)
    if (!dispatch) {
      // Timed out with nothing to do. Returning rather than holding forever
      // keeps the connection observably alive and lets a node notice a control
      // plane restart instead of waiting on a socket nobody is listening to.
      res.status(204).end()
      return
    }
    res.json({
      dispatchId: dispatch.id,
      kind: dispatch.kind,
      modelHash: dispatch.modelHash,
      body: dispatch.body,
    })
  })

  r.post('/dispatch/:dispatchId/result', async (req, res) => {
    const b = req.body as { result?: unknown; error?: string }
    const accepted = broker.complete(req.params.dispatchId!, req.node!.id, {
      body: b.result, error: b.error,
    })
    // A late answer whose dispatch already timed out is refused rather than
    // silently dropped, so the agent can tell the difference between "done" and
    // "nobody was waiting".
    res.status(accepted ? 200 : 409).json({ accepted })
  })

  r.get('/work', async (req, res) => {
    // The validator hands this back as an array now, but a hand-written client
    // or an older agent may still produce a bare string, and refusing those
    // would break nodes mid-upgrade for no benefit.
    const raw = req.query.kinds
    const parts = Array.isArray(raw) ? raw.map(String) : String(raw ?? '').split(',')
    const requested = parts.map((s) => s.trim()).filter((s): s is WorkKind =>
      (KINDS as string[]).includes(s))

    const out = await leaseWork(db, req.node!, requested)
    res.json(out)
  })

  r.post('/work/:unitId/result', async (req, res) => {
    try {
      const out = await reportResult(db, req.node!.id, req.params.unitId!, req.body)
      await db.query(
        `INSERT INTO activity_log (node_id, event, detail) VALUES ($1,'work.result',$2)`,
        [req.node!.id, JSON.stringify({ unitId: req.params.unitId, ...out })],
      )
      res.json(out)
    } catch (err) {
      if (err instanceof LeaseConflict) {
        res.status(409).json({ error: 'lease_conflict', detail: err.message })
        return
      }
      throw err
    }
  })

  return r
}

export { randomUUID }
