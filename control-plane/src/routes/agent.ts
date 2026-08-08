import { Router } from 'express'
import { createHash, randomUUID } from 'node:crypto'
import type { Db } from '../lib/db.js'
import { agentAuth } from '../lib/auth.js'
import { POLICY, type WorkKind } from '../lib/policy.js'
import { LeaseConflict, leaseWork, reportResult } from '../lib/work.js'

const KINDS: WorkKind[] = ['embed', 'generate', 'render']

export function agentRoutes(db: Db): Router {
  const r = Router()

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

    // Stand-in for signing the CSR. The real issuer signs at approval, not here.
    const fingerprint = createHash('sha256').update(b.csrPem).digest('hex')

    const { rows } = await db.query(
      `INSERT INTO nodes (hostname, chip, memory_gb, metal_working_set_gb, os_version,
                          state, cert_fingerprint)
       VALUES ($1,$2,$3,$4,$5,'pending',$6)
       ON CONFLICT (cert_fingerprint) DO UPDATE SET hostname = EXCLUDED.hostname
       RETURNING id, state`,
      [b.hostname, b.chip, b.memoryGb, b.metalWorkingSetGb, b.osVersion, fingerprint],
    )
    res.status(202).json({ nodeId: rows[0]!.id, state: 'pending', fingerprint })
  })

  r.use(agentAuth(db))

  r.get('/policy', (_req, res) => {
    res.json(POLICY)
  })

  r.post('/heartbeat', async (req, res) => {
    const b = req.body as {
      presenceState: string; onAcPower?: boolean; thermalOk?: boolean
      capabilitySamples?: { workloadClass: string; itemsPerSecond: number }[]
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
              capability_profiles = capability_profiles || $4::jsonb
        WHERE id = $5`,
      [b.presenceState, b.onAcPower ?? null, b.thermalOk ?? null,
       JSON.stringify(profiles), node.id],
    )
    res.status(204).end()
  })

  r.get('/work', async (req, res) => {
    const raw = String(req.query.kinds ?? '')
    const requested = raw.split(',').map((s) => s.trim()).filter((s): s is WorkKind =>
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
