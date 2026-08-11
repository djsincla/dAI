import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import pg from 'pg'

const here = dirname(fileURLToPath(import.meta.url))
export const SCHEMA_PATH = join(here, '..', '..', 'db', 'schema.sql')

export type Db = pg.Pool

export function createPool(url = process.env.DATABASE_URL): Db {
  if (!url) throw new Error('DATABASE_URL is not set')
  return new pg.Pool({ connectionString: url, max: 10 })
}

/** Apply the schema. Idempotent enough for dev and for per-test databases. */
export async function migrate(db: Db): Promise<void> {
  await db.query(readFileSync(SCHEMA_PATH, 'utf8'))
  await ensureBootstrapAdmin(db)
}

/**
 * The account a fresh deployment starts with: admin / admin, which must be
 * changed before anything else can be done.
 *
 * Created only when there is no account with a password, so this never
 * resurrects itself on an established fleet and never disturbs existing users.
 *
 * Roles here are per pool and granted through a group, so an administrator is
 * not a flag on a user: this puts the account in an `administrators` group and
 * binds that group as admin on every pool. New pools already bind their
 * creator's group when they are made, so the two paths agree.
 */
export async function ensureBootstrapAdmin(db: Db): Promise<void> {
  const { rows: existing } = await db.query(
    `SELECT 1 FROM users WHERE password_hash IS NOT NULL LIMIT 1`)
  if (existing.length > 0) return

  const { hashPassword, DEFAULT_PASSWORD, DEFAULT_USERNAME } = await import('./password.js')
  const hash = await hashPassword(DEFAULT_PASSWORD)

  // ON CONFLICT so a deployment that already had a passwordless user with this
  // address gains a password rather than failing the migration outright.
  const { rows } = await db.query(
    `INSERT INTO users (email, username, password_hash, must_change_password)
     VALUES ($1, $2, $3, true)
     ON CONFLICT (email) DO UPDATE
       SET username = EXCLUDED.username,
           password_hash = EXCLUDED.password_hash,
           must_change_password = true
     RETURNING id`,
    ['admin@localhost', DEFAULT_USERNAME, hash],
  )
  const userId = rows[0]!.id as string

  const { rows: group } = await db.query(
    `INSERT INTO groups (name) VALUES ('administrators')
     ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
     RETURNING id`)
  const groupId = group[0]!.id as string

  await db.query(
    `INSERT INTO group_members (group_id, user_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
    [groupId, userId])
  await db.query(
    `INSERT INTO role_bindings (group_id, pool_id, role)
     SELECT $1, p.id, 'admin' FROM pools p
     ON CONFLICT (group_id, pool_id) DO NOTHING`,
    [groupId])
}

export async function reset(db: Db): Promise<void> {
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;')
  await migrate(db)
}

/**
 * Run fn inside a transaction.
 *
 * Dispatch and result reporting both read-then-write rows that another node may
 * be racing for, so they need real transactions rather than sequential queries.
 */
export async function tx<T>(db: Db, fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await db.connect()
  try {
    await client.query('BEGIN')
    const out = await fn(client)
    await client.query('COMMIT')
    return out
  } catch (err) {
    await client.query('ROLLBACK')
    throw err
  } finally {
    client.release()
  }
}
