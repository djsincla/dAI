import { Router } from 'express'
import { createHash, randomUUID } from 'node:crypto'
import type { Db } from '../lib/db.js'
import { agentAuth } from '../lib/auth.js'
import { poolsFor } from '../lib/pools.js'
import { effectiveServing } from '../lib/groupRules.js'
import { assignRanks, rankOf } from '../lib/splitRanks.js'
import { repositoryRoot, safePath } from '../lib/repository.js'
import { outputsRoot, sceneById, scenesRoot } from '../lib/scenes.js'
import { blobPath, finishIfDone, manifestFor, outputPath } from '../lib/attachments.js'
import { buildPath, desiredBuildFor } from '../lib/agentBuilds.js'
import { POLICY, type WorkKind } from '../lib/policy.js'
import { LeaseConflict, leaseWork, reportResult } from '../lib/work.js'
import { clientIp, nodeNetworkAllowed } from '../lib/netacl.js'
import type { Broker } from '../lib/broker.js'
import { type Ca, newEnrollmentToken, publicKeyIdOf } from '../lib/ca.js'
import { existsSync, readFileSync } from 'node:fs'
import { mkdir, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

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
   * Renew this node's certificate.
   *
   * No human in the loop, unlike approval. The node is calling over mTLS with
   * the certificate it already holds, which proves it controls the key that
   * certificate names. There is nothing left for an admin to decide that was
   * not decided when the node was approved.
   *
   * This exists because certificates are deliberately short-lived - a machine
   * that leaves the building should stop being a fleet member on its own. That
   * property is only affordable if renewal is automatic. Without it, expiry is
   * indistinguishable from an outage and the remedy is walking to every machine
   * once a month.
   *
   * A node that has *already* expired does not get here: `agentAuth` rejects it
   * first. That is deliberate. Renewal extends an identity, it does not
   * resurrect one, and a certificate that lapsed unnoticed is a machine nobody
   * has accounted for in a month.
   */
  r.post('/renew', async (req, res) => {
    const csrPem = (req.body as { csrPem?: string })?.csrPem ?? ''

    // Superseded means this hardware already came back as a different node
    // record. Renewing the old one would put two live certificates on one
    // machine and make the fleet count its capacity twice.
    const { rows: current } = await db.query(
      `SELECT state, cert_pem, hostname FROM nodes WHERE id = $1`, [req.node!.id])
    const node = current[0] as { state: string; cert_pem: string; hostname: string }
    if (node.state !== 'active') {
      res.status(403).json({ error: 'forbidden',
                             detail: `a ${node.state} node cannot renew` })
      return
    }

    let signed
    try {
      signed = await ca.sign(csrPem, req.node!.id, node.hostname)
    } catch (err) {
      res.status(400).json({ error: 'bad_request',
                             detail: `cannot sign CSR: ${(err as Error).message}` })
      return
    }

    // Ordinarily the key does not change: it lives in the Secure Enclave and
    // cannot leave. A machine that has had to rebuild that key would otherwise
    // need a full re-enrollment, so a new one is accepted and recorded. The
    // record is the only trace of a machine's key changing, so it is written
    // whether or not anybody is watching for it.
    const rekeyed = node.cert_pem
      ? publicKeyIdOf(csrPem) !== publicKeyIdOf(node.cert_pem)
      : false

    // Cleared here rather than when it was asked for: a request that was made
    // and a request that was met are different facts, and only the second means
    // the machine has what it was sent for.
    await db.query(`UPDATE nodes SET renew_requested_at = NULL WHERE id = $1`, [req.node!.id])

    await db.query(
      `UPDATE nodes SET cert_pem=$2, cert_fingerprint=$3, cert_not_after=$4 WHERE id=$1`,
      [req.node!.id, signed.certPem, signed.fingerprint, signed.notAfter],
    )
    await db.query(
      `INSERT INTO activity_log (node_id, event, detail) VALUES ($1,'node.renewed',$2)`,
      [req.node!.id, JSON.stringify({ notAfter: signed.notAfter, rekeyed })],
    )

    res.json({
      certPem: signed.certPem,
      notAfter: signed.notAfter.toISOString(),
      rekeyed,
      // Both CAs, so a rotated CA reaches the fleet without anybody visiting
      // it, and so that nodes enrolled before peer connections existed acquire
      // the node CA on their next renewal rather than needing re-enrolling.
      serverCaPem,
      nodeCaPem: ca.certPem,
    })
  })

  /**
   * What a job needs on this machine.
   *
   * The manifest, not the bytes. A node compares it with what it already holds
   * and fetches only the gaps, which is what makes the second frame of a job on
   * the same machine nearly free - and content is tens of gigabytes, so "nearly
   * free" is the difference between a fleet that renders and one that spends
   * its evening copying.
   */
  r.get('/jobs/:jobId/attachments', async (req, res) => {
    const { rows } = await db.query(
      `SELECT entry_path FROM jobs WHERE id = $1`, [req.params.jobId])
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no such job' })
      return
    }
    res.json({ entry: rows[0]!.entry_path, files: await manifestFor(db, req.params.jobId!) })
  })

  /**
   * One piece of content, by its hash.
   *
   * Checked against what some job actually references before the disk is
   * touched, so the store cannot be enumerated by a node guessing hashes, and
   * so content whose last job has finished is already unreachable before the
   * reaper gets to it.
   */
  r.get('/blobs/:sha256', async (req, res) => {
    const sha256 = req.params.sha256!.toLowerCase()
    const { rows } = await db.query(
      `SELECT 1 FROM job_attachments WHERE sha256 = $1 LIMIT 1`, [sha256])
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no live job references that content' })
      return
    }
    const full = blobPath(sha256)
    if (!full || !existsSync(full)) {
      res.status(404).json({ error: 'not_found', detail: 'referenced but not stored' })
      return
    }
    res.sendFile(full)
  })

  /**
   * The scene manifest, so a node can work out what it is missing.
   *
   * The manifest rather than the bytes. A node compares this with what it has
   * and fetches only the gaps, which is what makes a second unit of the same job
   * on a machine that already holds the scene nearly free - and a scene is tens
   * of gigabytes, so "nearly free" is the difference between a fleet that
   * renders and one that spends its evening copying.
   */
  r.get('/scenes/:sceneId', async (req, res) => {
    const scene = await sceneById(db, req.params.sceneId!)
    if (!scene) {
      res.status(404).json({ error: 'not_found', detail: 'no such scene' })
      return
    }
    res.json({
      id: scene.id, entry: scene.entry, sizeBytes: scene.sizeBytes, files: scene.files,
    })
  })

  r.get('/scenes/:sceneId/files/:filePath', async (req, res) => {
    const { sceneId, filePath } = req.params as { sceneId: string; filePath: string }
    // Checked against the catalogue before the disk, so the repository can only
    // ever serve bytes something registered claims to be part of a scene.
    const { rows } = await db.query(
      `SELECT 1 FROM scene_files WHERE scene_id=$1 AND path=$2`, [sceneId, filePath])
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no such scene file' })
      return
    }
    const full = safePath(scenesRoot(), sceneId, filePath)
    if (!full || !existsSync(full)) {
      res.status(404).json({ error: 'not_found', detail: 'registered but not in the repository' })
      return
    }
    res.sendFile(full)
  })

  /**
   * A finished frame, coming back.
   *
   * Only from the node holding the lease. Without that check any enrolled
   * machine could overwrite any job's output, and a fleet where a node can
   * quietly replace another node's frames is worse than one that cannot render
   * at all: the failure is invisible until somebody watches the sequence.
   */
  r.put('/work/:unitId/output/:name', async (req, res) => {
    const { unitId, name } = req.params as { unitId: string; name: string }
    const { rows } = await db.query(
      `SELECT u.id, u.job_id, u.lease_node_id, u.kind
         FROM work_units u WHERE u.id = $1`, [unitId])
    const unit = rows[0] as
      { id: string; job_id: string; lease_node_id: string | null; kind: string } | undefined
    if (!unit) {
      res.status(404).json({ error: 'not_found', detail: 'no such work unit' })
      return
    }
    if (unit.lease_node_id !== req.node!.id) {
      res.status(403).json({ error: 'forbidden', detail: 'this unit is not leased to you' })
      return
    }
    // The name lands on disk, so it is held to the same allow-list as every
    // other caller-supplied path segment rather than trusted for having come
    // from a node we authenticated.
    const dest = outputPath(unit.job_id, name)
    if (!dest) {
      res.status(400).json({ error: 'bad_request', detail: 'that output name cannot be a file' })
      return
    }
    const body = req.body as Buffer
    if (!Buffer.isBuffer(body) || body.length === 0) {
      res.status(400).json({ error: 'bad_request', detail: 'no bytes' })
      return
    }

    await mkdir(dirname(dest), { recursive: true })
    // Written aside and moved into place, so a transfer that dies halfway
    // leaves no file rather than a truncated frame that looks finished.
    const partial = `${dest}.partial`
    await writeFile(partial, body)
    await rename(partial, dest)
    const sha256 = createHash('sha256').update(body).digest('hex')

    // Last write wins. A render unit is idempotent, so a requeued one
    // legitimately produces a frame that already exists; refusing the second
    // copy would fail a job for succeeding twice.
    await db.query(
      `INSERT INTO work_outputs (job_id, name, unit_id, node_id, size_bytes, sha256)
       VALUES ($1,$2,$3,$4,$5,$6)
       ON CONFLICT (job_id, name) DO UPDATE
         SET unit_id = EXCLUDED.unit_id, node_id = EXCLUDED.node_id,
             size_bytes = EXCLUDED.size_bytes, sha256 = EXCLUDED.sha256,
             created_at = now()`,
      [unit.job_id, name, unit.id, req.node!.id, body.length, sha256],
    )
    res.json({ name, sizeBytes: body.length, sha256 })
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
      `SELECT id, hostname, tier, tiers, state FROM nodes WHERE id = $1`, [req.node!.id])
    res.json(rows[0])
  })

  r.get('/policy', (_req, res) => {
    res.json(POLICY)
  })

  r.post('/heartbeat', async (req, res) => {
    const b = req.body as {
      presenceState: string; onAcPower?: boolean; thermalOk?: boolean
      userPaused?: boolean
      models?: { name: string; contextLength: number }[]
      capabilitySamples?: { workloadClass: string; itemsPerSecond: number }[]
      residentModels?: Record<string, number>
      storedModels?: Record<string, number>
      agentVersion?: string
      agentFingerprint?: string
      // model id -> why this node does not hold it. Sent only after a sync pass
      // has run, so absent means "nothing new to say" rather than "all well".
      syncFaults?: Record<string, string>
      pipelineAddress?: string | null
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
              -- Replaced when the beat carries models, left alone when it does
              -- not.
              --
              -- Replacing unconditionally was right when one loop spoke for a
              -- node and wrong the moment two did: a node runs batch work and
              -- serving side by side, each heartbeats, and the batch loop knows
              -- nothing about the GPU model. Its silence was being read as
              -- "this node serves nothing" and erased the catalogue entry a
              -- second later.
              --
              -- Absent means unchanged; present means authoritative.
              model_context = COALESCE($8::jsonb, model_context),
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
              resident_models = $5::jsonb,
              -- Absent means unchanged, so an agent that predates this field
              -- keeps whatever it last reported rather than being recorded as
              -- holding nothing and triggering a fleet-wide redistribution.
              stored_models = COALESCE($9::jsonb, stored_models),
              agent_version = COALESCE($10, agent_version),
              agent_fingerprint = COALESCE($11, agent_fingerprint),
              -- Absent means unchanged, for the same reason stored_models is:
              -- an agent that predates the field must not appear to have
              -- cleared its faults just by heartbeating. A pass that succeeded
              -- sends an empty object, which does clear them.
              model_sync_faults = COALESCE($12::jsonb, model_sync_faults),
              -- Present-and-null clears it; absent leaves it alone. Only the
              -- node knows whether the link its peers reach it on still has an
              -- address, and a fleet that keeps the last one it heard forms a
              -- gang over a cable that is no longer there - which is exactly
              -- what happened: a Thunderbolt bridge went inactive, both
              -- machines went on advertising the addresses it used to have,
              -- and a split dialled into silence.
              pipeline_address = CASE WHEN $14::boolean
                                      THEN $13 ELSE pipeline_address END,
              last_model_sync = CASE WHEN $12::jsonb IS NULL
                                     THEN last_model_sync ELSE now() END
        WHERE id = $6`,
      [b.presenceState, b.onAcPower ?? null, b.thermalOk ?? null,
       JSON.stringify(profiles), JSON.stringify(b.residentModels ?? {}), node.id,
       b.userPaused ?? null,
       b.models === undefined
         ? null
         : JSON.stringify(Object.fromEntries(
             b.models.map((m) => [m.name, m.contextLength]))),
       b.storedModels ? JSON.stringify(b.storedModels) : null,
       b.agentVersion ?? null, b.agentFingerprint ?? null,
       b.syncFaults === undefined ? null : JSON.stringify(b.syncFaults),
       b.pipelineAddress ?? null,
       // Whether the node said anything about it at all. An agent that predates
       // the field must not appear to have lost its link by heartbeating.
       'pipelineAddress' in (req.body as object) ],
    )
    // Presence history feeds the capacity graph, which cannot be drawn from
    // current state alone.
    await db.query(
      `INSERT INTO presence_samples (node_id, presence_state, on_ac_power)
       VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`,
      [node.id, b.presenceState, b.onAcPower ?? null],
    )
    // What the control plane wants from this node, answered on the beat it
    // already sends. There is no other way to reach a machine that dials out
    // and never listens - and the one thing worth asking for cannot be done
    // any other way: the Enclave key signs only inside this daemon, so a
    // renewal cannot be run by hand from any shell.
    const { rows: asked } = await db.query(
      `SELECT renew_requested_at FROM nodes WHERE id = $1`, [node.id])

    // Which model this machine should be serving, which belongs to its group
    // and not to the machine.
    //
    // Until this existed a node's model was the argument its daemon happened to
    // be started with, set once by hand per box. A group could therefore
    // declare it served one model while its machines ran two different ones,
    // and nothing anywhere disagreed - which is what this fleet was doing.
    //
    // Where a machine's cluster and harvest groups disagree, the cluster group
    // wins: it promises never to be preempted and is the only place a split can
    // run, and the harvest group promises the opposite. Only one of those
    // survives contact with a single machine.
    const { rows: pools } = await db.query(
      `SELECT id, name, tier, membership, serving_model_id, idle_unload_seconds
         FROM pools
        WHERE serving_model_id IS NOT NULL AND enabled`)
    // How wide each model was declared, so the node can be told whether what it
    // has been asked to hold runs across machines. One query rather than one
    // per pool: there are few models and this runs on every heartbeat.
    const { rows: widths } = await db.query(`SELECT id, machines FROM models`)
    const machinesFor = new Map((widths as { id: string; machines: number }[])
      .map((m) => [m.id, Math.max(1, Number(m.machines ?? 1))]))

    const serving = effectiveServing(node as never, (pools as any[]).map((p) => ({
      ...p,
      servingModelId: p.serving_model_id as string,
      idleUnloadSeconds: p.idle_unload_seconds as number | null,
    })) as never, (id) => machinesFor.get(id) ?? 1)

    res.json({
      renewRequested: asked[0]?.renew_requested_at != null,
      // Null means nobody has said, which the node treats as "keep what you
      // have" rather than "stop serving": a group that has not been given a
      // model is not an instruction to unload one.
      servingModel: serving.model,
      // Whether to hold it in memory rather than loading on the next request.
      //
      // Intent, not tier. The node never learns which groups it is in - that
      // keeps the shape of the fleet out of a credential living on somebody's
      // workstation - and "hold this loaded" is an instruction it can follow
      // without knowing why it was given.
      //
      // True for a cluster group, because a split cannot start until every rank
      // has built its share: a cold gang pays the slowest machine's load before
      // the first token, and pays it again whenever the group falls idle. False
      // for harvest, where the machine belongs to whoever is sitting at it.
      keepLoaded: serving.keepLoaded,
      // How many machines this model runs across.
      //
      // Sent because a node cannot know it and must not guess. Warming a split
      // by loading the whole model is worse than not warming at all: it holds
      // twice the memory the share needs, and the split path never uses it -
      // it builds its own model with num_hidden_layers cut to this rank's
      // range, straight from the same weights.
      machines: serving.machines,
      // How long to hold the model once nothing is being asked of it.
      //
      // Null for a dedicated group, which holds its model for as long as it
      // stands. A number is a harvest machine being told when to let go: the
      // presence policy already covers "somebody wants their machine back",
      // and this covers "nobody wants anything", which nothing did.
      idleUnloadSeconds: serving.idleUnloadSeconds,
      // Which share of a split this machine holds, before anything asks for it.
      //
      // Rank is decided per request at dispatch, which is too late for a machine
      // to have built anything: a cold gang pays the slowest machine's load
      // before the first token. This is the same assignment from the same
      // function, sent ahead so the share can be ready.
      //
      // The dispatch stays authoritative. If it names a different rank -
      // membership changed, an address came or went - the machine rebuilds,
      // because the share it warmed was for a fleet that no longer exists.
      ...(await standingRank(db, node, serving)),
    })
  })

  /**
   * This machine's seat in a split, decided the same way the router decides it.
   *
   * Only for a group serving a model that runs across machines: everything else
   * gets nothing, and a node that is told nothing warms whatever it holds
   * whole. Costs one query, and only on the heartbeats that need it.
   */
  async function standingRank(
    db: Db, node: { id: string }, serving: { machines: number; groupId: string | null },
  ): Promise<{ rank?: number; size?: number }> {
    if (serving.machines <= 1 || !serving.groupId) return {}

    const { rows: pool } = await db.query(
      `SELECT id, tier, membership FROM pools WHERE id = $1 AND enabled`,
      [serving.groupId])
    if (pool.length === 0) return {}

    const { rows: nodes } = await db.query(
      `SELECT id, hostname, tier, chip, memory_gb, pipeline_address
         FROM nodes WHERE state = 'active'`)
    const members = (nodes as any[])
      .filter((n) => poolsFor(n as never, pool as never).length > 0)
      .map((n) => ({
        id: n.id as string, hostname: n.hostname as string,
        pipelineAddress: (n.pipeline_address as string | null) ?? null,
      }))

    const rank = rankOf(assignRanks(members), node.id)
    // No rank when nobody can be dialled. Sending one anyway would have a
    // machine build a share for a gang that cannot form.
    return rank === null ? {} : { rank, size: members.length }
  }

  /**
   * What this node should be holding.
   *
   * Resolved through pool membership rather than listed per machine, so an
   * operator assigns a model to a pool and every machine in it works out that
   * the instruction applies to them. A node never learns which pools it is in,
   * which keeps the fleet's shape out of a credential that lives on a
   * workstation.
   *
   * File hashes come down with it. They are what the node verifies against, and
   * verification is the entire reason this is not just an rsync.
   */
  r.get('/models/assigned', async (req, res) => {
    const node = req.node!
    const { rows: pools } = await db.query(`SELECT id, tier, membership FROM pools`)
    const mine = poolsFor(node as never, pools as never).map((p) => p.id)
    if (mine.length === 0) { res.json([]); return }

    const { rows } = await db.query(
      `SELECT DISTINCT m.id, m.runtime, m.kind
         FROM models m JOIN pool_models pm ON pm.model_id = m.id
        WHERE pm.pool_id = ANY($1::uuid[]) ORDER BY m.id`, [mine])

    const out = []
    for (const m of rows) {
      const { rows: files } = await db.query(
        `SELECT path, size_bytes, sha256 FROM model_files WHERE model_id=$1 ORDER BY path`,
        [m.id])
      out.push({
        id: m.id, runtime: m.runtime, kind: m.kind,
        files: files.map((f) => ({
          path: f.path, sizeBytes: Number(f.size_bytes), sha256: f.sha256,
        })),
      })
    }
    res.json(out)
  })

  /**
   * One file of one model.
   *
   * Both parameters arrive percent-encoded, because a model id contains a
   * slash and a file path may contain several. Express matches on the raw path
   * and decodes afterwards, so an encoded slash stays inside one parameter
   * rather than becoming another path segment - which is also what stops a
   * caller from walking out of the repository by spelling the traversal in
   * pieces.
   *
   * sendFile handles Range, and Range is why this is a file server rather than
   * a JSON payload: a shard is gigabytes, and a transfer that cannot resume
   * starts from zero every time a workstation sleeps.
   */
  r.get('/models/:modelId/files/:filePath', async (req, res) => {
    const { modelId, filePath } = req.params as { modelId: string; filePath: string }
    const { rows } = await db.query(
      `SELECT 1 FROM model_files WHERE model_id=$1 AND path=$2`, [modelId, filePath])
    // Checked against the catalogue first, so the repository can only ever
    // serve bytes something registered claims to be part of a model.
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no such model file' })
      return
    }
    const full = safePath(repositoryRoot(), modelId, filePath)
    if (!full || !existsSync(full)) {
      res.status(404).json({ error: 'not_found', detail: 'registered but not in the repository' })
      return
    }
    res.sendFile(full)
  })

  /**
   * What this node should be running, if anybody is managing it.
   *
   * Answers nothing when the node's pools are external: in that mode an MDM or
   * a person owns the binary and this system only observes. A node that is told
   * nothing does nothing, which is the correct behaviour for a machine whose
   * software somebody else is responsible for.
   */
  r.get('/agent/desired', async (req, res) => {
    const { rows: pools } = await db.query(`SELECT id, tier, membership FROM pools`)
    const mine = poolsFor(req.node! as never, pools as never).map((p) => p.id)
    const build = await desiredBuildFor(db, mine)
    res.json(build ?? {})
  })

  /** The bytes of one build. Verified against the recorded hash by the node. */
  r.get('/agent/builds/:version/binary', async (req, res) => {
    const { version } = req.params as { version: string }
    const { rows } = await db.query(`SELECT 1 FROM agent_builds WHERE version = $1`, [version])
    if (rows.length === 0) {
      res.status(404).json({ error: 'not_found', detail: 'no such build' })
      return
    }
    const path = buildPath(version)
    if (!path || !existsSync(path)) {
      res.status(404).json({ error: 'not_found', detail: 'registered but not in the repository' })
      return
    }
    res.sendFile(path)
  })

  /**
   * What an upgrade did, reported by the machine that attempted it.
   *
   * Written by the node because the interesting outcome is the one this server
   * cannot observe: a binary that starts, fails to reach home, and is rolled
   * back by the machine itself. Without this the fleet would show a node that
   * never moved and no trace of it having tried.
   */
  r.post('/agent/upgrades', async (req, res) => {
    const b = req.body as {
      fromVersion?: string | null; toVersion: string
      state: 'started' | 'committed' | 'reverted' | 'failed'; detail?: string | null
    }
    await db.query(
      `INSERT INTO agent_upgrades (node_id, from_version, to_version, state, detail)
       VALUES ($1,$2,$3,$4,$5)`,
      [req.node!.id, b.fromVersion ?? null, b.toVersion, b.state, b.detail ?? null],
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

  /**
   * Whether the caller has given up on a request this node is still running.
   *
   * Polled rather than pushed, because the node is inside a generation loop
   * with no open channel to receive anything. Cheap: one small request every
   * couple of seconds against a lookup in memory.
   */
  r.get('/dispatch/:dispatchId/cancelled', (req, res) => {
    res.json({ cancelled: broker.isCancelled(req.params.dispatchId!) })
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
      // Asked here rather than on a timer. The moment the last unit stops is
      // the moment the job's inputs are dead, and holding tens of gigabytes of
      // somebody else's scene for the length of a polling interval is holding
      // it for no reason at all.
      const { rows: which } = await db.query(
        `SELECT job_id FROM work_units WHERE id = $1`, [req.params.unitId])
      let jobFinished = false
      if (which[0]?.job_id) {
        const done = await finishIfDone(db, which[0].job_id as string)
        jobFinished = done.finished
        if (done.finished) {
          await db.query(
            `INSERT INTO activity_log (node_id, event, detail) VALUES ($1,'job.finished',$2)`,
            [req.node!.id, JSON.stringify({ jobId: which[0].job_id,
                                            blobsDeleted: done.blobsDeleted })],
          )
        }
      }
      // Told to the node, so it can delete its own copy of the job's content
      // rather than waiting to be swept. The machine belongs to somebody else
      // and tens of gigabytes of a finished job is not the agent's to keep.
      res.json({ ...out, jobFinished })
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
