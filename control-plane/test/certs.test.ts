import { execSync } from 'node:child_process'
import type { Server } from 'node:http'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { Ca, fingerprintOfPem, loadOrCreateCa } from '../src/lib/ca.js'
import { type Fixtures, appFor, freshDb, seed } from './helpers.js'

/**
 * `algorithm` exists because the Secure Enclave only generates P-256, so EC is
 * the algorithm the agent actually uses. RSA stays covered because certificates
 * already issued against RSA keys have to keep working.
 */
function makeCsr(cn = 'whatever-the-node-asked-for',
                 algorithm: 'rsa' | 'ec' = 'rsa'): { csr: string; dir: string } {
  const dir = mkdtempSync(join(tmpdir(), 'dai-csr-'))
  const keyspec = algorithm === 'ec'
    ? '-newkey ec -pkeyopt ec_paramgen_curve:prime256v1'
    : '-newkey rsa:2048'
  execSync(`openssl req ${keyspec} -nodes -keyout ${dir}/k.pem ` +
           `-out ${dir}/r.csr -subj "/CN=${cn}" 2>/dev/null`)
  return { csr: readFileSync(`${dir}/r.csr`, 'utf8'), dir }
}

describe('certificate authority', () => {
  let caDir: string
  let ca: Ca

  beforeEach(async () => {
    caDir = mkdtempSync(join(tmpdir(), 'dai-ca-'))
    ca = new Ca(await loadOrCreateCa(join(caDir, 'ca.crt'), join(caDir, 'ca.key')))
  })
  afterEach(() => rmSync(caDir, { recursive: true, force: true }))

  it('produces a fingerprint in the exact form Node TLS reports', async () => {
    // If these differ, every mTLS lookup silently misses and the failure looks
    // like "unknown certificate" rather than a formatting bug.
    const { csr, dir } = makeCsr()
    const signed = await ca.sign(csr, 'node-1', 'orca')
    const viaOpenssl = execSync(
      `echo '${signed.certPem}' | openssl x509 -noout -fingerprint -sha256`,
    ).toString().split('=')[1]!.trim()
    expect(signed.fingerprint).toBe(viaOpenssl)
    expect(fingerprintOfPem(signed.certPem)).toBe(viaOpenssl)
    rmSync(dir, { recursive: true, force: true })
  })

  it('names the certificate after the node record, not the CSR', async () => {
    // A node does not choose the name it is known by. Otherwise a machine could
    // request an identity belonging to another node record.
    const { csr, dir } = makeCsr('i-am-the-admin-box')
    const signed = await ca.sign(csr, 'node-42', 'orca')
    const subject = execSync(`echo '${signed.certPem}' | openssl x509 -noout -subject`).toString()
    expect(subject).toContain('CN=node-42')
    expect(subject).not.toContain('i-am-the-admin-box')
    rmSync(dir, { recursive: true, force: true })
  })

  it('issues client-auth-only certificates', async () => {
    // A node certificate must not be usable to impersonate the control plane to
    // another node.
    const { csr, dir } = makeCsr()
    const signed = await ca.sign(csr, 'node-1', 'orca')
    const text = execSync(`echo '${signed.certPem}' | openssl x509 -noout -text`).toString()
    expect(text).toContain('TLS Web Client Authentication')
    expect(text).not.toContain('TLS Web Server Authentication')
    expect(text).toContain('CA:FALSE')
    rmSync(dir, { recursive: true, force: true })
  })

  it('issues short-lived certificates', async () => {
    // These live on laptops that leave the building, so a stolen machine should
    // stop being a fleet member on its own.
    const { csr, dir } = makeCsr()
    const signed = await ca.sign(csr, 'node-1', 'orca')
    const days = (signed.notAfter.getTime() - Date.now()) / 86_400_000
    expect(days).toBeGreaterThan(1)
    expect(days).toBeLessThanOrEqual(31)
    rmSync(dir, { recursive: true, force: true })
  })

  it('refuses anything that is not a valid CSR', async () => {
    await expect(ca.sign('not a csr', 'n', 'h')).rejects.toThrow()
    await expect(ca.sign('', 'n', 'h')).rejects.toThrow()
  })

  it('signs the elliptic-curve CSR the Secure Enclave produces', async () => {
    // The reason this CA moved off node-forge. A P-256 key is the only kind the
    // Enclave will generate, and forge cannot sign one at all.
    const { csr, dir } = makeCsr('enclave-node', 'ec')
    const signed = await ca.sign(csr, 'node-se', 'orca')
    const text = execSync(`echo '${signed.certPem}' | openssl x509 -noout -text`).toString()
    expect(text).toContain('id-ecPublicKey')
    expect(text).toContain('prime256v1')
    expect(text).toContain('CN=node-se')
    // keyEncipherment describes RSA key transport; claiming it for a key that
    // can only sign is a promise the key cannot keep.
    expect(text).not.toContain('Key Encipherment')
    rmSync(dir, { recursive: true, force: true })
  })

  it('rejects a CSR whose signature does not match its own key', async () => {
    // Signing this would bind an identity to a key the requester does not hold.
    const { csr, dir } = makeCsr('tampered', 'ec')
    const lines = csr.trim().split('\n')
    const body = lines.slice(1, -1).join('')
    const bytes = Buffer.from(body, 'base64')
    bytes[bytes.length - 1] = bytes[bytes.length - 1]! ^ 0xff  // corrupt the signature
    const tampered = `-----BEGIN CERTIFICATE REQUEST-----\n${
      bytes.toString('base64').replace(/(.{64})/g, '$1\n')}\n-----END CERTIFICATE REQUEST-----\n`
    await expect(ca.sign(tampered, 'node-1', 'orca')).rejects.toThrow()
    rmSync(dir, { recursive: true, force: true })
  })

  it('keeps issuing under an RSA CA created before the move off node-forge', async () => {
    // The fleet's existing CA is RSA. Rotating it would invalidate every
    // certificate under it and mean re-approving every node by hand, so an RSA
    // CA has to keep signing - including EC CSRs, which is the combination that
    // did not exist before.
    const dir = mkdtempSync(join(tmpdir(), 'dai-rsa-ca-'))
    execSync(`openssl req -x509 -newkey rsa:2048 -nodes -keyout ${dir}/ca.key ` +
             `-out ${dir}/ca.crt -days 365 -subj "/CN=legacy dAI node CA" ` +
             `-addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null`)
    const legacy = new Ca({
      certPem: readFileSync(`${dir}/ca.crt`, 'utf8'),
      keyPem: readFileSync(`${dir}/ca.key`, 'utf8'),
    })

    const { csr, dir: csrDir } = makeCsr('enclave-node', 'ec')
    const signed = await legacy.sign(csr, 'node-se', 'orca')
    const text = execSync(`echo '${signed.certPem}' | openssl x509 -noout -text`).toString()
    expect(text).toContain('prime256v1')                    // EC leaf
    expect(text).toContain('sha256WithRSAEncryption')       // RSA issuer signature

    // Chain verification is the claim that matters: a leaf that parses but does
    // not verify against its issuer would fail at TLS handshake time instead.
    writeFileSync(`${dir}/leaf.crt`, signed.certPem)
    const verify = execSync(
      `openssl verify -CAfile ${dir}/ca.crt -purpose sslclient ${dir}/leaf.crt`).toString()
    expect(verify).toContain('OK')

    rmSync(dir, { recursive: true, force: true })
    rmSync(csrDir, { recursive: true, force: true })
  })

  it('never writes the CA key world-readable', () => {
    const mode = execSync(`stat -f '%Lp' ${join(caDir, 'ca.key')}`).toString().trim()
    expect(mode).toBe('600')
  })
})

