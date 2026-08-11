import { Router } from 'express'
import type { Db } from '../lib/db.js'
import { userAuth } from '../lib/auth.js'
import {
  checkPassword, DEFAULT_PASSWORD, hashPassword, verifyPassword,
} from '../lib/password.js'
import {
  issue, listApiKeys, lookup, revoke, revokeApiKey, revokeSessions,
} from '../lib/tokens.js'

/**
 * Signing in, signing out, and changing a password.
 *
 * Mounted before the credential check, because a route that requires a
 * credential in order to obtain one is not a login. Everything past `/login`
 * checks for itself.
 */
export function authRoutes(db: Db): Router {
  const r = Router()

  /**
   * Exchange a username and password for a session token.
   *
   * The token is returned once and stored only as a hash, so it cannot be
   * recovered from the database or from this server later.
   */
  r.post('/login', async (req, res) => {
    const { username, password } = req.body as { username?: string; password?: string }
    if (!username || !password) {
      res.status(400).json({ error: 'bad_request', detail: 'username and password are required' })
      return
    }

    const { rows } = await db.query(
      `SELECT id, email, username, password_hash, must_change_password
         FROM users WHERE lower(username) = lower($1)`, [username])
    const user = rows[0]

    // The hash is verified even when no such user exists, against a throwaway
    // value. Returning early would make a missing account measurably faster
    // than a wrong password, which is how a login endpoint hands over a list of
    // valid usernames.
    const stored = (user?.password_hash as string | undefined)
      ?? '$scrypt$131072$8$1$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAA=='
    const ok = await verifyPassword(password, stored)

    if (!user || !ok) {
      res.status(401).json({ error: 'unauthorized', detail: 'wrong username or password' })
      return
    }

    const { token, expiresAt } = await issue(db, user.id as string, 'session')
    res.json({
      token,
      expiresAt: expiresAt?.toISOString() ?? null,
      email: user.email,
      username: user.username,
      // The client uses this to send the person straight to a change form
      // rather than to a console they are not allowed to use yet.
      mustChangePassword: user.must_change_password === true,
    })
  })

  /** Give up this session. Other sessions and API keys are untouched. */
  r.post('/logout', userAuth(db), async (req, res) => {
    if (req.presentedToken) await revoke(db, req.presentedToken)
    res.status(204).end()
  })

  /** Who this credential belongs to, for a page restoring its state. */
  r.get('/me', userAuth(db), async (req, res) => {
    const owner = req.presentedToken ? await lookup(db, req.presentedToken) : null
    res.json({
      email: req.user!.email,
      username: owner?.username ?? null,
      kind: req.authKind ?? 'session',
      mustChangePassword: owner?.mustChangePassword ?? false,
    })
  })

  /**
   * Change a password, which is also how a fresh deployment becomes usable.
   *
   * Reachable while `must_change_password` is set, and the only thing that is.
   */
  r.post('/password', userAuth(db), async (req, res) => {
    const { currentPassword, newPassword } =
      req.body as { currentPassword?: string; newPassword?: string }
    if (!currentPassword || !newPassword) {
      res.status(400).json({
        error: 'bad_request', detail: 'currentPassword and newPassword are required',
      })
      return
    }
    // A program holding a long-lived key is not a person rotating their own
    // password, and letting one do it would mean a leaked key can lock out the
    // human it belongs to.
    if (req.authKind !== 'session') {
      res.status(403).json({
        error: 'forbidden', detail: 'a password can only be changed from a signed-in session',
      })
      return
    }

    const { rows } = await db.query(
      `SELECT username, password_hash FROM users WHERE id = $1`, [req.user!.id])
    const user = rows[0]
    if (!user || !await verifyPassword(currentPassword, user.password_hash as string)) {
      res.status(401).json({ error: 'unauthorized', detail: 'current password is wrong' })
      return
    }

    const rule = checkPassword(newPassword, (user.username as string | null) ?? undefined)
    if (!rule.ok) {
      res.status(400).json({ error: 'bad_request', detail: `password ${rule.reason}` })
      return
    }

    await db.query(
      `UPDATE users
          SET password_hash = $2, must_change_password = false, password_changed_at = now()
        WHERE id = $1`,
      [req.user!.id, await hashPassword(newPassword)])

    // Every other session goes. A password change that left old sessions
    // working would not lock anybody out, which is the main reason people change
    // one. The session doing the changing survives so nobody is signed out of
    // the form they just used.
    const dropped = await revokeSessions(db, req.user!.id, req.presentedToken)
    res.json({ ok: true, otherSessionsEnded: dropped })
  })

  /* ------------------------------------------------------------- API keys */

  r.get('/keys', userAuth(db), async (req, res) => {
    res.json(await listApiKeys(db, req.user!.id))
  })

  /**
   * Mint a key for a program.
   *
   * Long lived on purpose: a tool pointed at the serving API cannot be asked to
   * sign in. Named, so one can be withdrawn without guessing what it was for.
   */
  r.post('/keys', userAuth(db), async (req, res) => {
    const { label } = req.body as { label?: string }
    if (req.authKind !== 'session') {
      res.status(403).json({
        error: 'forbidden', detail: 'API keys can only be created from a signed-in session',
      })
      return
    }
    const { token } = await issue(db, req.user!.id, 'api_key', label)
    // Shown once. There is nowhere to look it up afterwards, because only a
    // hash was kept.
    res.status(201).json({ token, label: label ?? null })
  })

  r.delete('/keys/:id', userAuth(db), async (req, res) => {
    const gone = await revokeApiKey(db, req.user!.id, String(req.params.id))
    if (!gone) {
      res.status(404).json({ error: 'not_found', detail: 'no such key' })
      return
    }
    res.status(204).end()
  })

  return r
}

export { DEFAULT_PASSWORD }
