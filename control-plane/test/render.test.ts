import { execSync } from 'node:child_process'
import type { Server } from 'node:http'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { entryOf, framesFor, frameName } from '../src/lib/scenes.js'
import { type Fixtures, appFor, freshDb, seed } from './helpers.js'

/**
 * Rendering, which needed no separate codebase and no separate fleet.
 *
 * The presence detection, policy engine, enrollment and leasing already carried
 * it. What it needed was a runtime on the agent, somewhere for scenes to live,
 * and somewhere for frames to come back to. These are the last two.
 */
describe('deciding what a render job covers', () => {
  it('refuses a range that runs off the end of the scene', () => {
    // A frame past the end renders black, lands as a real file of a plausible
    // size, and looks like a successful job until somebody plays it back.
    const bounds = { frameStart: 1, frameEnd: 100 }
    expect(framesFor(1, 101, 1, bounds)).toEqual({ error: 'the scene ends at frame 100' })
    expect(framesFor(0, 50, 1, bounds)).toEqual({ error: 'the scene starts at frame 1' })
    expect(framesFor(1, 100, 1, bounds)).toHaveProperty('frames')
  })

  it('refuses a range that ends before it starts', () => {
    expect(framesFor(50, 10)).toEqual({ error: 'frame range 50-10 ends before it starts' })
  })

  it('caps a job that is probably a typo', () => {
    // 1-100000 is indistinguishable from an intention until fifty machines have
    // been busy for a week.
    expect(framesFor(1, 100_000)).toEqual({ error: 'more than 20000 frames; split the job' })
  })

  it('walks the range by the step it was given', () => {
    expect(framesFor(1, 9, 4)).toEqual({ frames: [1, 5, 9] })
    expect(framesFor(7, 7)).toEqual({ frames: [7] })
  })

  it('refuses anything that is not a whole frame number', () => {
    // The frame is the one value from a submission that reaches a command line.
    expect(framesFor(1.5, 4)).toEqual({ error: 'frames must be whole numbers' })
    expect(framesFor(1, 4, 0)).toEqual({ error: 'step must be at least 1' })
  })

  it('names frames so they sort', () => {
    expect(frameName(7)).toBe('frame_0007.png')
    expect([frameName(10), frameName(9)].sort()).toEqual(['frame_0009.png', 'frame_0010.png'])
  })
})

describe('choosing which file the renderer opens', () => {
  it('works it out when there is exactly one', () => {
    expect(entryOf([
      { path: 'shot.blend', sizeBytes: 1, sha256: 'x' },
      { path: 'tex/wood.png', sizeBytes: 1, sha256: 'y' },
    ])).toEqual({ entry: 'shot.blend' })
  })

  it('asks rather than guessing when there is more than one', () => {
    // Two machines guessing differently would render two different scenes under
    // one name, and nothing downstream would say so: the frames would simply
    // not match.
    const result = entryOf([
      { path: 'shot.blend', sizeBytes: 1, sha256: 'x' },
      { path: 'shot_old.blend', sizeBytes: 1, sha256: 'y' },
    ])
    expect(result).toHaveProperty('error')
    expect((result as { error: string }).error).toContain('name one explicitly')
  })

  it('refuses a bundle with nothing to render', () => {
    expect(entryOf([{ path: 'notes.txt', sizeBytes: 1, sha256: 'x' }]))
      .toEqual({ error: 'no .blend file in the scene' })
  })
})

