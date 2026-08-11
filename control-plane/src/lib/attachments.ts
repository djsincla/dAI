import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises'
import { dirname, join, resolve as resolvePath } from 'node:path'
import type { Db } from './db.js'

/**
 * Content that arrives with a job, and leaves with it.
 *
 * The requester uploads what the render needs, the fleet holds it for as long
 * as the render takes, the frames go back, and then everything is deleted. That
 * lifetime is the whole design. A scene is tens of gigabytes and belongs to
 * whoever submitted it; a fleet that kept one indefinitely would be storing
 * somebody else's work on somebody else's workstations, with no reason for
 * anyone to notice until the disks filled.
 *
 * Content-addressed, which buys two things beyond deduplication. A resubmission
 * after a lighting tweak uploads the one file that changed rather than the
 * bundle. And a file's name is its hash, so a truncated or substituted upload
 * cannot be stored under the name of the file it was meant to be.
 */

export function blobRoot(): string {
  return process.env.DAI_BLOB_STORE ?? resolvePath(process.cwd(), 'blobs')
}

export function outputsRoot(): string {
  return process.env.DAI_OUTPUT_DIR ?? resolvePath(process.cwd(), 'outputs')
}

/** After a requester collects a frame, how long before it is deleted. */
export function retentionAfterCollection(): number {
  return Number(process.env.DAI_OUTPUT_RETENTION_S ?? 24 * 3600)
}

/**
 * How long an *uncollected* frame survives.
 *
 * Needed because the other clock never starts if nobody comes back for the
 * work. Without this, "we do not hold assets indefinitely" would be true only
 * of jobs somebody remembered to collect, which is the wrong half.
 */
export function maxAgeAfterCompletion(): number {
  return Number(process.env.DAI_OUTPUT_MAX_AGE_S ?? 7 * 24 * 3600)
}

const HEX64 = /^[0-9a-f]{64}$/

/**
 * Where a blob lives.
 *
 * Fanned out one level, because a flat directory of a hundred thousand files is
 * slow to list on every filesystem that matters and impossible to look at.
 *
 * The hash is validated rather than trusted: it comes from a caller and becomes
 * a path. Requiring exactly 64 lowercase hex characters leaves nothing to
 * escape with - no separator, no dot, no encoding.
 */
export function blobPath(sha256: string, root = blobRoot()): string | null {
  if (!HEX64.test(sha256)) return null
  return join(root, sha256.slice(0, 2), sha256)
}

export function hashOf(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex')
}

/**
 * Store bytes under their own hash.
 *
 * The hash is computed here and compared with what the caller claimed. An
 * upload that does not hash to the name it was sent under is refused: accepting
 * it would put the wrong bytes under a name some job is about to fetch, and
 * every machine would render it without complaint.
 */
export async function putBlob(
  db: Db, claimed: string, bytes: Buffer,
): Promise<{ sha256: string; sizeBytes: number } | { error: string }> {
  const actual = hashOf(bytes)
  if (claimed && claimed !== actual) {
    return { error: `content does not match its name: claimed ${claimed}, got ${actual}` }
  }
  const path = blobPath(actual)
  if (!path) return { error: 'that is not a sha256' }

  if (!existsSync(path)) {
    await mkdir(dirname(path), { recursive: true })
    // Written aside and moved into place, so an interrupted upload leaves
    // nothing rather than a short file under a name that promises otherwise.
    const partial = `${path}.partial`
    await writeFile(partial, bytes)
    await rename(partial, path)
  }
  await db.query(
    `INSERT INTO attachment_blobs (sha256, size_bytes) VALUES ($1,$2)
     ON CONFLICT (sha256) DO UPDATE SET last_used_at = now()`,
    [actual, bytes.length],
  )
  return { sha256: actual, sizeBytes: bytes.length }
}

export async function readBlob(sha256: string): Promise<Buffer | null> {
  const path = blobPath(sha256)
  if (!path || !existsSync(path)) return null
  return readFile(path)
}

export interface AttachmentEntry {
  path: string
  sha256: string
  dataFlow?: 'IN' | 'OUT' | 'INOUT'
}

/** A path that can be written inside a job's working set and nowhere else. */
const SEGMENT = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

export function isSafeRelativePath(path: string): boolean {
  if (path === '' || path.startsWith('/')) return false
  const segments = path.split('/')
  return segments.every((s) => SEGMENT.test(s))
}

/**
 * Record what a job needs.
 *
 * Every blob must already be stored. A manifest naming content nobody uploaded
 * would be a job that leases a machine, fetches, fails, and repeats on the next
 * machine - so it is refused here, once, to the person who can fix it.
 */
