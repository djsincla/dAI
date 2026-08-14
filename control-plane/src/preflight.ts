/**
 * The installer's question, answered with the database in hand.
 *
 *     node dist/preflight.js --ca /var/db/dai-control/node-ca/ca.crt
 *
 * Prints what should happen and exits 0 to proceed, 3 to stop. Separate from the
 * installer because the shell cannot ask Postgres anything without dragging in a
 * client that may not be installed, and because the decision itself is worth
 * testing rather than trusting.
 *
 * A database that has never been migrated has no nodes table, which is not an
 * error: it is a first install, and the answer is "generate".
 */

import { existsSync } from 'node:fs'
import { createPool } from './lib/db.js'
import { certDecision } from './lib/preflight.js'

const args = process.argv.slice(2)
const valueOf = (flag: string) => {
  const i = args.indexOf(flag)
  return i >= 0 ? args[i + 1] : undefined
}

const caPath = valueOf('--ca')
const stateDir = valueOf('--state-dir')
const url = process.env.DATABASE_URL

if (!caPath) {
  console.error('usage: preflight --ca <path to ca.crt> [--state-dir <dir>]')
  process.exit(2)
}

async function enrolledNodes(): Promise<number> {
  if (!url) return 0
  const db = createPool(url)
  try {
    const { rows } = await db.query(
      `SELECT count(*)::int AS n FROM nodes WHERE state <> 'superseded'`)
    return Number((rows[0] as { n: number } | undefined)?.n ?? 0)
  } catch {
    // No table, no database, no connection. All of them mean the same thing for
    // this question: there is no fleet here to lock out. A database that cannot
    // be reached at all is reported by the migration step a moment later, which
    // is a better place to say it.
    return 0
  } finally {
    await db.end().catch(() => {})
  }
}

const decision = certDecision({
  caPresent: existsSync(caPath),
  enrolledNodes: await enrolledNodes(),
  stateDir,
})

console.log(decision.detail)
process.exit(decision.action === 'refuse' ? 3 : 0)
