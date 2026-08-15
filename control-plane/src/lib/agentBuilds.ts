import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { copyFile, mkdir, stat } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { Db } from './db.js'
import { repositoryRoot, safePath } from './repository.js'

/**
 * Agent binaries the fleet may be asked to run.
 *
 * Stored beside the model weights and by the same rules, because the risk is
 * the same shape and worse in degree: a corrupted model produces bad answers,
 * a corrupted binary produces a machine that will not come back. The hash is
 * recorded on the way in and checked by the node before it will replace what it
 * is running.
 */
export interface AgentBuild {
  version: string
  sha256: string
  sizeBytes: number
  notes: string | null
}

/** Where a build's bytes live. Version is a path segment, so it is validated. */
export function buildPath(version: string): string | null {
  return safePath(repositoryRoot(), 'agent', `${version}/dai-agent`)
}

const sha256 = (path: string) => new Promise<string>((resolve, reject) => {
  const h = createHash('sha256')
  createReadStream(path)
    .on('data', (c) => h.update(c))
    .on('end', () => resolve(h.digest('hex')))
    .on('error', reject)
})

/**
 * Take a binary into the repository and record what it is.
 *
 * The version becomes a directory name, so it goes through the same allow-list
 * as everything else a caller names: this process can read the private key of
 * the CA that signs every node certificate, and a version string is a path
 * component somebody typed.
 */
export async function registerAgentBuild(
  db: Db, version: string, source: string, notes: string | null, userId: string,
): Promise<AgentBuild> {
  const dest = buildPath(version)
  if (!dest) throw new Error(`unsafe version name: ${version}`)

  const { size } = await stat(source)
  if (size === 0) throw new Error('refusing to register an empty binary')

  await mkdir(dirname(dest), { recursive: true })
  // Copied to a temporary name and renamed, so a half-copied binary is never
  // reachable under the name a node will fetch.
  const tmp = `${dest}.partial`
  await copyFile(source, tmp)
  const hash = await sha256(tmp)
  const { rename, unlink } = await import('node:fs/promises')
  try {
    await db.query(
      `INSERT INTO agent_builds (version, sha256, size_bytes, notes, uploaded_by)
       VALUES ($1,$2,$3,$4,$5)`,
      [version, hash, size, notes, userId],
    )
  } catch (e) {
    await unlink(tmp).catch(() => {})
    throw e
  }
  await rename(tmp, dest)
  return { version, sha256: hash, sizeBytes: size, notes }
}

/** The build a node should be running, or null when nobody has said. */
export async function desiredBuildFor(
  db: Db, poolIds: string[],
): Promise<AgentBuild | null> {
  if (poolIds.length === 0) return null
  const { rows } = await db.query(
    `SELECT b.version, b.sha256, b.size_bytes, b.notes
       FROM pools p JOIN agent_builds b ON b.version = p.desired_agent_version
      -- Only pools that asked to be managed. An external pool records what it
      -- expects and never pushes, which is what makes this safe to run beside
      -- an MDM: two systems racing to own one executable is worse than either
      -- owning it alone.
      -- and standing. A group that has been stood down asserts nothing,
      -- including which build its machines should run.
      WHERE p.id = ANY($1::uuid[]) AND p.agent_channel = 'managed' AND p.enabled
      LIMIT 1`,
    [poolIds],
  )
  const b = rows[0]
  return b
    ? { version: b.version, sha256: b.sha256, sizeBytes: Number(b.size_bytes), notes: b.notes }
    : null
}

export { join }
