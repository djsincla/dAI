import type { Server } from 'node:http'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import {
  blobPath, collectGarbage, expireOutputs, hashOf, isSafeRelativePath, outputPath,
  uploadGrace,
} from '../src/lib/attachments.js'
import { SPECIFICATION_VERSION, type JobTemplate } from '../src/lib/openjd.js'
import { type Fixtures, appFor, freshDb, seed } from './helpers.js'

/**
 * Content that arrives with a job and leaves with it.
 *
 * The lifetime is the design. A scene is tens of gigabytes and belongs to
 * whoever submitted it; a fleet that kept one indefinitely would be storing
 * somebody else's work on somebody else's workstations, with nobody having a
 * reason to notice until the disks filled.
 */
describe('naming content by its own hash', () => {
  it('refuses anything that is not a sha256, because the name becomes a path', () => {
    expect(blobPath('../../etc/passwd')).toBeNull()
    expect(blobPath('')).toBeNull()
    expect(blobPath('ABC')).toBeNull()
    // Uppercase is a different string and would store the same content twice.
    expect(blobPath('A'.repeat(64))).toBeNull()
    expect(blobPath('a'.repeat(64))).toContain('/aa/')
  })

  it('fans out one level, so the store stays listable', () => {
    const path = blobPath('deadbeef' + 'a'.repeat(56), '/store')
    expect(path).toBe(`/store/de/deadbeef${'a'.repeat(56)}`)
  })

  it('refuses a job-relative path that could escape', () => {
    expect(isSafeRelativePath('tex/wood.png')).toBe(true)
    expect(isSafeRelativePath('../secrets')).toBe(false)
    expect(isSafeRelativePath('/etc/passwd')).toBe(false)
    expect(isSafeRelativePath('a//b')).toBe(false)
    expect(isSafeRelativePath('')).toBe(false)
  })

  it('keeps an output under its own job and nowhere else', () => {
    const job = '11111111-2222-3333-4444-555555555555'
    expect(outputPath(job, 'frame_0001.png', '/out')).toBe(`/out/${job}/frame_0001.png`)
    expect(outputPath(job, '../escaped.png', '/out')).toBeNull()
    expect(outputPath(job, 'sub/frame.png', '/out')).toBeNull()
    expect(outputPath('not-a-job', 'frame.png', '/out')).toBeNull()
  })
})

