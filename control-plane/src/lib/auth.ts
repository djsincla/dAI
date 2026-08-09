import type { NextFunction, Request, Response } from 'express'
import type { TLSSocket } from 'node:tls'
import type { Db } from './db.js'

/**
 * Two identity systems that must not be merged. An enrolled Mac is not a user
 * and holds no role; a human holds roles and owns no certificate.
 */

export interface NodeIdentity {
  id: string
  hostname: string
  state: string
  presence_state: string | null
  paused_until: Date | null
  // Carried on the identity because the scheduler checks it on every lease. A
  // machine whose owner has paused it must be refused work on the same request
  // that authenticates it, not on a later lookup somebody can forget to make.
  user_paused: boolean
  owner_user_id: string | null
}

export interface UserIdentity {
  id: string
  email: string
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      node?: NodeIdentity
      user?: UserIdentity
    }
  }
}

/**
 * Whether to trust a fingerprint header instead of a real client certificate.
 * Off unless explicitly enabled, because a deployment that quietly accepts a
 * header as node identity has no authentication at all.
 *
 * Read per call rather than captured at module load: a value frozen at import
 * time cannot be changed by anything that imports this module first, which is
 * exactly what happened to the test suite.
 */
function trustHeaderEnabled(): boolean {
  return process.env.DAI_TRUST_FINGERPRINT_HEADER === '1'
}

function fingerprintOf(req: Request): string | null {
  const socket = req.socket as TLSSocket
  if (typeof socket.getPeerCertificate === 'function') {
    const cert = socket.getPeerCertificate()
    if (cert && cert.fingerprint256) return cert.fingerprint256
  }
  if (trustHeaderEnabled()) {
    const header = req.header('x-node-fingerprint')
    if (header) return header
  }
  return null
}

/** mTLS: the client certificate identifies the node. */
export function agentAuth(db: Db) {
  return async (req: Request, res: Response, next: NextFunction) => {
    const fingerprint = fingerprintOf(req)
    if (!fingerprint) {
      res.status(401).json({ error: 'unauthorized', detail: 'no client certificate' })
      return
    }
    const { rows } = await db.query(
      `SELECT id, hostname, state, presence_state, paused_until, user_paused,
              owner_user_id, revoked_at, cert_not_after
         FROM nodes WHERE cert_fingerprint = $1`,
      [fingerprint],
    )
    const node = rows[0] as (NodeIdentity & {
      revoked_at: Date | null; cert_not_after: Date | null
    }) | undefined
    if (!node) {
      res.status(401).json({ error: 'unauthorized', detail: 'unknown certificate' })
      return
    }
    // Revocation and expiry are checked on every request rather than cached.
    // A stolen laptop must stop being a fleet member the moment it is reported,
    // and a certificate that has aged out must stop working on its own so that
    // renewal is routine rather than something anyone has to remember.
    if (node.revoked_at) {
      res.status(401).json({ error: 'unauthorized', detail: 'certificate revoked' })
      return
    }
    if (node.cert_not_after && node.cert_not_after < new Date()) {
      res.status(401).json({ error: 'unauthorized', detail: 'certificate expired; re-enroll' })
      return
    }
    if (node.state === 'pending') {
      res.status(401).json({ error: 'unauthorized', detail: 'node not approved' })
      return
    }
    req.node = node
    next()
  }
}

/**
 * Session tokens are uuids, and anything else is rejected before it is used as
 * one. Not a security control - an attacker can send a well-formed uuid - but
 * the difference between "your credential is wrong" and "the server fell over",
 * which are different instructions to the client.
 */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** Session auth. A real deployment swaps this for OIDC against the IdP. */
export function userAuth(db: Db) {
  return async (req: Request, res: Response, next: NextFunction) => {
    // x-api-key as well as Bearer, because that is the header every Anthropic
    // client sends and the serving surface exists to be pointed at by tools
    // people already use. Same credential either way.
    const header = req.header('authorization')
    const token = header?.startsWith('Bearer ') ? header.slice(7)
      : req.header('x-api-key') ?? null
    if (!token) {
      res.status(401).json({ error: 'unauthorized', detail: 'no session' })
      return
    }
    // Checked before it reaches the database, because the column is a uuid and
    // Postgres raises on a malformed one. That surfaced as a 500, which tells a
    // client the server is broken and to try again: an invalid credential sent
    // Claude Code into its retry loop instead of failing fast. A bad token is
    // the caller's fault and has to say so.
    if (!UUID.test(token)) {
      res.status(401).json({ error: 'unauthorized', detail: 'malformed session token' })
      return
    }
    const { rows } = await db.query(`SELECT id, email FROM users WHERE id = $1`, [token])
    const user = rows[0] as UserIdentity | undefined
    if (!user) {
      res.status(401).json({ error: 'unauthorized', detail: 'unknown session' })
      return
    }
    req.user = user
    next()
  }
}

export type Role = 'viewer' | 'operator' | 'admin'
const RANK: Record<Role, number> = { viewer: 1, operator: 2, admin: 3 }

/** Highest role this user holds on this pool, through any group. */
export async function roleOnPool(db: Db, userId: string, poolId: string): Promise<Role | null> {
  const { rows } = await db.query(
    `SELECT rb.role
       FROM role_bindings rb
       JOIN group_members gm ON gm.group_id = rb.group_id
      WHERE gm.user_id = $1 AND rb.pool_id = $2`,
    [userId, poolId],
  )
  let best: Role | null = null
  for (const r of rows as { role: Role }[]) {
    if (!best || RANK[r.role] > RANK[best]) best = r.role
  }
  return best
}

export async function requireRole(
  db: Db,
  userId: string,
  poolId: string,
  needed: Role,
): Promise<boolean> {
  const held = await roleOnPool(db, userId, poolId)
  return held !== null && RANK[held] >= RANK[needed]
}

/**
 * The owner of a machine may always pause it, and no role overrides that.
 *
 * This is deliberately not a permission check. An operator who could force work
 * onto someone's Mac makes the agent malware in that person's mental model, and
 * the one-strike social constraint is what the whole policy engine exists to
 * protect.
 */
export async function mayPauseNode(db: Db, userId: string, nodeId: string): Promise<boolean> {
  const { rows } = await db.query(`SELECT owner_user_id FROM nodes WHERE id = $1`, [nodeId])
  const node = rows[0] as { owner_user_id: string | null } | undefined
  if (!node) return false
  if (node.owner_user_id === userId) return true

  const { rows: admin } = await db.query(
    `SELECT 1
       FROM role_bindings rb
       JOIN group_members gm ON gm.group_id = rb.group_id
      WHERE gm.user_id = $1 AND rb.role IN ('operator','admin')
      LIMIT 1`,
    [userId],
  )
  return admin.length > 0
}
