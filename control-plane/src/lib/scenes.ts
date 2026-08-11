import { createHash } from 'node:crypto'
import { createReadStream, existsSync } from 'node:fs'
import { readdir, stat } from 'node:fs/promises'
import { join, relative, resolve } from 'node:path'
import type { Db } from './db.js'
import { safePath, type StoredFile } from './repository.js'

/**
 * Scenes, and the frames that come back from them.
 *
 * A scene is content the fleet distributes, catalogued the same way a model is:
 * named, hashed per file, pulled once per site and then spread over the LAN.
 * The mechanics are deliberately the model repository's, because the property
 * that matters - the data does not leave the building - is the same property
 * and should not have two implementations.
 *
 * What differs is economics, and it is why this is a separate catalogue rather
 * than a `kind` column on models. A model is a few GB, cached once and shared by
 * every job. A scene is tens of GB, differs per job, and is worthless the moment
 * the job finishes. Nothing here is assignable to a pool or counted as
 * residency: a scene that stayed resident on forty machines after its job
 * completed would fill them, and the operator would have no reason to look.
 */

export function scenesRoot(): string {
  return process.env.DAI_SCENE_REPO ?? resolve(process.cwd(), 'scenes')
}

/**
 * Where finished frames land.
 *
 * Separate from the scene repository because the two have opposite lifetimes.
 * A scene is deletable the moment its job is done; the frames are the only
 * thing anybody wanted.
 */
export function outputsRoot(): string {
  return process.env.DAI_OUTPUT_DIR ?? resolve(process.cwd(), 'outputs')
}

/** Files a renderer will not open, and which should not be shipped to fifty machines. */
const IGNORED = new Set(['.DS_Store', 'Thumbs.db'])

/**
 * Every file in a scene directory, hashed.
 *
 * Symlinks are skipped rather than followed. A followed symlink both
 * double-counts a bundle's size and, worse, can reach outside it: a scene
 * containing a link to the artist's home directory would otherwise be
 * catalogued, distributed to the fleet, and served to any node that asked.
 */
export async function walk(dir: string, prefix = ''): Promise<StoredFile[]> {
  const out: StoredFile[] = []
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (IGNORED.has(entry.name)) continue
    const full = join(dir, entry.name)
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name
    if (entry.isSymbolicLink()) continue
    if (entry.isDirectory()) {
      out.push(...(await walk(full, rel)))
      continue
    }
    if (!entry.isFile()) continue
    const info = await stat(full)
    out.push({ path: rel, sizeBytes: info.size, sha256: await hashOf(full) })
  }
  return out
}

export async function hashOf(path: string): Promise<string> {
  const hash = createHash('sha256')
  const reader = createReadStream(path)
  for await (const chunk of reader) hash.update(chunk as Buffer)
  return hash.digest('hex')
}

/**
 * The file the renderer should open.
 *
 * Chosen here, once, and stored, rather than worked out on each node. Two
 * machines guessing differently would render two different scenes under one
 * name, and nothing downstream would say so - the frames would simply not
 * match. A bundle with more than one candidate is refused rather than resolved
 * by a rule like "shortest path", because the right answer is for a person to
 * say which one.
 */
export function entryOf(files: StoredFile[]): { entry: string } | { error: string } {
  const blends = files.filter((f) => f.path.toLowerCase().endsWith('.blend'))
  if (blends.length === 0) return { error: 'no .blend file in the scene' }
  if (blends.length > 1) {
    // Blender writes `shot.blend1` backups beside the file, which are not
    // candidates. Anything genuinely ambiguous is the submitter's to resolve.
    const names = blends.map((f) => f.path).sort()
    return { error: `more than one .blend file, name one explicitly: ${names.join(', ')}` }
  }
  return { entry: blends[0]!.path }
}

/** Whether every file of a scene is present at the size the catalogue records. */
export async function isComplete(root: string, sceneId: string, files: StoredFile[]) {
  for (const f of files) {
    const p = safePath(root, sceneId, f.path)
    if (!p || !existsSync(p)) return false
    if ((await stat(p)).size !== f.sizeBytes) return false
  }
  return true
}

/**
 * The frames a job covers, as a list.
 *
 * Rejected rather than clamped when the range falls outside what the scene
 * declares. A frame past the end renders black, lands as a real file, and looks
 * like a successful job until somebody plays it back.
 */
