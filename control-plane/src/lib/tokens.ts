import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import type { Db } from './db.js'

/**
 * Credentials that are secrets, as distinct from identifiers.
 *
 * The console used to authenticate with a user id used directly as a bearer
 * token. A user id is an identifier: it is returned by the jobs API as
 * `submittedBy`, written to the audit log, stamped on every imported model, and
 * visible in any screenshot of the fleet view. Anyone who read it anywhere had
 * full administrative access, there was no expiry, and the only revocation was
 * deleting the user row, which also orphaned that user's audit history.
 *
 * Two kinds live in one table because the lookup is identical and the policy is
 * not:
 *
 * **session** is what a browser gets for signing in. Short lived, renewed by
 * use, and revoked wholesale when a password changes.
 *
 * **api_key** is what a program gets. Long lived on purpose, because a tool
 * pointed at the serving API cannot be asked to log in, but named and revocable
 * so one can be withdrawn without disturbing anything else.
 *
 * Only a hash of the secret is stored. A copy of this database is then a list of
 * hashes rather than a set of working credentials, which is the same reason the
 * password column is a hash.
 */
export type TokenKind = 'session' | 'api_key'

/** A browser session, long enough for a working day and no longer. */
export const SESSION_TTL_HOURS = 12

export interface IssuedToken {
  /** The secret. Returned exactly once, at creation, and never recoverable. */
  token: string
  expiresAt: Date | null
}

export interface TokenOwner {
  userId: string
  email: string
  username: string | null
  mustChangePassword: boolean
  kind: TokenKind
}

/** 32 bytes of randomness, url-safe, prefixed so it is recognisable in a log. */
function mint(kind: TokenKind): string {
  const prefix = kind === 'session' ? 'dais' : 'daik'
  return `${prefix}_${randomBytes(32).toString('base64url')}`
}

/**
 * SHA-256 rather than a slow KDF, deliberately.
 *
 * A password is low entropy and guessable, so it needs a deliberately expensive
 * hash. A 32 byte random token is not guessable, so the cost buys nothing and
 * would be paid on every single API request.
 */
export function fingerprint(token: string): string {
  return createHash('sha256').update(token).digest('hex')
}

export async function issue(
  db: Db, userId: string, kind: TokenKind, label?: string,
): Promise<IssuedToken> {
  const token = mint(kind)
  const expiresAt = kind === 'session'
    ? new Date(Date.now() + SESSION_TTL_HOURS * 3600 * 1000)
    : null
  await db.query(
    `INSERT INTO auth_tokens (token_hash, user_id, kind, label, expires_at)
     VALUES ($1,$2,$3,$4,$5)`,
    [fingerprint(token), userId, kind, label ?? null, expiresAt],
  )
  return { token, expiresAt }
}

/**
 * Who a token belongs to, or null.
 *
 * Expiry is enforced in the query rather than in TypeScript, so a clock read on
 * the application side cannot disagree with the one the database used when the
 * row was written.
 */
export async function lookup(db: Db, token: string): Promise<TokenOwner | null> {
  const { rows } = await db.query(
    `SELECT t.kind, u.id, u.email, u.username, u.must_change_password
       FROM auth_tokens t JOIN users u ON u.id = t.user_id
      WHERE t.token_hash = $1
        AND (t.expires_at IS NULL OR t.expires_at > now())`,
    [fingerprint(token)],
  )
  const row = rows[0]
  if (!row) return null

  // Best effort, and not awaited into the request path: this is for showing an
  // operator which keys are still in use, and a failed write must not fail an
  // otherwise valid request.
  void db.query(`UPDATE auth_tokens SET last_seen_at = now() WHERE token_hash = $1`,
    [fingerprint(token)]).catch(() => {})

  return {
    userId: row.id as string,
    email: row.email as string,
    username: (row.username as string | null) ?? null,
    mustChangePassword: row.must_change_password as boolean,
    kind: row.kind as TokenKind,
  }
}

export async function revoke(db: Db, token: string): Promise<void> {
  await db.query(`DELETE FROM auth_tokens WHERE token_hash = $1`, [fingerprint(token)])
}

/**
 * Drop every session a user holds, optionally sparing the one in hand.
 *
 * Called when a password changes. A password change that left old sessions
 * working would not actually lock anybody out, which is the main reason people
 * change one.
 *
 * API keys are deliberately left alone: they belong to running tools, and
 * silently breaking a service because somebody rotated their own password would
 * be a surprising consequence.
 */
export async function revokeSessions(
  db: Db, userId: string, exceptToken?: string,
): Promise<number> {
  const { rowCount } = await db.query(
    `DELETE FROM auth_tokens
      WHERE user_id = $1 AND kind = 'session'
        AND ($2::text IS NULL OR token_hash <> $2)`,
    [userId, exceptToken ? fingerprint(exceptToken) : null],
  )
  return rowCount ?? 0
}

/** Expired rows, cleared on a schedule so the table does not grow forever. */
export async function purgeExpired(db: Db): Promise<number> {
  const { rowCount } = await db.query(
    `DELETE FROM auth_tokens WHERE expires_at IS NOT NULL AND expires_at < now()`)
  return rowCount ?? 0
}

/** For the UI: what keys exist, without ever showing the secret. */
export async function listApiKeys(db: Db, userId: string) {
  const { rows } = await db.query(
    `SELECT token_hash, label, created_at, last_seen_at
       FROM auth_tokens WHERE user_id = $1 AND kind = 'api_key'
      ORDER BY created_at DESC`, [userId])
  return rows.map((r) => ({
    // The first characters of the hash, purely so a person can tell two keys
    // apart in a list. It is not the secret and cannot be turned back into it.
    id: (r.token_hash as string).slice(0, 12),
    label: (r.label as string | null) ?? null,
    createdAt: new Date(r.created_at).toISOString(),
    lastSeenAt: r.last_seen_at ? new Date(r.last_seen_at).toISOString() : null,
  }))
}

export async function revokeApiKey(db: Db, userId: string, id: string): Promise<boolean> {
  const { rowCount } = await db.query(
    `DELETE FROM auth_tokens
      WHERE user_id = $1 AND kind = 'api_key' AND left(token_hash, 12) = $2`,
    [userId, id])
  return (rowCount ?? 0) > 0
}

export { timingSafeEqual }
