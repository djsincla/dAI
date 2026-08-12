import type { NextFunction, Request, Response } from 'express'
import type { TLSSocket } from 'node:tls'
import type { Db } from './db.js'
import { lookup } from './tokens.js'

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
  // Pool membership is decided from these on every lease, for the same reason:
  // a node must be matched to pools by what it is, on the request that proves
  // who it is, rather than by a lookup somewhere else that can go stale.
  tier: string
  chip: string | null
  memory_gb: string | number | null
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
      /// Whether this request arrived on a browser session or a program's API
      /// key. Sign-in routes refuse an API key: rotating a password from a
      /// long-lived key held by a service is not a thing a person is doing.
      authKind?: 'session' | 'api_key'
      /// The credential as presented, so a password change can spare the
      /// session doing the changing while revoking the rest.
      presentedToken?: string
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

/**
 * Which node states may use the agent surface, and why each one may or may not.
 *
 * An allowlist rather than a list of rejections, because the rejection list is
 * the thing that quietly goes stale. This started as a single check for
 * `pending` and then `superseded` was added to the schema for re-enrolment - a
 * state nobody thought about here, so a retired identity kept authenticating.
 * On this fleet that ran for two days: a machine re-enrolled, its old daemon
 * kept the old certificate, and the control plane accepted every heartbeat
 * while the console displayed the newer row, which was dead. The fleet said
 * ABSENT about a machine somebody was sitting at, which is the one thing this
 * system may not get wrong.
 *
 * With a map, adding a state to the schema and not to this table fails closed
 * and says so, instead of silently granting access.
 */
const AGENT_ACCESS: Record<string, { allowed: boolean; detail: string }> = {
  // Working normally.
  active: { allowed: true, detail: '' },

  // Administratively paused, and it must keep talking. A paused node still
  // heartbeats, still reports presence, and is resumed by an admin acting on
  // the record those heartbeats maintain. Refusing it here would make pausing
  // a one way door.
  paused: { allowed: true, detail: '' },

  // Marked offline for missing heartbeats. Coming back is the entire point.
  offline: { allowed: true, detail: '' },

  // Enrolled, not approved. It has a queue position and nothing else.
  pending: { allowed: false, detail: 'node not approved' },

  // Cordoned, which is set with revoked_at when an identity is withdrawn. The
  // revocation check above catches it first; this is here so the two cannot
  // drift apart.
  cordoned: { allowed: false, detail: 'node cordoned' },

  // Replaced by a later enrolment of the same hardware. The certificate is
  // genuine and was really issued, which is exactly why this needs saying: it
  // verifies, so nothing else would stop it.
  superseded: {
    allowed: false,
    detail: 'this identity is superseded: the machine re-enrolled and this record was replaced; re-enroll',
  },
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
              owner_user_id, revoked_at, cert_not_after,
              tier, chip, memory_gb
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
    const access = AGENT_ACCESS[node.state]
    if (!access || !access.allowed) {
      res.status(401).json({
        error: 'unauthorized',
        // An unlisted state is a schema change nobody brought here. Refusing it
        // is right, and naming it is what turns a mystery 401 into a one line
        // fix in this file.
        detail: access?.detail ?? `node state '${node.state}' may not use the agent API`,
      })
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
/**
 * Who is calling, from a credential that is actually a secret.
 *
 * This used to accept a user id as a bearer token. A user id is an identifier:
 * it comes back from the jobs API, sits in the audit log, and appears in any
 * screenshot of the console, so anyone who read one anywhere held administrative
 * access that could not expire and could not be revoked without deleting the
 * person.
 *
 * Now it accepts a session token from signing in, or a named API key. Both are
 * random, stored only as hashes, and individually revocable.
 */
export function userAuth(db: Db) {
  return async (req: Request, res: Response, next: NextFunction) => {
    // x-api-key as well as Bearer, because that is the header every Anthropic
    // client sends and the serving surface exists to be pointed at by tools
    // people already use.
    const header = req.header('authorization')
    const token = header?.startsWith('Bearer ') ? header.slice(7)
      : req.header('x-api-key') ?? null
    if (!token) {
      res.status(401).json({ error: 'unauthorized', detail: 'no credential' })
      return
    }

    const owner = await lookup(db, token)
    if (!owner) {
      // One message for absent, expired and wrong. Distinguishing them tells
      // somebody probing which of their guesses was closest.
      res.status(401).json({ error: 'unauthorized', detail: 'invalid or expired credential' })
      return
    }

    // A deployment still on the shipped default can do exactly one thing. This
    // is the whole point of seeding admin/admin: the first person in has to
    // replace it before the fleet is reachable, rather than being reminded and
    // carrying on.
    if (owner.mustChangePassword && !isPasswordChange(req)) {
      res.status(403).json({
        error: 'password_change_required',
        detail: 'the default password must be changed before anything else',
      })
      return
    }

    req.user = { id: owner.userId, email: owner.email }
    req.authKind = owner.kind
    req.presentedToken = token
    next()
  }
}

/**
 * The one route a must-change-password credential may still reach.
 *
 * Matched on the full URL rather than `req.path`, which inside a mounted router
 * is only the part after the mount point: the check silently never matched and
 * locked the default account out of the very form it has to use.
 */
function isPasswordChange(req: Request): boolean {
  return req.method === 'POST'
    && req.originalUrl.split('?')[0]!.endsWith('/admin/v1/auth/password')
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
