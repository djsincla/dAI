import { createReadStream, createWriteStream, existsSync } from 'node:fs'
import { mkdir, rename, stat, unlink } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { dirname, join, resolve, sep } from 'node:path'
import { pipeline } from 'node:stream/promises'

/**
 * Where the fleet's weights actually live.
 *
 * The catalogue records what a model is and what it should hash to; this holds
 * the bytes. Until it existed, assignment declared an intention that nothing
 * could act on and weights travelled between machines by scp.
 *
 * On-premises by construction. One pull from the internet per site, then
 * distribution over the LAN, which is what makes "the data does not leave the
 * building" true of the weights as well as the prompts.
 */
export function repositoryRoot(): string {
  return process.env.DAI_MODEL_REPO ?? resolve(process.cwd(), 'models')
}

/**
 * A path inside the repository, or an error.
 *
 * Model ids and file paths both arrive from callers and both contain slashes,
 * so this is a directory traversal waiting to happen: `../../etc/passwd` as a
 * file path would otherwise be served to any node that asked, over an
 * authenticated channel, by a process that can read the private key of the
 * fleet CA.
 *
 * Allow-list rather than deny-list. Rejecting `..` catches the obvious attempt
 * and misses percent-encoding, unicode lookalikes and absolute paths; naming
 * the characters that are permitted has no such gaps.
 */
const SEGMENT = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

export function safePath(root: string, modelId: string, filePath = ''): string | null {
  const segments = [...modelId.split('/'), ...(filePath ? filePath.split('/') : [])]
  if (segments.length === 0) return null
  for (const s of segments) {
    // Empty segments are rejected rather than dropped. Silently normalising
    // "/etc" to "etc" would let two different model ids name one directory,
    // and a content store where two names collide is one where the wrong
    // weights can be served under the right name.
    if (s === '' || s === '.' || s === '..' || !SEGMENT.test(s)) return null
  }
  const full = join(root, ...segments)
  // Belt and braces. If the checks above are ever loosened, this still refuses
  // to hand back a path that escaped the root.
  const bounded = resolve(root) + sep
  return resolve(full).startsWith(bounded) ? full : null
}

export interface StoredFile { path: string; sizeBytes: number; sha256: string }

/** Whether every file of a model is present at the size the catalogue records. */
export async function isComplete(root: string, modelId: string, files: StoredFile[]) {
  for (const f of files) {
    const p = safePath(root, modelId, f.path)
    if (!p) return false
    try {
      const s = await stat(p)
      if (s.size !== Number(f.sizeBytes)) return false
    } catch { return false }
  }
  return files.length > 0
}

/**
 * Copy a file into the repository, hashing as it goes.
 *
 * Written to a temporary name and renamed only after the hash matches, so an
 * interrupted copy cannot leave a file that looks complete. This is the exact
 * failure that was invisible when weights moved by hand: rsync left a partial
 * shard under a temp name and a size check on the directory counted it as
 * finished.
 */
export async function ingest(
  root: string, modelId: string, file: StoredFile, source: string,
): Promise<void> {
  const dest = safePath(root, modelId, file.path)
  if (!dest) throw new Error(`unsafe path: ${modelId}/${file.path}`)
  await mkdir(dirname(dest), { recursive: true })

  const tmp = `${dest}.partial`
  const hash = createHash('sha256')
  const reader = createReadStream(source)
  reader.on('data', (c) => hash.update(c))
  await pipeline(reader, createWriteStream(tmp))

  const got = hash.digest('hex')
  if (got !== file.sha256) {
    await unlink(tmp).catch(() => {})
    throw new Error(`${file.path}: expected ${file.sha256}, got ${got}`)
  }
  await rename(tmp, dest)
}

export function has(root: string, modelId: string, filePath: string): boolean {
  const p = safePath(root, modelId, filePath)
  return p !== null && existsSync(p)
}
