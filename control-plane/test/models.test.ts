import type { Server } from 'node:http'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { type Fixtures, appFor, freshDb, seed } from './helpers.js'

/**
 * The model catalogue, and the difference between what a machine has and what
 * it was told to have.
 *
 * There was no catalogue until now. Weights were copied machine to machine by
 * hand over scp, verified by reading file sizes off a terminal, and the record
 * of what was where lived in somebody's memory. That is survivable at two
 * machines and is the whole job at fifty.
 *
 * The property these protect is that the declared and the observed halves stay
 * distinguishable. A view that silently merges them cannot show drift, and
 * drift is the only thing worth looking at.
 */
let db: Db
let fx: Fixtures
let server: Server
let base: string

beforeEach(async () => {
  db = await freshDb()
  fx = await seed(db)
  server = await new Promise<Server>((resolve) => {
    const s = appFor(db).listen(0, () => resolve(s))
  })
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`
})
afterEach(async () => { await new Promise<void>((r) => server.close(() => r())) })
afterAll(async () => { await db?.end() })

const asUser = (id: string) => ({
  authorization: `Bearer ${id}`, 'content-type': 'application/json',
})

const MODEL = {
  id: 'mlx-community/Qwen2.5-Coder-32B-Instruct-4bit',
  runtime: 'mlx', kind: 'generate', contextLength: 32768,
  quantization: '4bit', family: 'hermes-qwen',
  files: [
    { path: 'model-00001-of-00002.safetensors', sizeBytes: 5366582717, sha256: 'a'.repeat(64) },
    { path: 'model-00002-of-00002.safetensors', sizeBytes: 2362540888, sha256: 'b'.repeat(64) },
    { path: 'config.json', sizeBytes: 867, sha256: 'c'.repeat(64) },
  ],
}

const register = (userId: string, body: unknown = MODEL) =>
  fetch(`${base}/admin/v1/models`, {
    method: 'POST', headers: asUser(userId), body: JSON.stringify(body),
  })

describe('registering weights', () => {
  it('records the files and totals their size', async () => {
    // Size is derived rather than declared: a caller who states a total that
    // disagrees with the files is stating something unverifiable, and the
    // number is used to decide whether a machine can hold the model at all.
    const r = await register(fx.ownerToken)
    expect(r.status).toBe(201)
    const m = await r.json()
    expect(m.fileCount).toBe(3)
    expect(m.sizeBytes).toBe(5366582717 + 2362540888 + 867)
    expect(m.contextLength).toBe(32768)
  })

  it('refuses a second registration of the same id', async () => {
    // Silently replacing hashes would change what every node is reconciling
    // toward without anybody asking for it, and the nodes would obediently
    // re-fetch seventeen gigabytes each.
    await register(fx.ownerToken)
    const again = await register(fx.ownerToken)
    expect(again.status).toBe(409)
  })

  it('rejects a model with no files', async () => {
    // An entry with nothing to fetch is one a node can never satisfy, so it
    // would sit permanently in drift with no way to resolve it.
    const r = await register(fx.ownerToken, { ...MODEL, files: [] })
    expect(r.status).toBe(400)
  })

  it('rejects a hash that is not a sha256', async () => {
    // The hash is the only thing standing between a truncated shard and a node
    // loading it. A short or malformed one has to fail at the door.
    const r = await register(fx.ownerToken, {
      ...MODEL, files: [{ path: 'a.bin', sizeBytes: 1, sha256: 'nope' }],
    })
    expect(r.status).toBe(400)
  })

  it('rejects a runtime the fleet has no way to run', async () => {
    const r = await register(fx.ownerToken, { ...MODEL, runtime: 'cuda' })
    expect(r.status).toBe(400)
  })
})

describe('assignment against residency', () => {
  const assign = (userId: string, poolId: string, modelId: string, method = 'PUT') =>
    fetch(`${base}/admin/v1/pools/${poolId}/models/${encodeURIComponent(modelId)}`,
      { method, headers: asUser(userId) })

  it('counts a node that should hold a model and does not', async () => {
    // The number the whole catalogue exists to produce. Before assignment there
    // is nothing to be missing, so the count is zero and not "everything".
    await register(fx.ownerToken)
    const before = await (await fetch(`${base}/admin/v1/models`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(before[0].nodesWanting).toBe(0)
    expect(before[0].nodesHolding).toBe(0)

    expect((await assign(fx.operatorToken, fx.poolId, MODEL.id)).status).toBe(204)
    const after = await (await fetch(`${base}/admin/v1/models`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(after[0].nodesWanting).toBe(1)
    expect(after[0].assignedPools).toEqual([fx.poolId])
  })

  it('stops counting a node as wanting once it holds the weights', async () => {
    await register(fx.ownerToken)
    await assign(fx.operatorToken, fx.poolId, MODEL.id)
    await db.query(`UPDATE nodes SET stored_models = $2 WHERE id = $1`,
      [fx.nodeId, JSON.stringify({ [MODEL.id]: 17.2 })])

    const rows = await (await fetch(`${base}/admin/v1/models`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(rows[0].nodesHolding).toBe(1)
    expect(rows[0].nodesWanting).toBe(0)
  })

  it('shows weights a node holds that nobody assigned', async () => {
    // Hand-staged models are exactly this case, and it is the one a view that
    // only lists what is missing cannot show. Every model on the fleet today
    // arrived this way.
    await register(fx.ownerToken)
    await db.query(`UPDATE nodes SET stored_models = $2 WHERE id = $1`,
      [fx.nodeId, JSON.stringify({ [MODEL.id]: 17.2 })])

    const detail = await (await fetch(
      `${base}/admin/v1/models/${encodeURIComponent(MODEL.id)}`,
      { headers: asUser(fx.ownerToken) })).json()
    const node = detail.placement.find((p: { hostname: string }) => p.hostname === 'rotorua')
    expect(node).toMatchObject({ wanted: false, held: true })
  })

  it('respects pool membership when deciding who wants it', async () => {
    // Assignment is to a pool, not to a list of machines, so a node that is not
    // in the pool must not be counted as missing something it was never asked
    // to hold.
    await register(fx.ownerToken)
    await assign(fx.operatorToken, fx.poolId, MODEL.id)
    await db.query(`UPDATE pools SET membership = '{"minMemoryGb": 128}' WHERE id = $1`,
      [fx.poolId])

    const rows = await (await fetch(`${base}/admin/v1/models`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(rows[0].nodesWanting).toBe(0)
  })

  it('separates having the weights from having them loaded', async () => {
    // The defect this whole column exists to fix. A machine holding 18GB on
    // disk with nothing loaded is the normal state of a healthy node nobody has
    // asked anything of yet, and reading residency as possession reported it as
    // empty - which would have an operator send it weights it already had.
    await register(fx.ownerToken)
    await assign(fx.operatorToken, fx.poolId, MODEL.id)
    await db.query(`UPDATE nodes SET stored_models = $2, resident_models = '{}' WHERE id = $1`,
      [fx.nodeId, JSON.stringify({ [MODEL.id]: 17.2 })])

    const detail = await (await fetch(
      `${base}/admin/v1/models/${encodeURIComponent(MODEL.id)}`,
      { headers: asUser(fx.ownerToken) })).json()
    const node = detail.placement.find((p: { hostname: string }) => p.hostname === 'rotorua')
    expect(node).toMatchObject({ wanted: true, held: true, loaded: false })

    const rows = await (await fetch(`${base}/admin/v1/models`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(rows[0].nodesHolding).toBe(1)
    expect(rows[0].nodesWanting).toBe(0)
  })

  it('does not count a node that has only been retired', async () => {
    // nodesHolding counted every row the nodes table had ever held, including
    // superseded ones. A machine re-enrolled after a rebuild left a ghost that
    // went on reporting weights forever, and the catalogue said one node held
    // the 32B while the placement list showed nobody did.
    await register(fx.ownerToken)
    await db.query(
      `INSERT INTO nodes (hostname, state, cert_fingerprint, stored_models)
       VALUES ('rotorua','superseded','fp-old',$1)`,
      [JSON.stringify({ [MODEL.id]: 17.2 })])

    const rows = await (await fetch(`${base}/admin/v1/models`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(rows[0].nodesHolding).toBe(0)
  })

  it('refuses assignment from somebody with no standing on the pool', async () => {
    await register(fx.ownerToken)
    expect((await assign(fx.strangerToken, fx.poolId, MODEL.id)).status).toBe(403)
  })

  it('unassigns without deleting the model', async () => {
    await register(fx.ownerToken)
    await assign(fx.operatorToken, fx.poolId, MODEL.id)
    expect((await assign(fx.operatorToken, fx.poolId, MODEL.id, 'DELETE')).status).toBe(204)
    const rows = await (await fetch(`${base}/admin/v1/models`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(rows).toHaveLength(1)
    expect(rows[0].assignedPools).toEqual([])
  })

  it('is idempotent, so assigning twice is not an error', async () => {
    // An operator clicking twice, or a manager-of-managers reconciling the same
    // desired state repeatedly, must not accumulate anything.
    await register(fx.ownerToken)
    await assign(fx.operatorToken, fx.poolId, MODEL.id)
    expect((await assign(fx.operatorToken, fx.poolId, MODEL.id)).status).toBe(204)
    const rows = await (await fetch(`${base}/admin/v1/models`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(rows[0].assignedPools).toEqual([fx.poolId])
  })
})

describe('the catalogue itself', () => {
  it('returns the files and their hashes for one model', async () => {
    await register(fx.ownerToken)
    const detail = await (await fetch(
      `${base}/admin/v1/models/${encodeURIComponent(MODEL.id)}`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(detail.files).toHaveLength(3)
    expect(detail.files.map((f: { path: string }) => f.path))
      .toContain('model-00001-of-00002.safetensors')
  })

  it('answers 404 for a model nobody registered', async () => {
    const r = await fetch(`${base}/admin/v1/models/nope`, { headers: asUser(fx.ownerToken) })
    expect(r.status).toBe(404)
  })

  it('removing a model takes its assignments with it', async () => {
    await register(fx.ownerToken)
    await fetch(`${base}/admin/v1/pools/${fx.poolId}/models/${encodeURIComponent(MODEL.id)}`,
      { method: 'PUT', headers: asUser(fx.operatorToken) })
    const r = await fetch(`${base}/admin/v1/models/${encodeURIComponent(MODEL.id)}`,
      { method: 'DELETE', headers: asUser(fx.ownerToken) })
    expect(r.status).toBe(204)
    const { rows } = await db.query(`SELECT count(*)::int n FROM pool_models`)
    expect(rows[0].n).toBe(0)
  })
})

describe('an import while it is running', () => {
  it('is visible before the model joins the catalogue', async () => {
    // The gap this closes. A model appears in the catalogue only once every
    // file has landed and hashed, which is correct, but it left minutes during
    // which an eighteen gigabyte import showed nothing anywhere.
    await db.query(
      `INSERT INTO model_imports (model_id, source, files_done, files_total, bytes_done)
       VALUES ('org/big', '/tmp/x', 2, 11, 5000000000)`)

    const rows = await (await fetch(`${base}/admin/v1/models/imports`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ modelId: 'org/big', state: 'running', filesDone: 2 })

    // And the catalogue itself is still empty, which is the invariant worth
    // keeping: a half-registered model would be assignable and unfetchable.
    expect(await (await fetch(`${base}/admin/v1/models`,
      { headers: asUser(fx.ownerToken) })).json()).toEqual([])
  })

  it('keeps a failure around, and drops a success', async () => {
    // A successful import is recorded by the model itself. A failure has no
    // other trace at all.
    await db.query(
      `INSERT INTO model_imports (model_id, source, state, error, finished_at)
       VALUES ('org/bad', '/tmp/x', 'failed', 'a.bin: hash mismatch', now()),
              ('org/good', '/tmp/y', 'done', NULL, now())`)

    const rows = await (await fetch(`${base}/admin/v1/models/imports`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(rows.map((r: { modelId: string }) => r.modelId)).toEqual(['org/bad'])
    expect(rows[0].error).toMatch(/hash mismatch/)
  })

  it('is not shadowed by the route that fetches one model', async () => {
    // /models/imports and /models/{modelId} both match the same shape. Ordered
    // wrongly, asking for imports returns a 404 for a model called "imports".
    const r = await fetch(`${base}/admin/v1/models/imports`, { headers: asUser(fx.ownerToken) })
    expect(r.status).toBe(200)
    expect(Array.isArray(await r.json())).toBe(true)
  })
})

describe('who told the fleet to do it', () => {
  const assign = (userId: string, poolId: string, modelId: string, method = 'PUT') =>
    fetch(`${base}/admin/v1/pools/${poolId}/models/${encodeURIComponent(modelId)}`,
      { method, headers: asUser(userId) })

  it('records a push, and keeps it after the push is undone', async () => {
    // The gap this closes. Pushing commits every machine in a pool to fetching
    // up to eighteen gigabytes, and the only record was a single mutable row:
    // unassign and reassign, and there was nothing left to ask about.
    await register(fx.ownerToken)
    await assign(fx.operatorToken, fx.poolId, MODEL.id)
    await assign(fx.operatorToken, fx.poolId, MODEL.id, 'DELETE')

    const detail = await (await fetch(
      `${base}/admin/v1/models/${encodeURIComponent(MODEL.id)}`,
      { headers: asUser(fx.ownerToken) })).json()

    // Newest first, and the push survives its own undoing.
    expect(detail.history.map((h: { action: string }) => h.action))
      .toEqual(['model.unpush', 'model.push'])
    expect(detail.history[0].by).toBe('operator@example.com')
  })

  it('attributes the action to the person who took it', async () => {
    await register(fx.ownerToken)
    await assign(fx.operatorToken, fx.poolId, MODEL.id)
    const detail = await (await fetch(
      `${base}/admin/v1/models/${encodeURIComponent(MODEL.id)}`,
      { headers: asUser(fx.ownerToken) })).json()
    expect(detail.history[0]).toMatchObject({
      action: 'model.push', by: 'operator@example.com',
    })
  })

  it('does not fail the action when the audit write fails', async () => {
    // An audit write that fails must not fail the thing it describes, or a full
    // disk turns "push a model" into an outage.
    await register(fx.ownerToken)
    await db.query(`ALTER TABLE audit_log RENAME TO audit_log_hidden`)
    try {
      expect((await assign(fx.operatorToken, fx.poolId, MODEL.id)).status).toBe(204)
    } finally {
      await db.query(`ALTER TABLE audit_log_hidden RENAME TO audit_log`)
    }
  })
})
