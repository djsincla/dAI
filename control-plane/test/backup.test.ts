import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { createPool, type Db } from '../src/lib/db.js'

/**
 * Backup and restore, exercised as a round trip.
 *
 * A backup nobody has restored is a hope. The only way to know the archive is
 * good is to destroy something and bring it back, so this creates a scratch
 * database, fills it, backs it up, drops the contents and restores.
 *
 * What it protects is disproportionate to its size: the CA private key is
 * 1.7KB, every node certificate traces to it, and enrolment needs the Secure
 * Enclave, which will not generate a key over ssh. Losing it means walking to
 * every machine in the building.
 */
const SCRATCH = 'postgres://dai:dai@localhost:5433/dai_backup_test'
let db: Db
let dir: string

/**
 * Reached over TCP rather than through a container.
 *
 * This shelled out to `docker exec control-plane-postgres-1` and so described
 * one way of running Postgres rather than the one the fleet uses. When the
 * control plane moved to a native server under launchd the container stopped,
 * and this file failed with "container is not running" - a suite that was
 * testing the deployment instead of the backup.
 *
 * The URL is the same one the rest of the file already used for its own
 * connection, so a server anywhere works: container, native, or another host.
 */
const psql = (sql: string, database = 'dai_backup_test') =>
  execFileSync('psql', [
    `postgres://dai:dai@localhost:5433/${database}`,
    '-q', '-t', '-A', '-c', sql,
  ], { encoding: 'utf8' }).trim()

beforeAll(async () => {
  try { psql('DROP DATABASE IF EXISTS dai_backup_test', 'postgres') } catch { /* fresh */ }
  psql('CREATE DATABASE dai_backup_test', 'postgres')
  db = createPool(SCRATCH)
  const { migrate } = await import('../src/lib/db.js')
  await migrate(db)

  await db.query(
    `INSERT INTO nodes (hostname, chip, memory_gb, state, cert_fingerprint, cert_pem)
     VALUES ('rotorua','Apple M2 Max',64,'active','fp-1','---cert---'),
            ('orca','Apple M4 Pro',48,'active','fp-2','---cert---')`)
  await db.query(
    `INSERT INTO pools (name, tier, schedule, preempt)
     VALUES ('overnight-harvest','harvest','independent-units','on-user-activity')`)
  await db.query(
    `INSERT INTO models (id, runtime, kind, size_bytes)
     VALUES ('mlx-community/Qwen2.5-Coder-32B-Instruct-4bit','mlx','generate',18441439373)`)
  dir = mkdtempSync(join(tmpdir(), 'dai-backup-'))
})

afterAll(async () => {
  await db?.end()
  rmSync(dir, { recursive: true, force: true })
  try { psql('DROP DATABASE IF EXISTS dai_backup_test', 'postgres') } catch { /* gone */ }
})

describe('a backup of a fleet', () => {
  let archive: string

  it('captures the database, the CA and the configuration', () => {
    execFileSync('bash', [join(process.cwd(), 'scripts', 'backup.sh'), dir], {
      env: { ...process.env, DATABASE_URL: SCRATCH },
      encoding: 'utf8',
    })
    const found = readdirSync(dir).filter((f) => f.endsWith('.tar.gz'))
    expect(found).toHaveLength(1)
    archive = join(dir, found[0]!)

    const listing = execFileSync('tar', ['-tzf', archive], { encoding: 'utf8' })
    expect(listing).toContain('dai.sql')
    // The whole reason this script exists.
    expect(listing).toContain('certs/ca.key')
    expect(listing).toContain('config.env')
    expect(listing).toContain('manifest.txt')
  })

  it('does not carry model weights', () => {
    // They are the one thing that can be fetched again, and the catalogue
    // records a hash per file so a re-import is verifiable rather than trusted.
    // An archive that swept them in would be unusably large and nobody would
    // take it.
    const listing = execFileSync('tar', ['-tzf', archive], { encoding: 'utf8' })
    expect(listing).not.toMatch(/safetensors/)
    expect(execFileSync('stat', ['-f', '%z', archive], { encoding: 'utf8' }).trim())
      .toSatisfy((s: string) => Number(s) < 50_000_000)
  })

  it('brings a wiped fleet back, and checks it against the manifest', () => {
    // The destructive half. Everything goes, then comes back.
    psql('DROP SCHEMA public CASCADE; CREATE SCHEMA public;')
    expect(() => psql('SELECT count(*) FROM nodes')).toThrow()

    const out = execFileSync('bash', [
      join(process.cwd(), 'scripts', 'restore.sh'), archive, '--yes',
    ], { env: { ...process.env, DATABASE_URL: SCRATCH }, encoding: 'utf8' })

    expect(psql('SELECT count(*) FROM nodes')).toBe('2')
    expect(psql("SELECT hostname FROM nodes ORDER BY hostname")).toContain('orca')
    // Certificates survive, which is the difference between a fleet that keeps
    // working and one that re-enrols by hand at every machine.
    expect(psql("SELECT cert_pem FROM nodes WHERE hostname='rotorua'")).toBe('---cert---')
    expect(psql('SELECT count(*) FROM models')).toBe('1')
    expect(out).not.toMatch(/MISMATCH/)
  })

  it('keeps the CA it replaced rather than overwriting it', () => {
    // If this turns out to be the wrong archive, the fleet that was working
    // five minutes ago has to still be recoverable.
    const superseded = readdirSync(join(process.cwd(), 'certs'))
      .filter((f) => f.startsWith('superseded-'))
    expect(superseded.length).toBeGreaterThan(0)
    expect(existsSync(join(process.cwd(), 'certs', superseded[0]!, 'ca.key'))).toBe(true)
  })
})