describe('scenes and frames over HTTP', () => {
  let db: Db
  let fx: Fixtures
  let server: Server
  let base: string
  let sceneDir: string
  let outDir: string

  beforeEach(async () => {
    sceneDir = mkdtempSync(join(tmpdir(), 'dai-scenes-'))
    outDir = mkdtempSync(join(tmpdir(), 'dai-outputs-'))
    process.env.DAI_SCENE_REPO = sceneDir
    process.env.DAI_OUTPUT_DIR = outDir
    db = await freshDb()
    fx = await seed(db)
    const g = await db.query(`INSERT INTO groups (name) VALUES ('ops') RETURNING id`)
    await db.query(`INSERT INTO group_members VALUES ($1,$2)`, [g.rows[0].id, fx.operatorId])
    await db.query(`INSERT INTO role_bindings VALUES ($1,$2,'operator')`,
      [g.rows[0].id, fx.poolId])
    const app = appFor(db)
    server = await new Promise<Server>((r) => { const s = app.listen(0, () => r(s)) })
    base = `http://127.0.0.1:${(server.address() as any).port}`
  })
  afterEach(async () => {
    await new Promise<void>((r) => server.close(() => r()))
    rmSync(sceneDir, { recursive: true, force: true })
    rmSync(outDir, { recursive: true, force: true })
    delete process.env.DAI_SCENE_REPO
    delete process.env.DAI_OUTPUT_DIR
  })
  afterAll(async () => { await db?.end() })

  const asUser = (id: string) =>
    ({ authorization: `Bearer ${id}`, 'content-type': 'application/json' })
  const asNode = () => ({ 'x-node-fingerprint': fx.fingerprint })

  function putScene(id: string, files: Record<string, string>) {
    mkdirSync(join(sceneDir, id), { recursive: true })
    for (const [path, body] of Object.entries(files)) {
      const full = join(sceneDir, id, path)
      mkdirSync(join(full, '..'), { recursive: true })
      writeFileSync(full, body)
    }
  }

  const register = (body: unknown) =>
    fetch(`${base}/admin/v1/scenes`, {
      method: 'POST', headers: asUser(fx.operatorToken), body: JSON.stringify(body) })

  it('registers a scene where it already sits', async () => {
    // Catalogued rather than copied. Scenes are large and short-lived, and
    // copying a 40GB bundle to register it costs 40GB and several minutes
    // before a job can even be submitted.
    putScene('shot-01', { 'shot.blend': 'BLENDER-x', 'tex/wood.png': 'PNGDATA' })
    const r = await register({ id: 'shot-01', frameStart: 1, frameEnd: 24 })
    expect(r.status).toBe(201)
    const scene = await r.json()
    expect(scene.entry).toBe('shot.blend')
    expect(scene.files).toHaveLength(2)
    expect(scene.sizeBytes).toBe('BLENDER-x'.length + 'PNGDATA'.length)
  })

  it('re-registering forgets a file the scene no longer has', async () => {
    // A catalogue that only ever grew would keep sending nodes after a file
    // that is not part of the scene any more.
    putScene('shot-02', { 'shot.blend': 'B', 'old.png': 'X' })
    await register({ id: 'shot-02' })
    rmSync(join(sceneDir, 'shot-02', 'old.png'))
    const again = await register({ id: 'shot-02' })
    expect((await again.json()).files.map((f: any) => f.path)).toEqual(['shot.blend'])
  })

  it('refuses a scene name that could escape the repository', async () => {
    const r = await register({ id: '../../etc' })
    expect(r.status).toBe(400)
  })

  it('gives a node the manifest and the bytes', async () => {
    putScene('shot-03', { 'shot.blend': 'BLENDER-DATA' })
    await register({ id: 'shot-03' })

    const manifest = await fetch(`${base}/agent/v1/scenes/shot-03`, { headers: asNode() })
    expect(manifest.status).toBe(200)
    const body = await manifest.json()
    expect(body.entry).toBe('shot.blend')

    const file = await fetch(`${base}/agent/v1/scenes/shot-03/files/shot.blend`,
      { headers: asNode() })
    expect(file.status).toBe(200)
    expect(await file.text()).toBe('BLENDER-DATA')
  })

  it('serves only what the catalogue claims is part of a scene', async () => {
    // Checked against the catalogue before the disk, so the repository cannot
    // be walked by asking for a file that happens to be sitting in it.
    putScene('shot-04', { 'shot.blend': 'B' })
    await register({ id: 'shot-04' })
    // Written after registration, so it is genuinely sitting in the repository
    // and genuinely not in the catalogue.
    writeFileSync(join(sceneDir, 'shot-04', 'secret.txt'), 'not registered')
    const r = await fetch(`${base}/agent/v1/scenes/shot-04/files/secret.txt`,
      { headers: asNode() })
    expect(r.status).toBe(404)
  })

  it('turns a scene and a range into one unit per frame', async () => {
    putScene('shot-05', { 'shot.blend': 'B' })
    await register({ id: 'shot-05', frameStart: 1, frameEnd: 100 })

    const r = await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({
        poolId: fx.poolId, kind: 'render', sceneId: 'shot-05',
        frameStart: 5, frameEnd: 8, label: 'shot 05 overnight',
      }),
    })
    expect(r.status).toBe(201)
    const job = await r.json()
    // One frame per unit: a unit is the granularity at which work is thrown
    // away when somebody sits down at the machine, and one frame is minutes.
    expect(job.counts.pending).toBe(4)

    const { rows } = await db.query(
      `SELECT payload FROM work_units WHERE job_id=$1 ORDER BY position`, [job.id])
    expect(rows.map((r: any) => r.payload[0].frame)).toEqual([5, 6, 7, 8])
  })

  it('refuses a render job with no scene', async () => {
    const r = await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'render', frameStart: 1, frameEnd: 2 }),
    })
    expect(r.status).toBe(400)
  })

  it('tells the node which scene, on the lease', async () => {
    // On the lease rather than in the payload, so a unit cannot name the
    // content it wants. The unit says which frame; the job says of what.
    putScene('shot-06', { 'shot.blend': 'B' })
    await register({ id: 'shot-06' })
    await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'render', sceneId: 'shot-06',
                             frameStart: 1, frameEnd: 1 }),
    })
    await db.query(`UPDATE nodes SET presence_state='ABSENT' WHERE id=$1`, [fx.nodeId])

    const lease = await fetch(`${base}/agent/v1/work?kinds=render`, { headers: asNode() })
    expect(lease.status).toBe(200)
    const body = await lease.json()
    expect(body.sceneId).toBe('shot-06')
    expect(body.items[0].frame).toBe(1)
  })

  it('takes a frame back, and only from the node holding the lease', async () => {
    putScene('shot-07', { 'shot.blend': 'B' })
    await register({ id: 'shot-07' })
    const job = await (await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'render', sceneId: 'shot-07',
                             frameStart: 1, frameEnd: 1 }),
    })).json()
    await db.query(`UPDATE nodes SET presence_state='ABSENT' WHERE id=$1`, [fx.nodeId])
    const lease = await (await fetch(`${base}/agent/v1/work?kinds=render`,
      { headers: asNode() })).json()

    const png = Buffer.from('PNGDATA-frame-one')
    const up = await fetch(`${base}/agent/v1/work/${lease.unitId}/output/frame_0001.png`, {
      method: 'PUT',
      headers: { ...asNode(), 'content-type': 'application/octet-stream' },
      body: png,
    })
    expect(up.status).toBe(200)
    expect((await up.json()).sizeBytes).toBe(png.length)

    // The operator can get it back, which is the only reason any of this ran.
    const listed = await (await fetch(`${base}/admin/v1/jobs/${job.id}/outputs`,
      { headers: asUser(fx.operatorToken) })).json()
    expect(listed.outputs.map((o: any) => o.name)).toEqual(['frame_0001.png'])
    const got = await fetch(`${base}/admin/v1/jobs/${job.id}/outputs/frame_0001.png`,
      { headers: asUser(fx.operatorToken) })
    expect(Buffer.from(await got.arrayBuffer())).toEqual(png)
  })

  it('will not let a node overwrite a frame it is not rendering', async () => {
    // Without this any enrolled machine could replace any job's output, and a
    // fleet where that is possible is worse than one that cannot render: the
    // failure is invisible until somebody watches the sequence.
    putScene('shot-08', { 'shot.blend': 'B' })
    await register({ id: 'shot-08' })
    const job = await (await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'render', sceneId: 'shot-08',
                             frameStart: 1, frameEnd: 1 }),
    })).json()
    const { rows } = await db.query(
      `SELECT id FROM work_units WHERE job_id=$1`, [job.id])

    // Never leased to this node.
    const r = await fetch(`${base}/agent/v1/work/${rows[0].id}/output/frame_0001.png`, {
      method: 'PUT',
      headers: { ...asNode(), 'content-type': 'application/octet-stream' },
      body: Buffer.from('mine now'),
    })
    expect(r.status).toBe(403)
  })

  it('accepts the same frame twice, because a requeued unit is not a failure', async () => {
    // A render unit is idempotent: frame 12 of scene S is the same pixels
    // wherever it runs. Refusing the second copy would fail a job for
    // succeeding twice.
    putScene('shot-09', { 'shot.blend': 'B' })
    await register({ id: 'shot-09' })
    const job = await (await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'render', sceneId: 'shot-09',
                             frameStart: 1, frameEnd: 1 }),
    })).json()
    await db.query(`UPDATE nodes SET presence_state='ABSENT' WHERE id=$1`, [fx.nodeId])
    const lease = await (await fetch(`${base}/agent/v1/work?kinds=render`,
      { headers: asNode() })).json()

    const put = (body: string) =>
      fetch(`${base}/agent/v1/work/${lease.unitId}/output/frame_0001.png`, {
        method: 'PUT',
        headers: { ...asNode(), 'content-type': 'application/octet-stream' },
        body: Buffer.from(body),
      })
    expect((await put('first')).status).toBe(200)
    expect((await put('second attempt')).status).toBe(200)

    const listed = await (await fetch(`${base}/admin/v1/jobs/${job.id}/outputs`,
      { headers: asUser(fx.operatorToken) })).json()
    expect(listed.outputs).toHaveLength(1)
    expect(listed.outputs[0].sizeBytes).toBe('second attempt'.length)
  })

  it('refuses an output name that could escape the job directory', async () => {
    putScene('shot-10', { 'shot.blend': 'B' })
    await register({ id: 'shot-10' })
    await fetch(`${base}/admin/v1/jobs`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ poolId: fx.poolId, kind: 'render', sceneId: 'shot-10',
                             frameStart: 1, frameEnd: 1 }),
    })
    await db.query(`UPDATE nodes SET presence_state='ABSENT' WHERE id=$1`, [fx.nodeId])
    const lease = await (await fetch(`${base}/agent/v1/work?kinds=render`,
      { headers: asNode() })).json()

    const r = await fetch(
      `${base}/agent/v1/work/${lease.unitId}/output/${encodeURIComponent('../escaped.png')}`, {
        method: 'PUT',
        headers: { ...asNode(), 'content-type': 'application/octet-stream' },
        body: Buffer.from('x'),
      })
    expect(r.status).toBe(400)
  })
})
