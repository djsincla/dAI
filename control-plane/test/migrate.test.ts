import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { migrate, type Db } from '../src/lib/db.js'
import { freshDb } from './helpers.js'

/**
 * Applying the schema to a database that already has one.
 *
 * This is the only path a deployment has to an upgrade: the installer runs the
 * whole of `db/schema.sql`, so any statement that errors on a second run leaves
 * a half-migrated database and an installer reporting failure.
 *
 * It did error. Eleven tables and five indexes were created without IF NOT
 * EXISTS, so `migrate` worked on a fresh database and failed against every
 * database it would ever be run against in anger. Nothing caught it because the
 * suite only ever migrates into an empty schema - which is exactly the one case
 * that was already working.
 */
describe('applying the schema twice', () => {
  let db: Db

  beforeEach(async () => { db = await freshDb() })
  afterEach(async () => { await db?.end() })

  it('is a no-op the second time', async () => {
    await expect(migrate(db)).resolves.toBeUndefined()
    await expect(migrate(db)).resolves.toBeUndefined()
  })

  it('leaves the data alone', async () => {
    // The case that matters. An upgrade runs against a fleet that exists, and a
    // schema file that dropped or recreated anything would take it with it.
    await db.query(
      `INSERT INTO nodes (hostname, cert_fingerprint, tiers)
       VALUES ('survivor', 'fp-survivor', ARRAY['harvest','cluster'])`)
    await migrate(db)

    const { rows } = await db.query(
      `SELECT hostname, tiers, tier FROM nodes WHERE hostname='survivor'`)
    expect(rows).toHaveLength(1)
    expect(rows[0].tiers).toEqual(['harvest', 'cluster'])
    expect(rows[0].tier).toBe('cluster')
  })

  it('does not add a second copy of a guarded constraint', async () => {
    // Constraints have no IF NOT EXISTS, so this one is asked for rather than
    // assumed. It is the canary for the whole class: anything else added
    // without a guard fails the test above instead.
    await migrate(db)
    const { rows } = await db.query(
      `SELECT count(*)::int AS n FROM pg_constraint
        WHERE conname = 'pools_agent_channel_check'`)
    expect(rows[0].n).toBe(1)
  })

  it('keeps the bootstrap admin it already has', async () => {
    // Re-applying the schema must not resurrect admin/admin on a fleet whose
    // password was changed. `ensureBootstrapAdmin` returns early once any
    // account has a password, and this is the test that says so from the
    // upgrade's point of view rather than the seeding function's.
    const { rows: before } = await db.query(
      `UPDATE users SET password_hash = 'already-set', must_change_password = false
        WHERE username = 'admin' RETURNING id`)
    expect(before).toHaveLength(1)

    await migrate(db)

    const { rows } = await db.query(
      `SELECT password_hash, must_change_password FROM users WHERE username='admin'`)
    expect(rows[0].password_hash).toBe('already-set')
    expect(rows[0].must_change_password).toBe(false)
  })
})