export async function attach(
  db: Db, jobId: string, entries: AttachmentEntry[],
): Promise<{ attached: number } | { error: string }> {
  for (const e of entries) {
    if (!isSafeRelativePath(e.path)) {
      return { error: `${JSON.stringify(e.path)} cannot be a path inside a job` }
    }
    if (!blobPath(e.sha256)) return { error: `${e.path}: that is not a sha256` }
    const { rows } = await db.query(
      `SELECT 1 FROM attachment_blobs WHERE sha256=$1`, [e.sha256])
    if (rows.length === 0) return { error: `${e.path}: nothing uploaded for ${e.sha256}` }
  }
  for (const e of entries) {
    await db.query(
      `INSERT INTO job_attachments (job_id, path, sha256, data_flow) VALUES ($1,$2,$3,$4)
       ON CONFLICT (job_id, path) DO UPDATE SET sha256=EXCLUDED.sha256,
                                                data_flow=EXCLUDED.data_flow`,
      [jobId, e.path, e.sha256, e.dataFlow ?? 'IN'],
    )
    await db.query(`UPDATE attachment_blobs SET last_used_at = now() WHERE sha256=$1`,
      [e.sha256])
  }
  return { attached: entries.length }
}

export async function manifestFor(db: Db, jobId: string): Promise<AttachmentEntry[]> {
  const { rows } = await db.query(
    `SELECT a.path, a.sha256, a.data_flow, b.size_bytes
       FROM job_attachments a JOIN attachment_blobs b ON b.sha256 = a.sha256
      WHERE a.job_id = $1 AND a.data_flow IN ('IN','INOUT')
      ORDER BY a.path`, [jobId])
  return (rows as any[]).map((r) => ({
    path: r.path, sha256: r.sha256, dataFlow: r.data_flow, sizeBytes: Number(r.size_bytes),
  })) as AttachmentEntry[]
}

/**
 * Delete what a job needed, now that it does not.
 *
 * Called when a job reaches a terminal state. The inputs are dead at that
 * moment: nothing will be rendered from them again, and the frames are what
 * anybody wanted. The blobs themselves go only if no other live job references
 * them, which is what makes sharing a texture library safe.
 */
export async function releaseInputs(db: Db, jobId: string): Promise<{ blobsDeleted: number }> {
  await db.query(`DELETE FROM job_attachments WHERE job_id=$1`, [jobId])
  return collectGarbage(db)
}

/** Blobs no live job references. */
export async function collectGarbage(db: Db): Promise<{ blobsDeleted: number }> {
  const { rows } = await db.query(
    `DELETE FROM attachment_blobs b
      WHERE NOT EXISTS (SELECT 1 FROM job_attachments a WHERE a.sha256 = b.sha256)
      RETURNING sha256`)
  let deleted = 0
  for (const row of rows as { sha256: string }[]) {
    const path = blobPath(row.sha256)
    if (path) await rm(path, { force: true })
    deleted += 1
  }
  return { blobsDeleted: deleted }
}

/**
 * Delete frames whose time is up.
 *
 * Two clocks, because either alone leaves something held forever. Collected
 * frames go a day after collection, so a requester can fetch twice without
 * racing a deletion. Uncollected ones go a week after the job finished,
 * because a job nobody came back for is exactly the case that would otherwise
 * accumulate silently.
 */
export async function expireOutputs(
  db: Db, now = new Date(),
): Promise<{ deleted: string[] }> {
  const { rows } = await db.query(
    `SELECT o.job_id, o.name
       FROM work_outputs o JOIN jobs j ON j.id = o.job_id
      WHERE (o.collected_at IS NOT NULL AND o.collected_at < $1)
         OR (j.completed_at IS NOT NULL AND j.completed_at < $2)`,
    [new Date(now.getTime() - retentionAfterCollection() * 1000),
     new Date(now.getTime() - maxAgeAfterCompletion() * 1000)],
  )
  const deleted: string[] = []
  for (const row of rows as { job_id: string; name: string }[]) {
    const path = outputPath(row.job_id, row.name)
    if (path) await rm(path, { force: true })
    await db.query(`DELETE FROM work_outputs WHERE job_id=$1 AND name=$2`,
      [row.job_id, row.name])
    deleted.push(`${row.job_id}/${row.name}`)
  }
  return { deleted }
}

/** Where a finished frame sits while it waits to be collected. */
export function outputPath(jobId: string, name: string, root = outputsRoot()): string | null {
  if (!/^[0-9a-fA-F-]{36}$/.test(jobId)) return null
  if (!isSafeRelativePath(name) || name.includes('/')) return null
  return join(root, jobId, name)
}

/**
 * Whether every unit of a job has stopped.
 *
 * The moment the inputs become deletable, so it is asked after each result
 * rather than on a timer: holding tens of gigabytes for the length of a polling
 * interval is holding it for no reason.
 */
export async function finishIfDone(
  db: Db, jobId: string,
): Promise<{ finished: boolean; blobsDeleted: number }> {
  const { rows } = await db.query(
    `SELECT count(*) FILTER (WHERE state IN ('pending','leased'))::int AS live
       FROM work_units WHERE job_id = $1`, [jobId])
  if ((rows[0]?.live ?? 0) > 0) return { finished: false, blobsDeleted: 0 }

  const { rows: failed } = await db.query(
    `SELECT count(*) FILTER (WHERE state='failed')::int AS n FROM work_units WHERE job_id=$1`,
    [jobId])
  await db.query(
    `UPDATE jobs SET state=$2, completed_at=COALESCE(completed_at, now()) WHERE id=$1`,
    [jobId, (failed[0]?.n ?? 0) > 0 ? 'failed' : 'complete'],
  )
  const { blobsDeleted } = await releaseInputs(db, jobId)
  return { finished: true, blobsDeleted }
}
