/**
 * Apply the schema to a database, from a command line.
 *
 * `migrate()` has existed since the beginning and was reachable from exactly
 * one place: the test helper. Every schema change therefore reached a real
 * deployment because somebody ran `psql` by hand and remembered which
 * statements were new. That is not a deployment story, and it is how the live
 * database spent a day disagreeing with the code that talked to it.
 *
 * The installer runs this, and so does an upgrade. There is no migration
 * machinery underneath because `db/schema.sql` is written to be re-runnable:
 * tables are `CREATE TABLE IF NOT EXISTS`, columns are `ADD COLUMN IF NOT
 * EXISTS`, and anything destructive is guarded by a `DO $$ ... $$` block that
 * checks whether it has already happened - the plural-tiers migration is the
 * worked example. Adding a fourth way to describe a schema change would be a
 * fourth thing to keep in step.
 *
 *   DATABASE_URL=postgres://... node dist/migrate.js
 *
 * Creates the database when it does not exist, because an installer that
 * requires somebody to have run `createdb` first has not installed anything.
 */
import pg from 'pg'
import { createPool, migrate } from './lib/db.js'

const url = process.env.DATABASE_URL
if (!url) {
  console.error('DATABASE_URL is not set')
  process.exit(2)
}

/**
 * Make the database if it is absent.
 *
 * Connects to `postgres` on the same server to do it, which is the only
 * database that can be assumed to exist. A duplicate is success rather than
 * failure: two installers racing, or a re-run, should both end with a database
 * present.
 */
async function ensureDatabase(target: string): Promise<void> {
  const name = decodeURIComponent(new URL(target).pathname.replace(/^\//, ''))
  if (!name) throw new Error('DATABASE_URL names no database')

  const maintenance = new URL(target)
  maintenance.pathname = '/postgres'
  const admin = new pg.Client({ connectionString: maintenance.toString() })
  await admin.connect()
  try {
    // Quoted, because a database name arrives from configuration and reaches
    // SQL that cannot be parameterised. Doubling any quote inside it is what
    // makes an identifier safe here.
    await admin.query(`CREATE DATABASE "${name.replace(/"/g, '""')}"`)
    console.log(`created database ${name}`)
  } catch (err) {
    if ((err as { code?: string }).code !== '42P04') throw err  // 42P04: exists
  } finally {
    await admin.end()
  }
}

try {
  await ensureDatabase(url)
} catch (err) {
  // Worth its own message. "Cannot reach Postgres" and "the schema is wrong"
  // send an operator to entirely different places, and an installer that says
  // only "migration failed" sends them to the wrong one first.
  console.error(`cannot reach Postgres at ${new URL(url).host}: ${(err as Error).message}`)
  process.exit(1)
}

const db = createPool(url)
try {
  await migrate(db)
  const { rows } = await db.query(
    `SELECT count(*)::int AS tables FROM information_schema.tables
      WHERE table_schema = 'public'`)
  console.log(`schema applied; ${rows[0].tables} tables`)
} catch (err) {
  console.error(`migration failed: ${(err as Error).message}`)
  process.exit(1)
} finally {
  await db.end()
}
