import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { readFile, readdir, stat } from 'node:fs/promises'
import { join, relative } from 'node:path'
import type { Db } from './db.js'
import { ingest, repositoryRoot, type StoredFile } from './repository.js'

/**
 * Taking a model that is on this machine into the fleet's repository.
 *
 * Everything here happens in one pass over the files: hash, copy, verify,
 * register. Hashing is the whole point rather than a formality, because the
 * failure it catches is silent - a shard that stopped on a block boundary has a
 * plausible size and correct-looking contents, and only fails much later as a
 * corrupt-weights crash on whichever machine happened to load it first.
 *
 * Registered only after every file has landed. A half-registered model would be
 * assigned to pools and fetched by nodes that could never complete it, and each
 * of them would keep trying.
 */
export interface ImportProgress {
  filesDone: number
  filesTotal: number
  bytesDone: number
}

const sha256 = (path: string) => new Promise<string>((resolve, reject) => {
  const h = createHash('sha256')
  createReadStream(path)
    .on('data', (c) => h.update(c))
    .on('end', () => resolve(h.digest('hex')))
    .on('error', reject)
})

/**
 * The directory that actually holds a model's files.
 *
 * The Python hub client does not store a model as a directory of files. It
 * stores `blobs/` keyed by content hash, `snapshots/<commit>/` full of symlinks
 * into them, plus `refs/` and `trees/`. Copying that wholesale produced a
 * repository entry containing all four, with every file present twice - 16.6GB
 * for an 8.3GB model - in a layout swift-transformers cannot read. A node would
 * have fetched it, seen a populated directory, and failed to load it.
 *
 * So resolve to the snapshot, which is the flat view of the model, and let the
 * symlinks be followed when the files are read.
 */
async function resolveSource(dir: string): Promise<string> {
  let snapshots
  try { snapshots = await readdir(join(dir, 'snapshots'), { withFileTypes: true }) } catch {
    return dir
  }
  const commits = snapshots.filter((e) => e.isDirectory()).map((e) => e.name)
  if (commits.length === 0) return dir

  // refs/main names the commit that is checked out. Preferred over guessing,
  // because a cache that has seen two revisions holds both snapshots and only
  // one of them is the model anybody asked for.
  try {
    const ref = (await readFile(join(dir, 'refs', 'main'), 'utf8')).trim()
    if (commits.includes(ref)) return join(dir, 'snapshots', ref)
  } catch { /* no ref, fall through */ }

  // Newest wins when there is no ref to consult, which is at least a defensible
  // guess rather than an arbitrary one.
  const withTimes = await Promise.all(commits.map(async (c) => ({
    c, at: (await stat(join(dir, 'snapshots', c))).mtimeMs,
  })))
  withTimes.sort((a, b) => b.at - a.at)
  return join(dir, 'snapshots', withTimes[0]!.c)
}

/** Every file under a directory, relative, skipping hidden bookkeeping. */
async function walk(base: string, prefix = ''): Promise<string[]> {
  const out: string[] = []
  const here = prefix ? join(base, prefix) : base
  for (const entry of await readdir(here, { withFileTypes: true })) {
    // The hub's own cache differs between machines holding identical weights,
    // so including it would make two correct copies disagree on their hashes.
    if (entry.name.startsWith('.')) continue
    const rel = prefix ? join(prefix, entry.name) : entry.name
    if (entry.isDirectory()) out.push(...await walk(base, rel))
    else out.push(rel)
  }
  return out
}

/**
 * Guess what a model is from its name.
 *
 * Only the fields that are conveniences. The tool dialect is matched on the
 * chat template at load time rather than on the name, because names lie about
 * this and templates do not, so a wrong guess here costs nothing.
 */
function describe(id: string) {
  const name = id.toLowerCase()
  const quant = name.match(/(\d+)bit/)?.[0] ?? null
  const family = name.includes('qwen') ? 'hermes-qwen'
      : name.includes('llama') ? 'llama-3'
      : name.includes('mistral') ? 'mistral'
      : null
  const kind = /embed|bge|e5|gte|minilm/.test(name) ? 'embed' : 'generate'
  return { quant, family, kind }
}

/**
 * Begin an import, returning the row that tracks it.
 *
 * Recorded before any bytes move so the page has something to show. Hashing
 * eighteen gigabytes takes minutes, and until this existed the catalogue showed
 * nothing at all during them: the only honest reading of the page was that the
 * import had failed.
 */
export async function startImport(
  db: Db, id: string, source: string, userId: string,
): Promise<string> {
  const { rows } = await db.query(
    `INSERT INTO model_imports (model_id, source, started_by) VALUES ($1,$2,$3)
     RETURNING id`, [id, source, userId])
  return rows[0]!.id as string
}

export async function importModel(
  db: Db, id: string, sourceDir: string, userId: string,
  importId?: string,
): Promise<void> {
  const root = repositoryRoot()
  const note = async (patch: string, params: unknown[]) => {
    if (importId) await db.query(`UPDATE model_imports SET ${patch} WHERE id = $1`,
      [importId, ...params])
  }

  try {
    const root2 = await resolveSource(sourceDir)
    const paths = (await walk(root2)).sort()
    if (paths.length === 0) throw new Error(`no files under ${root2}`)
    await note('files_total = $2', [paths.length])

    const files: StoredFile[] = []
    let bytesDone = 0
    for (const rel of paths) {
      const full = join(root2, rel)
      const { size } = await stat(full)
      const file: StoredFile = {
        // Normalised to forward slashes so the path a node asks for is the path
        // the catalogue recorded, whatever wrote it.
        path: rel.split(/[\\/]/).join('/'),
        sizeBytes: size,
        sha256: await sha256(full),
      }
      await ingest(root, id, file, full)
      files.push(file)
      bytesDone += size
      await note('files_done = $2, bytes_done = $3', [files.length, bytesDone])
    }

    const { quant, family, kind } = describe(id)
    const total = files.reduce((n, f) => n + f.sizeBytes, 0)
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, quantization, family, imported_by)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [id, kind === 'embed' ? 'coreml' : 'mlx', kind, total, quant, family, userId],
    )
    for (const f of files) {
      await db.query(
        `INSERT INTO model_files (model_id, path, size_bytes, sha256) VALUES ($1,$2,$3,$4)`,
        [id, f.path, f.sizeBytes, f.sha256],
      )
    }
    await note(`state = 'done', finished_at = now()`, [])
  } catch (e) {
    // Recorded rather than only logged. A failed import that leaves no trace is
    // indistinguishable from one that was never started, and the person who
    // clicked the button is the last to find out.
    await note(`state = 'failed', finished_at = now(), error = $2`,
      [e instanceof Error ? e.message : String(e)])
    throw e
  }
}

export { relative }