describe('a job holding content only while it needs it', () => {
  let db: Db
  let fx: Fixtures
  let server: Server
  let base: string
  let blobDir: string
  let outDir: string

  beforeEach(async () => {
    blobDir = mkdtempSync(join(tmpdir(), 'dai-blobs-'))
    outDir = mkdtempSync(join(tmpdir(), 'dai-out-'))
    process.env.DAI_BLOB_STORE = blobDir
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
    rmSync(blobDir, { recursive: true, force: true })
    rmSync(outDir, { recursive: true, force: true })
    delete process.env.DAI_BLOB_STORE
    delete process.env.DAI_OUTPUT_DIR
    delete process.env.DAI_OUTPUT_RETENTION_S
    delete process.env.DAI_OUTPUT_MAX_AGE_S
  })
  afterAll(async () => { await db?.end() })

  const asUser = () =>
    ({ authorization: `Bearer ${fx.operatorToken}`, 'content-type': 'application/json' })
  const asNode = () => ({ 'x-node-fingerprint': fx.fingerprint })

  const upload = (bytes: Buffer) =>
    fetch(`${base}/admin/v1/blobs/${hashOf(bytes)}`, {
      method: 'PUT',
      headers: { authorization: `Bearer ${fx.operatorToken}`,
                 'content-type': 'application/octet-stream' },
      body: new Uint8Array(bytes),
    })

  const template: JobTemplate = {
    specificationVersion: SPECIFICATION_VERSION,
    name: 'shot-050',
    steps: [{
      name: 'Render',
      parameterSpace: {
        taskParameterDefinitions: [{ name: 'Frame', type: 'INT', range: '1-2' }],
      },
      script: { actions: { onRun: { command: 'blender' } } },
    }],
  }

  async function submit(bytes = Buffer.from('BLENDER-SCENE-DATA')) {
    await upload(bytes)
    const r = await fetch(`${base}/admin/v1/jobs/openjd`, {
      method: 'POST', headers: asUser(),
      body: JSON.stringify({
        poolId: fx.poolId, template,
        attachments: [{ path: 'shot.blend', sha256: hashOf(bytes), dataFlow: 'IN' }],
      }),
    })
    return { response: r, job: r.status === 201 ? await r.json() : null, sha: hashOf(bytes) }
  }

  it('stores content once, however many times it is offered', async () => {
    // A resubmission after a lighting tweak should upload the file that
    // changed, not the bundle.
    const bytes = Buffer.from('a texture')
    expect((await upload(bytes)).status).toBe(200)
    expect((await upload(bytes)).status).toBe(200)
    const { rows } = await db.query(`SELECT count(*)::int AS n FROM attachment_blobs`)
    expect(rows[0].n).toBe(1)
  })

  it('tells a submitter what it does not already have', async () => {
    const here = Buffer.from('already here')
    await upload(here)
    const r = await fetch(`${base}/admin/v1/blobs/missing`, {
      method: 'POST', headers: asUser(),
      body: JSON.stringify({ sha256s: [hashOf(here), 'b'.repeat(64)] }),
    })
    expect((await r.json()).missing).toEqual(['b'.repeat(64)])
  })

  it('refuses content that does not hash to the name it was sent under', async () => {
    // Accepting it would put the wrong bytes under a name some job is about to
    // fetch, and every machine would render it without complaint.
    const r = await fetch(`${base}/admin/v1/blobs/${'c'.repeat(64)}`, {
      method: 'PUT',
      headers: { authorization: `Bearer ${fx.operatorToken}`,
                 'content-type': 'application/octet-stream' },
      body: new Uint8Array(Buffer.from('not what was claimed')),
    })
    expect(r.status).toBe(400)
    expect((await r.json()).detail).toContain('does not match its name')
  })

  it('takes an OpenJD template and makes one unit per frame', async () => {
    const { response, job } = await submit()
    expect(response.status).toBe(201)
    expect(job.counts.pending).toBe(2)
    expect(job.kind).toBe('render')
  })

  it('refuses a submission naming content nobody uploaded', async () => {
    // Otherwise the job leases a machine, fetches, fails, and repeats on the
    // next machine, reporting as a fleet-wide fault.
    const r = await fetch(`${base}/admin/v1/jobs/openjd`, {
      method: 'POST', headers: asUser(),
      body: JSON.stringify({
        poolId: fx.poolId, template,
        attachments: [{ path: 'shot.blend', sha256: 'd'.repeat(64) }],
      }),
    })
    expect(r.status).toBe(400)
    expect((await r.json()).detail).toContain('nothing uploaded')
    // And no half-made job is left behind.
    const { rows } = await db.query(`SELECT count(*)::int AS n FROM jobs`)
    expect(rows[0].n).toBe(0)
  })

  it('gives a node the manifest and the content', async () => {
    const { job, sha } = await submit()
    const manifest = await (await fetch(`${base}/agent/v1/jobs/${job.id}/attachments`,
      { headers: asNode() })).json()
    expect(manifest.entry).toBe('shot.blend')
    expect(manifest.files).toEqual([
      expect.objectContaining({ path: 'shot.blend', sha256: sha }),
    ])

    const content = await fetch(`${base}/agent/v1/blobs/${sha}`, { headers: asNode() })
    expect(await content.text()).toBe('BLENDER-SCENE-DATA')
  })

  it('deletes the inputs the moment the last frame is done', async () => {
    // The point of the whole exercise. Nothing will be rendered from them
    // again, and the frames are what anybody wanted.
    const { job, sha } = await submit()
    expect(existsSync(blobPath(sha)!)).toBe(true)

    await db.query(`UPDATE nodes SET presence_state='ABSENT' WHERE id=$1`, [fx.nodeId])
    for (let i = 0; i < 2; i++) {
      const lease = await (await fetch(`${base}/agent/v1/work?kinds=render`,
        { headers: asNode() })).json()
      await fetch(`${base}/agent/v1/work/${lease.unitId}/result`, {
        method: 'POST', headers: { ...asNode(), 'content-type': 'application/json' },
        body: JSON.stringify({ completed: lease.items, unfinished: [], seconds: 1 }),
      })
    }

    const { rows } = await db.query(`SELECT state, completed_at FROM jobs WHERE id=$1`, [job.id])
    expect(rows[0].state).toBe('complete')
    expect(rows[0].completed_at).not.toBeNull()
    // Gone from the catalogue and gone from the disk.
    const { rows: left } = await db.query(`SELECT count(*)::int AS n FROM attachment_blobs`)
    expect(left[0].n).toBe(0)
    expect(existsSync(blobPath(sha)!)).toBe(false)
  })

  it('keeps content a second live job still needs', async () => {
    // What makes sharing a texture library safe. Deleting on the first job to
    // finish would pull the ground out from under the second.
    const bytes = Buffer.from('shared library')
    const first = await submit(bytes)
    const second = await submit(bytes)
    expect(existsSync(blobPath(first.sha)!)).toBe(true)

    await db.query(`DELETE FROM work_units WHERE job_id=$1`, [first.job.id])
    const { finishIfDone } = await import('../src/lib/attachments.js')
    await finishIfDone(db, first.job.id)

    expect(existsSync(blobPath(second.sha)!)).toBe(true)
    const { rows } = await db.query(
      `SELECT count(*)::int AS n FROM job_attachments WHERE job_id=$1`, [second.job.id])
    expect(rows[0].n).toBe(1)
  })

  it('deletes a collected frame once its retention is up', async () => {
    process.env.DAI_OUTPUT_RETENTION_S = '3600'
    const { job } = await submit()
    await db.query(
      `INSERT INTO work_outputs (job_id, name, size_bytes, sha256, collected_at)
       VALUES ($1,'frame_0001.png',10,'x', now() - interval '2 hours')`, [job.id])

    const swept = await expireOutputs(db)
    expect(swept.deleted).toHaveLength(1)
    const { rows } = await db.query(`SELECT count(*)::int AS n FROM work_outputs`)
    expect(rows[0].n).toBe(0)
  })

  it('deletes a frame nobody ever collected', async () => {
    // The half that would otherwise accumulate silently: "we do not hold
    // assets indefinitely" must be true of jobs nobody came back for, which is
    // exactly the case the other clock never covers.
    process.env.DAI_OUTPUT_MAX_AGE_S = '3600'
    const { job } = await submit()
    await db.query(`UPDATE jobs SET completed_at = now() - interval '2 hours' WHERE id=$1`,
      [job.id])
    await db.query(
      `INSERT INTO work_outputs (job_id, name, size_bytes, sha256)
       VALUES ($1,'frame_0001.png',10,'x')`, [job.id])

    expect((await expireOutputs(db)).deleted).toHaveLength(1)
  })

  it('does not delete a frame that is still within its window', async () => {
    process.env.DAI_OUTPUT_RETENTION_S = '86400'
    process.env.DAI_OUTPUT_MAX_AGE_S = '604800'
    const { job } = await submit()
    await db.query(
      `INSERT INTO work_outputs (job_id, name, size_bytes, sha256, collected_at)
       VALUES ($1,'frame_0001.png',10,'x', now())`, [job.id])
    expect((await expireOutputs(db)).deleted).toEqual([])
  })

  it('marks a frame collected when the requester takes it', async () => {
    const { job } = await submit()
    const { mkdirSync, writeFileSync } = await import('node:fs')
    mkdirSync(join(outDir, job.id), { recursive: true })
    writeFileSync(join(outDir, job.id, 'frame_0001.png'), 'PNG')
    await db.query(
      `INSERT INTO work_outputs (job_id, name, size_bytes, sha256)
       VALUES ($1,'frame_0001.png',3,'x')`, [job.id])

    const r = await fetch(`${base}/admin/v1/jobs/${job.id}/outputs/frame_0001.png`,
      { headers: asUser() })
    expect(r.status).toBe(200)
    // And says how long it will keep it, so a submitter knows without asking.
    expect(r.headers.get('x-dai-retention-seconds')).toBeTruthy()

    const { rows } = await db.query(
      `SELECT collected_at FROM work_outputs WHERE job_id=$1`, [job.id])
    expect(rows[0].collected_at).not.toBeNull()
  })

  it('will not serve content no live job references', async () => {
    // Content whose last job finished is unreachable before the reaper gets to
    // it, so a node cannot enumerate the store by guessing hashes either.
    const bytes = Buffer.from('orphan')
    await upload(bytes)
    const r = await fetch(`${base}/agent/v1/blobs/${hashOf(bytes)}`, { headers: asNode() })
    expect(r.status).toBe(404)
  })

  it('does not delete an upload that has not been submitted yet', async () => {
    // The bug this exists for. A submitter uploads its content and then submits
    // the job, so between the two the blob is referenced by nothing. The sweep
    // runs every fifteen seconds; an upload of any size takes longer than that.
    // Collecting on "unreferenced" alone deleted the scene mid-submission, and
    // the submission then failed saying nothing had been uploaded.
    const bytes = Buffer.from('a scene still being uploaded')
    await upload(bytes)

    expect((await collectGarbage(db)).blobsDeleted).toBe(0)
    expect(existsSync(blobPath(hashOf(bytes))!)).toBe(true)

    // And it still works once submitted, which is the case that must not have
    // been broken by fixing the other one.
    const r = await fetch(`${base}/admin/v1/jobs/openjd`, {
      method: 'POST', headers: asUser(),
      body: JSON.stringify({
        poolId: fx.poolId, template,
        attachments: [{ path: 'shot.blend', sha256: hashOf(bytes) }],
      }),
    })
    expect(r.status).toBe(201)
  })

  it('does delete an upload nobody ever submitted', async () => {
    // The other half: an abandoned submission must not be kept either. Only
    // the window is protected, not the content.
    const bytes = Buffer.from('an upload nobody used')
    await upload(bytes)
    await db.query(
      `UPDATE attachment_blobs SET last_used_at = now() - ($1 || ' seconds')::interval
        WHERE sha256 = $2`, [uploadGrace() + 60, hashOf(bytes)])

    expect((await collectGarbage(db)).blobsDeleted).toBe(1)
    expect(existsSync(blobPath(hashOf(bytes))!)).toBe(false)
  })

  it('deletes a finished job\'s content without waiting out the grace period', async () => {
    // A job that finishes inside the upload window still releases immediately:
    // its content was referenced by a job that is over, so it is certainly not
    // a submission in progress.
    const { job, sha } = await submit()
    await db.query(`DELETE FROM work_units WHERE job_id=$1`, [job.id])
    const { finishIfDone } = await import('../src/lib/attachments.js')
    expect((await finishIfDone(db, job.id)).blobsDeleted).toBe(1)
    expect(existsSync(blobPath(sha)!)).toBe(false)
  })

  it('refuses to guess which scene to open when several are attached', async () => {
    // Picking the first silently means rendering a different scene from the one
    // the submitter meant, and nothing downstream says so: the frames simply
    // come out wrong.
    const a = Buffer.from('scene one')
    const b2 = Buffer.from('scene two')
    await upload(a)
    await upload(b2)
    const r = await fetch(`${base}/admin/v1/jobs/openjd`, {
      method: 'POST', headers: asUser(),
      body: JSON.stringify({
        poolId: fx.poolId, template,
        attachments: [{ path: 'shot.blend', sha256: hashOf(a) },
                      { path: 'shot_old.blend', sha256: hashOf(b2) }],
      }),
    })
    expect(r.status).toBe(400)
    const detail = (await r.json()).detail
    expect(detail).toContain('more than one scene')
    expect(detail).toContain('shot_old.blend')
  })

  it('takes the one named explicitly when there are several', async () => {
    const a = Buffer.from('scene one')
    const b2 = Buffer.from('scene two')
    await upload(a)
    await upload(b2)
    const r = await fetch(`${base}/admin/v1/jobs/openjd`, {
      method: 'POST', headers: asUser(),
      body: JSON.stringify({
        poolId: fx.poolId, template, entryPath: 'shot_old.blend',
        attachments: [{ path: 'shot.blend', sha256: hashOf(a) },
                      { path: 'shot_old.blend', sha256: hashOf(b2) }],
      }),
    })
    expect(r.status).toBe(201)
    const { rows } = await db.query(`SELECT entry_path FROM jobs WHERE id=$1`,
      [(await r.json()).id])
    expect(rows[0].entry_path).toBe('shot_old.blend')
  })

  it('sweeps content left behind by a job that was deleted', async () => {
    // Past the grace period, because this test previously asserted that a
    // fresh upload is collected at once - which is the behaviour that deleted
    // scenes out from under submissions in progress.
    const bytes = Buffer.from('left behind')
    await upload(bytes)
    await db.query(
      `UPDATE attachment_blobs SET last_used_at = now() - ($1 || ' seconds')::interval
        WHERE sha256 = $2`, [uploadGrace() + 60, hashOf(bytes)])

    expect(existsSync(blobPath(hashOf(bytes))!)).toBe(true)
    expect((await collectGarbage(db)).blobsDeleted).toBe(1)
    expect(existsSync(blobPath(hashOf(bytes))!)).toBe(false)
  })
})
