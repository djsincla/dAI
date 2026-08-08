import type { Server } from 'node:http'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { Acl, normalizeIp } from '../src/lib/netacl.js'
import { type Fixtures, appFor, freshDb, seed } from './helpers.js'

describe('Acl matching', () => {
  it('is open when unconfigured, since this is defence in depth not auth', () => {
    const acl = new Acl(undefined)
    expect(acl.open).toBe(true)
    expect(acl.allows('203.0.113.9')).toBe(true)
  })

  it('matches IPv4 subnets and rejects everything else', () => {
    const acl = new Acl('10.0.0.0/24, 192.168.4.0/22')
    expect(acl.allows('10.0.0.1')).toBe(true)
    expect(acl.allows('10.0.0.255')).toBe(true)
    expect(acl.allows('10.0.1.1')).toBe(false)
    expect(acl.allows('192.168.4.24')).toBe(true)
    expect(acl.allows('192.168.7.255')).toBe(true)
    expect(acl.allows('192.168.8.1')).toBe(false)
    expect(acl.allows('203.0.113.9')).toBe(false)
  })

  it('accepts bare addresses as well as CIDRs', () => {
    const acl = new Acl('10.0.0.2')
    expect(acl.allows('10.0.0.2')).toBe(true)
    expect(acl.allows('10.0.0.3')).toBe(false)
  })

  it('matches IPv6 and loopback', () => {
    const acl = new Acl('::1, fd00::/8')
    expect(acl.allows('::1')).toBe(true)
    expect(acl.allows('fd12::abcd')).toBe(true)
    expect(acl.allows('2001:db8::1')).toBe(false)
  })

  /**
   * Node reports IPv4 peers over a dual-stack socket as ::ffff:10.0.0.2.
   * Without unwrapping, an IPv4 allowlist silently rejects every real caller,
   * which looks like a working ACL right up until nothing can connect.
   */
  it('unwraps IPv4-mapped IPv6 before matching', () => {
    expect(normalizeIp('::ffff:10.0.0.2')).toBe('10.0.0.2')
    expect(normalizeIp('::FFFF:10.0.0.2')).toBe('10.0.0.2')
    expect(new Acl('10.0.0.0/24').allows('::ffff:10.0.0.2')).toBe(true)
  })

  it('rejects a missing address rather than defaulting open', () => {
    expect(new Acl('10.0.0.0/24').allows(undefined)).toBe(false)
    expect(new Acl('10.0.0.0/24').allows('not-an-ip')).toBe(false)
  })

  it('refuses malformed configuration at construction', () => {
    expect(() => new Acl('10.0.0.0/33')).toThrow()
    expect(() => new Acl('banana')).toThrow()
    expect(() => new Acl('10.0.0.0/abc')).toThrow()
  })
})

