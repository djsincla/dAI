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
