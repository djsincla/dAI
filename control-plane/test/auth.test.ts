import type { Server } from 'node:http'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { appFor, freshDb } from './helpers.js'
import { checkPassword, hashPassword, verifyPassword } from '../src/lib/password.js'
import { fingerprint } from '../src/lib/tokens.js'

/**
 * Signing in, and the default that must not survive first use.
 *
 * The console used to authenticate with a user id used directly as a bearer
 * token. A user id is an identifier: it is returned by the jobs API, written to
 * the audit log, stamped on every imported model, and visible in any screenshot
 * of the fleet view. Anyone who read one anywhere held administrative access
 * that never expired and could only be revoked by deleting the person.
 */
let db: Db
let server: Server
let base: string

beforeEach(async () => {
  db = await freshDb()
  server = await new Promise<Server>((r) => {
    const s = appFor(db).listen(0, () => r(s))
  })
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`
})
afterEach(async () => { await new Promise<void>((r) => server.close(() => r())) })
afterAll(async () => { await db?.end() })

const post = (path: string, body: unknown, token?: string) =>
  fetch(`${base}/admin/v1/auth${path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  })

const login = async (username = 'admin', password = 'admin') =>
  (await post('/login', { username, password })).json()

describe('the password itself', () => {
  it('never stores the password', async () => {
    const hash = await hashPassword('a passphrase nobody guesses')
    expect(hash).not.toContain('a passphrase')
    expect(hash.startsWith('scrypt$')).toBe(true)
  })

  it('verifies the right one and refuses the rest', async () => {
    const hash = await hashPassword('correct horse battery')
    expect(await verifyPassword('correct horse battery', hash)).toBe(true)
    expect(await verifyPassword('correct horse batteru', hash)).toBe(false)
    expect(await verifyPassword('', hash)).toBe(false)
  })

  it('salts, so two identical passwords do not share a hash', async () => {
    // Without this, a leaked database shows which accounts share a password
    // and turns one cracked hash into several compromised accounts.
    const [a, b] = await Promise.all([hashPassword('same'), hashPassword('same')])
    expect(a).not.toBe(b)
  })

  it('fails a corrupt stored value rather than throwing', async () => {
    // A damaged row should fail the sign-in, not return a 500 that tells a
    // caller the server is broken and to retry.
    expect(await verifyPassword('x', 'nonsense')).toBe(false)
    expect(await verifyPassword('x', 'scrypt$1$2$3$notbase64$')).toBe(false)
  })

  it('refuses the shipped default as a new password', () => {
    // The whole reason this change exists is a deployment still on admin.
    expect(checkPassword('admin').ok).toBe(false)
    expect(checkPassword('ADMIN').ok).toBe(false)
  })

  it('requires enough length, and says why', () => {
    expect(checkPassword('short').ok).toBe(false)
    expect(checkPassword('short').reason).toMatch(/at least/)
    expect(checkPassword('a long enough passphrase').ok).toBe(true)
  })

  it('refuses a password that is just the username', () => {
    expect(checkPassword('dwayne-admin', 'dwayne-admin').ok).toBe(false)
  })
})

describe('a fresh deployment', () => {
  it('starts with admin and admin', async () => {
    const body = await login()
    expect(body.token).toBeTruthy()
    expect(body.mustChangePassword).toBe(true)
  })

  it('lets that account do nothing else until the password changes', async () => {
    // The point of seeding a known default: it has to be a doorway, not a
    // working console with a reminder attached.
    const { token } = await login()
    const nodes = await fetch(`${base}/admin/v1/nodes`,
      { headers: { authorization: `Bearer ${token}` } })
    expect(nodes.status).toBe(403)
    expect((await nodes.json()).error).toBe('password_change_required')
  })

  it('opens the console once the password is changed', async () => {
    const { token } = await login()
    const changed = await post('/password',
      { currentPassword: 'admin', newPassword: 'a much better passphrase' }, token)
    expect(changed.status).toBe(200)

    const nodes = await fetch(`${base}/admin/v1/nodes`,
      { headers: { authorization: `Bearer ${token}` } })
    expect(nodes.status).toBe(200)
  })

  it('refuses to change the password to the default', async () => {
    const { token } = await login()
    const r = await post('/password',
      { currentPassword: 'admin', newPassword: 'admin' }, token)
    expect(r.status).toBe(400)
  })

  it('will not seed a second time on an established fleet', async () => {
    // Otherwise every migration re-opens a known-password account.
    const { ensureBootstrapAdmin } = await import('../src/lib/db.js')
    const { token } = await login()
    await post('/password',
      { currentPassword: 'admin', newPassword: 'a much better passphrase' }, token)

    await ensureBootstrapAdmin(db)
    const again = await post('/login', { username: 'admin', password: 'admin' })
    expect(again.status).toBe(401)
  })
})

describe('sessions', () => {
  const ready = async () => {
    const { token } = await login()
    await post('/password',
      { currentPassword: 'admin', newPassword: 'a much better passphrase' }, token)
    return token as string
  }

  it('refuses a user id used as a token, which used to be the whole scheme', async () => {
    const token = await ready()
    const { rows } = await db.query(`SELECT id FROM users LIMIT 1`)
    const r = await fetch(`${base}/admin/v1/nodes`,
      { headers: { authorization: `Bearer ${rows[0].id}` } })
    expect(r.status).toBe(401)
  })

  it('stores only a hash, so the database is not a set of live credentials', async () => {
    const token = await ready()
    const { rows } = await db.query(`SELECT token_hash FROM auth_tokens`)
    expect(rows.some((r) => r.token_hash === token)).toBe(false)
    expect(rows.some((r) => r.token_hash === fingerprint(token))).toBe(true)
  })

  it('ends other sessions when the password changes, and keeps this one', async () => {
    // A password change that left old sessions working would not lock anybody
    // out, which is the main reason people change one.
    const first = await ready()
    const second = (await login('admin', 'a much better passphrase')).token

    const r = await post('/password',
      { currentPassword: 'a much better passphrase', newPassword: 'another good passphrase' },
      second)
    expect(r.status).toBe(200)

    expect((await fetch(`${base}/admin/v1/nodes`,
      { headers: { authorization: `Bearer ${first}` } })).status).toBe(401)
    expect((await fetch(`${base}/admin/v1/nodes`,
      { headers: { authorization: `Bearer ${second}` } })).status).toBe(200)
  })

  it('stops working after logout', async () => {
    const token = await ready()
    expect((await post('/logout', {}, token)).status).toBe(204)
    expect((await fetch(`${base}/admin/v1/nodes`,
      { headers: { authorization: `Bearer ${token}` } })).status).toBe(401)
  })

  it('refuses an expired session', async () => {
    const token = await ready()
    await db.query(`UPDATE auth_tokens SET expires_at = now() - interval '1 hour'`)
    expect((await fetch(`${base}/admin/v1/nodes`,
      { headers: { authorization: `Bearer ${token}` } })).status).toBe(401)
  })

  it('gives the same answer for a wrong password and a missing account', async () => {
    // Different answers would let somebody enumerate which usernames exist.
    const missing = await post('/login', { username: 'nobody', password: 'whatever' })
    const wrong = await post('/login', { username: 'admin', password: 'whatever' })
    expect(missing.status).toBe(wrong.status)
    expect(await missing.json()).toEqual(await wrong.json())
  })
})

describe('API keys', () => {
  const ready = async () => {
    const { token } = await login()
    await post('/password',
      { currentPassword: 'admin', newPassword: 'a much better passphrase' }, token)
    return token as string
  }

  it('are shown once and never again', async () => {
    const session = await ready()
    const created = await (await post('/keys', { label: 'claude-local' }, session)).json()
    expect(created.token).toMatch(/^daik_/)

    const listed = await (await fetch(`${base}/admin/v1/auth/keys`,
      { headers: { authorization: `Bearer ${session}` } })).json()
    expect(listed).toHaveLength(1)
    expect(JSON.stringify(listed)).not.toContain(created.token)
  })

  it('work as a credential for the serving surface', async () => {
    // The reason keys exist at all: a tool pointed at the API cannot sign in.
    const session = await ready()
    const { token: key } = await (await post('/keys', { label: 'tool' }, session)).json()
    const r = await fetch(`${base}/v1/models`, { headers: { 'x-api-key': key } })
    expect(r.status).toBe(200)
  })

  it('cannot change a password, so a leaked key cannot lock out its owner', async () => {
    const session = await ready()
    const { token: key } = await (await post('/keys', { label: 'tool' }, session)).json()
    const r = await post('/password',
      { currentPassword: 'a much better passphrase', newPassword: 'yet another passphrase' }, key)
    expect(r.status).toBe(403)
  })

  it('survive a password change, because a service should not break', async () => {
    const session = await ready()
    const { token: key } = await (await post('/keys', { label: 'tool' }, session)).json()
    await post('/password',
      { currentPassword: 'a much better passphrase', newPassword: 'yet another passphrase' },
      session)
    expect((await fetch(`${base}/v1/models`, { headers: { 'x-api-key': key } })).status).toBe(200)
  })

  it('can be revoked individually', async () => {
    const session = await ready()
    const { token: key } = await (await post('/keys', { label: 'tool' }, session)).json()
    const [listed] = await (await fetch(`${base}/admin/v1/auth/keys`,
      { headers: { authorization: `Bearer ${session}` } })).json()

    const gone = await fetch(`${base}/admin/v1/auth/keys/${listed.id}`,
      { method: 'DELETE', headers: { authorization: `Bearer ${session}` } })
    expect(gone.status).toBe(204)
    expect((await fetch(`${base}/v1/models`, { headers: { 'x-api-key': key } })).status).toBe(401)
  })
})