describe('surface ACLs over HTTP', () => {
  let db: Db
  let fx: Fixtures
  let server: Server
  let base: string

  beforeEach(async () => {
    db = await freshDb()
    fx = await seed(db)
  })
  afterEach(async () => {
    delete process.env.DAI_AGENT_CIDRS
    delete process.env.DAI_ADMIN_CIDRS
    if (server) await new Promise<void>((r) => server.close(() => r()))
  })
  afterAll(async () => { await db?.end() })

  async function listen(): Promise<void> {
    const app = appFor(db)
    server = await new Promise<Server>((resolve) => {
      const s = app.listen(0, '127.0.0.1', () => resolve(s))
    })
    base = `http://127.0.0.1:${(server.address() as any).port}`
  }

  it('blocks the agent surface from outside the allowed range', async () => {
    process.env.DAI_AGENT_CIDRS = '10.0.0.0/24'
    await listen()
    const r = await fetch(`${base}/agent/v1/policy`, {
      headers: { 'x-node-fingerprint': fx.fingerprint },
    })
    expect(r.status).toBe(403)
  })

  it('allows the agent surface from inside the allowed range', async () => {
    process.env.DAI_AGENT_CIDRS = '127.0.0.0/8'
    await listen()
    const r = await fetch(`${base}/agent/v1/policy`, {
      headers: { 'x-node-fingerprint': fx.fingerprint },
    })
    expect(r.status).toBe(200)
  })

  it('scopes the two surfaces independently', async () => {
    process.env.DAI_AGENT_CIDRS = '127.0.0.0/8'
    process.env.DAI_ADMIN_CIDRS = '10.0.0.0/24'
    await listen()
    expect((await fetch(`${base}/agent/v1/policy`, {
      headers: { 'x-node-fingerprint': fx.fingerprint } })).status).toBe(200)
    expect((await fetch(`${base}/admin/v1/nodes`, {
      headers: { authorization: `Bearer ${fx.operatorId}` } })).status).toBe(403)
  })

  /**
   * The ACL narrows reach; it never grants it. A caller from an allowed network
   * with no credentials must still be refused.
   */
  it('does not substitute for authentication', async () => {
    process.env.DAI_AGENT_CIDRS = '127.0.0.0/8'
    await listen()
    expect((await fetch(`${base}/agent/v1/policy`)).status).toBe(401)
  })

  it('ignores a forged X-Forwarded-For when no proxy is trusted', async () => {
    // Reading the header unconditionally would let any caller declare their own
    // source address, making the allowlist worse than not having one.
    process.env.DAI_AGENT_CIDRS = '10.0.0.0/24'
    await listen()
    const r = await fetch(`${base}/agent/v1/policy`, {
      headers: { 'x-node-fingerprint': fx.fingerprint, 'x-forwarded-for': '10.0.0.5' },
    })
    expect(r.status).toBe(403)
  })
})

describe('per-node network pinning', () => {
  let db: Db
  let fx: Fixtures
  let server: Server
  let base: string

  beforeEach(async () => {
    db = await freshDb()
    fx = await seed(db)
    const app = appFor(db)
    server = await new Promise<Server>((resolve) => {
      const s = app.listen(0, '127.0.0.1', () => resolve(s))
    })
    base = `http://127.0.0.1:${(server.address() as any).port}`
  })
  afterEach(async () => {
    if (server) await new Promise<void>((r) => server.close(() => r()))
  })
  afterAll(async () => { await db?.end() })

  it('allows an unpinned node from anywhere', async () => {
    const r = await fetch(`${base}/agent/v1/policy`, {
      headers: { 'x-node-fingerprint': fx.fingerprint } })
    expect(r.status).toBe(200)
  })

  /**
   * This is the layer that catches a valid certificate presented from the wrong
   * place, which is what a copied credential looks like.
   */
  it('refuses a pinned node connecting from elsewhere', async () => {
    await db.query(`UPDATE nodes SET allowed_cidrs = '10.0.0.0/24' WHERE id = $1`, [fx.nodeId])
    const r = await fetch(`${base}/agent/v1/policy`, {
      headers: { 'x-node-fingerprint': fx.fingerprint } })
    expect(r.status).toBe(403)
  })

  it('records the refusal in the node activity log', async () => {
    await db.query(`UPDATE nodes SET allowed_cidrs = '10.0.0.0/24' WHERE id = $1`, [fx.nodeId])
    await fetch(`${base}/agent/v1/policy`, { headers: { 'x-node-fingerprint': fx.fingerprint } })
    const { rows } = await db.query(
      `SELECT event FROM activity_log WHERE node_id = $1 AND event = 'auth.wrong_network'`,
      [fx.nodeId])
    // Owner-readable, so a user can see an attempt to use their machine's
    // identity from somewhere it has never been.
    expect(rows).toHaveLength(1)
  })

  it('allows a pinned node from its own network', async () => {
    await db.query(`UPDATE nodes SET allowed_cidrs = '127.0.0.0/8' WHERE id = $1`, [fx.nodeId])
    const r = await fetch(`${base}/agent/v1/policy`, {
      headers: { 'x-node-fingerprint': fx.fingerprint } })
    expect(r.status).toBe(200)
  })
})