describe('enrollment and issuance over HTTP', () => {
  let db: Db
  let fx: Fixtures
  let server: Server
  let base: string
  let caDir: string

  beforeEach(async () => {
    caDir = mkdtempSync(join(tmpdir(), 'dai-ca-'))
    process.env.CA_DIR = caDir
    db = await freshDb()
    fx = await seed(db)
    await db.query(`INSERT INTO join_tokens (token) VALUES ('jt-test')`)
    // The admin who can approve.
    const g = await db.query(`INSERT INTO groups (name) VALUES ('admins') RETURNING id`)
    await db.query(`INSERT INTO group_members VALUES ($1,$2)`, [g.rows[0].id, fx.operatorId])
    await db.query(`INSERT INTO role_bindings VALUES ($1,$2,'admin')`, [g.rows[0].id, fx.poolId])
    const app = appFor(db)
    server = await new Promise<Server>((r) => { const s = app.listen(0, () => r(s)) })
    base = `http://127.0.0.1:${(server.address() as any).port}`
  })
  afterEach(async () => {
    await new Promise<void>((r) => server.close(() => r()))
    rmSync(caDir, { recursive: true, force: true })
  })
  afterAll(async () => { await db?.end() })

  const asUser = (id: string) => ({ authorization: `Bearer ${id}`, 'content-type': 'application/json' })

  async function enroll() {
    const { csr, dir } = makeCsr()
    const r = await fetch(`${base}/agent/v1/enroll`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        joinToken: 'jt-test', hostname: 'newmac', chip: 'Apple M4 Pro',
        memoryGb: 48, metalWorkingSetGb: 37.4, osVersion: '26.5.1', csrPem: csr,
      }),
    })
    return { ...(await r.json()), dir }
  }

  it('issues nothing at enrollment', async () => {
    const e = await enroll()
    expect(e.state).toBe('pending')
    expect(e.enrollmentToken).toBeTruthy()
    // A leaked join token must be a nuisance, not a fleet compromise.
    expect(e.certPem).toBeUndefined()

    const poll = await fetch(`${base}/agent/v1/enroll/${e.nodeId}`, {
      headers: { 'x-enrollment-token': e.enrollmentToken } })
    expect(poll.status).toBe(202)
    rmSync(e.dir, { recursive: true, force: true })
  })

  it('issues a usable certificate on approval', async () => {
    const e = await enroll()
    const approve = await fetch(`${base}/admin/v1/nodes/${e.nodeId}/approve`, {
      method: 'POST', headers: asUser(fx.operatorId) })
    expect(approve.status).toBe(200)

    const poll = await fetch(`${base}/agent/v1/enroll/${e.nodeId}`, {
      headers: { 'x-enrollment-token': e.enrollmentToken } })
    expect(poll.status).toBe(200)
    const issued = await poll.json()
    expect(issued.certPem).toContain('BEGIN CERTIFICATE')
    // The node CA is informational. What a node actually needs is the *server*
    // CA, and confusing the two fails every later connection with a certificate
    // error that reads like a network problem.
    expect(issued.nodeCaPem).toContain('BEGIN CERTIFICATE')

    // The stored fingerprint must match what a TLS handshake would report, or
    // the node authenticates once and never again.
    const { rows } = await db.query(`SELECT cert_fingerprint FROM nodes WHERE id=$1`, [e.nodeId])
    expect(rows[0].cert_fingerprint).toBe(fingerprintOfPem(issued.certPem))
    rmSync(e.dir, { recursive: true, force: true })
  })

  it('will not hand the certificate over twice', async () => {
    const e = await enroll()
    await fetch(`${base}/admin/v1/nodes/${e.nodeId}/approve`, {
      method: 'POST', headers: asUser(fx.operatorId) })
    const first = await fetch(`${base}/agent/v1/enroll/${e.nodeId}`, {
      headers: { 'x-enrollment-token': e.enrollmentToken } })
    expect(first.status).toBe(200)
    // Single use. A credential that can be replayed is one that will be.
    const second = await fetch(`${base}/agent/v1/enroll/${e.nodeId}`, {
      headers: { 'x-enrollment-token': e.enrollmentToken } })
    expect(second.status).toBe(401)
    rmSync(e.dir, { recursive: true, force: true })
  })

  it('refuses collection without the token', async () => {
    const e = await enroll()
    const r = await fetch(`${base}/agent/v1/enroll/${e.nodeId}`)
    expect(r.status).toBe(401)
    const wrong = await fetch(`${base}/agent/v1/enroll/${e.nodeId}`, {
      headers: { 'x-enrollment-token': 'guessed' } })
    expect(wrong.status).toBe(401)
    rmSync(e.dir, { recursive: true, force: true })
  })

  it('rejects an unsignable CSR at approval rather than half-enrolling', async () => {
    const r = await fetch(`${base}/agent/v1/enroll`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        joinToken: 'jt-test', hostname: 'bad', chip: 'x', memoryGb: 1,
        metalWorkingSetGb: 1, osVersion: '1', csrPem: 'not a csr at all',
      }),
    })
    const e = await r.json()
    const approve = await fetch(`${base}/admin/v1/nodes/${e.nodeId}/approve`, {
      method: 'POST', headers: asUser(fx.operatorId) })
    expect(approve.status).toBe(400)
    const { rows } = await db.query(`SELECT state FROM nodes WHERE id=$1`, [e.nodeId])
    expect(rows[0].state).toBe('pending')
  })

  it('stops a revoked node immediately', async () => {
    // Revocation is checked per request, not cached, so a stolen laptop stops
    // being a fleet member the moment it is reported.
    const policy = await fetch(`${base}/agent/v1/policy`, {
      headers: { 'x-node-fingerprint': fx.fingerprint } })
    expect(policy.status).toBe(200)

    const revoke = await fetch(`${base}/admin/v1/nodes/${fx.nodeId}/revoke`, {
      method: 'POST', headers: asUser(fx.operatorId) })
    expect(revoke.status).toBe(200)

    const after = await fetch(`${base}/agent/v1/policy`, {
      headers: { 'x-node-fingerprint': fx.fingerprint } })
    expect(after.status).toBe(401)
    expect((await after.json()).detail).toMatch(/revoked/)
  })

  it('stops a node whose certificate has expired', async () => {
    await db.query(`UPDATE nodes SET cert_not_after = now() - interval '1 day' WHERE id=$1`,
      [fx.nodeId])
    const r = await fetch(`${base}/agent/v1/policy`, {
      headers: { 'x-node-fingerprint': fx.fingerprint } })
    expect(r.status).toBe(401)
    // Expiry must be self-enforcing so renewal is routine rather than something
    // someone has to remember.
    expect((await r.json()).detail).toMatch(/expired/)
  })
})