export function framesFor(
  start: number, end: number, step = 1,
  bounds?: { frameStart: number | null; frameEnd: number | null },
): { frames: number[] } | { error: string } {
  if (!Number.isInteger(start) || !Number.isInteger(end)) {
    return { error: 'frames must be whole numbers' }
  }
  if (!Number.isInteger(step) || step < 1) return { error: 'step must be at least 1' }
  if (end < start) return { error: `frame range ${start}-${end} ends before it starts` }
  // A cap, because a typo of 1-100000 is indistinguishable from an intention
  // until fifty machines are busy for a week.
  if ((end - start) / step + 1 > 20_000) {
    return { error: 'more than 20000 frames; split the job' }
  }
  if (bounds) {
    const lo = bounds.frameStart, hi = bounds.frameEnd
    if (lo != null && start < lo) return { error: `the scene starts at frame ${lo}` }
    if (hi != null && end > hi) return { error: `the scene ends at frame ${hi}` }
  }
  const frames: number[] = []
  for (let f = start; f <= end; f += step) frames.push(f)
  return { frames }
}

/** The name a rendered frame is stored under. Zero-padded so it sorts. */
export function frameName(frame: number, extension = 'png'): string {
  return `frame_${String(frame).padStart(4, '0')}.${extension}`
}

export interface SceneRow {
  id: string
  entry: string
  sizeBytes: number
  frameStart: number | null
  frameEnd: number | null
  renderer: string
  files: StoredFile[]
}

export async function sceneById(db: Db, id: string): Promise<SceneRow | null> {
  const { rows } = await db.query(
    `SELECT id, entry, size_bytes, frame_start, frame_end, renderer FROM scenes WHERE id=$1`,
    [id],
  )
  const s = rows[0] as any
  if (!s) return null
  const { rows: files } = await db.query(
    `SELECT path, size_bytes, sha256 FROM scene_files WHERE scene_id=$1 ORDER BY path`, [id])
  return {
    id: s.id,
    entry: s.entry,
    sizeBytes: Number(s.size_bytes),
    frameStart: s.frame_start,
    frameEnd: s.frame_end,
    renderer: s.renderer,
    files: (files as any[]).map((f) => ({
      path: f.path, sizeBytes: Number(f.size_bytes), sha256: f.sha256,
    })),
  }
}

/**
 * Register a directory as a scene.
 *
 * The bundle is catalogued where it already sits, under the scene repository
 * root, rather than copied. Scenes are large and short-lived, and a copy of a
 * 40GB bundle to register it is 40GB of disk and several minutes before a job
 * can even be submitted.
 */
export async function registerScene(
  db: Db,
  opts: { id: string; frameStart?: number | null; frameEnd?: number | null
          entry?: string | null; importedBy?: string | null },
): Promise<{ scene: SceneRow } | { error: string }> {
  const dir = safePath(scenesRoot(), opts.id)
  if (!dir) return { error: 'that scene name cannot be used as a directory' }
  if (!existsSync(dir)) return { error: `nothing at ${relative(process.cwd(), dir)}` }

  const files = await walk(dir)
  if (files.length === 0) return { error: 'the scene directory is empty' }

  let entry = opts.entry ?? null
  if (entry) {
    if (!files.some((f) => f.path === entry)) return { error: `${entry} is not in the scene` }
  } else {
    const found = entryOf(files)
    if ('error' in found) return found
    entry = found.entry
  }

  const size = files.reduce((n, f) => n + f.sizeBytes, 0)
  await db.query(
    `INSERT INTO scenes (id, entry, size_bytes, frame_start, frame_end, imported_by)
     VALUES ($1,$2,$3,$4,$5,$6)
     ON CONFLICT (id) DO UPDATE
       SET entry = EXCLUDED.entry, size_bytes = EXCLUDED.size_bytes,
           frame_start = EXCLUDED.frame_start, frame_end = EXCLUDED.frame_end`,
    [opts.id, entry, size, opts.frameStart ?? null, opts.frameEnd ?? null,
     opts.importedBy ?? null],
  )
  // Replaced wholesale, so a re-registered scene that lost a file loses it here
  // too. A catalogue that only ever grows would keep sending nodes after a file
  // that is no longer part of the scene.
  await db.query(`DELETE FROM scene_files WHERE scene_id=$1`, [opts.id])
  for (const f of files) {
    await db.query(
      `INSERT INTO scene_files (scene_id, path, size_bytes, sha256) VALUES ($1,$2,$3,$4)`,
      [opts.id, f.path, f.sizeBytes, f.sha256],
    )
  }
  const scene = await sceneById(db, opts.id)
  return scene ? { scene } : { error: 'the scene was not registered' }
}
