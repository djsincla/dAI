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

/**
 * A fresh CSR from a key that already exists.
 *
 * This is the ordinary renewal case: the key lives in the Secure Enclave, has
 * no way to leave the machine and no reason to change, so what a node asks for
 * at renewal is a new certificate over the same key.
 */
function csrForExistingKey(dir: string, cn = 'whatever-the-node-asked-for'): string {
  execSync(`openssl req -new -key ${dir}/k.pem -out ${dir}/renew.csr ` +
           `-subj "/CN=${cn}" 2>/dev/null`)
  return readFileSync(`${dir}/renew.csr`, 'utf8')
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
    // -nameopt RFC2253 because openssl's default subject formatting is not
    // stable across builds: 3.6.3 locally prints `CN=node-42, OU=orca` and
    // the CI runner prints `CN = node-42, OU = orca`, so an assertion written
    // against one machine fails on the other while the certificate is
    // byte-identical. RFC2253 is a specified format and renders the same
    // everywhere.
    const subject = execSync(`echo '${signed.certPem}' | openssl x509 -noout -subject -nameopt RFC2253`).toString()
    expect(subject).toContain('CN=node-42')
    expect(subject).not.toContain('i-am-the-admin-box')
    rmSync(dir, { recursive: true, force: true })
  })

  it('issues certificates a node can use as either end of a connection', async () => {
    // A node is a client to the control plane and a server to another node: one
    // half of a split model listens and the other connects to it. Client-only
    // certificates were refused by the connecting side for "unsuitable
    // certificate purpose", which names the extension rather than the
    // situation and reads like a broken link.
    //
    // Nothing here lets a node pose as the control plane. That is prevented by
    // the control plane being signed by a different CA which agents pin
    // separately, not by these bits.
    const { csr, dir } = makeCsr()
    const signed = await ca.sign(csr, 'node-1', 'orca')
    const text = execSync(`echo '${signed.certPem}' | openssl x509 -noout -text -nameopt RFC2253`).toString()
    expect(text).toContain('TLS Web Client Authentication')
    expect(text).toContain('TLS Web Server Authentication')
    expect(text).toContain('CA:FALSE')
    rmSync(dir, { recursive: true, force: true })
  })

  it('issues a certificate openssl accepts for server use', async () => {
    // The assertion above reads the extension; this one asks a verifier, which
    // is what actually rejected it. `-purpose sslserver` is the check the
    // connecting half of a split performs.
    const { csr, dir } = makeCsr()
    const signed = await ca.sign(csr, 'node-1', 'orca')
    writeFileSync(join(dir, 'node.crt'), signed.certPem)
    writeFileSync(join(dir, 'ca.crt'), ca.certPem)
    for (const purpose of ['sslserver', 'sslclient']) {
      const out = execSync(
        `openssl verify -purpose ${purpose} -CAfile ${dir}/ca.crt ${dir}/node.crt`,
      ).toString()
      expect(out).toContain('OK')
    }
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
    const text = execSync(`echo '${signed.certPem}' | openssl x509 -noout -text -nameopt RFC2253`).toString()
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
    const text = execSync(`echo '${signed.certPem}' | openssl x509 -noout -text -nameopt RFC2253`).toString()
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


  it('retires the old record when the same machine enrolls again', async () => {
    // A reinstalled machine arrives as a new node with a new key. Without this
    // the old record stays active-looking forever, so the fleet view shows two
    // entries for one machine and counts its capacity twice - which is exactly
    // what a fleet view must not do.
    const machineId = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'
    // A token per enrolment, because they are single use now.
    //
    // This test used to re-enrol with the same one, which is what re-enrolment
    // did in practice - `reenroll-node.sh --token` takes a token and reuses it.
    // Enforcing what the schema had declared since it was written changed that,
    // and the answer is that tooling mints rather than operators hoarding: it is
    // one command, and a credential good for one machine forever was the thing
    // worth fixing.
    let minted = 0
    const enrollSame = async () => {
      const token = `jt-reenrol-${minted++}`
      await db.query(`INSERT INTO join_tokens (token) VALUES ($1)`, [token])
      const { csr, dir } = makeCsr('same-machine', 'ec')
      const r = await fetch(`${base}/agent/v1/enroll`, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          joinToken: token, hostname: 'rotorua', chip: 'Apple M4 Pro',
          memoryGb: 48, metalWorkingSetGb: 38, osVersion: '15.0',
          csrPem: csr, machineId,
        }),
      })
      rmSync(dir, { recursive: true, force: true })
      return (await r.json() as any).nodeId as string
    }
    const approve = (id: string) =>
      fetch(`${base}/admin/v1/nodes/${id}/approve`, {
        method: 'POST', headers: asUser(fx.operatorToken), body: '{}',
      })

    const first = await enrollSame()
    await approve(first)
    const second = await enrollSame()
    await approve(second)

    const { rows } = await db.query(
      `SELECT id, state FROM nodes WHERE machine_id = $1 ORDER BY created_at`, [machineId])
    expect(rows).toHaveLength(2)
    expect(rows[0].state).toBe('superseded')
    expect(rows[1].state).toBe('active')

    // Superseded rather than deleted: the certificate really was issued and
    // knowing what was signed matters after the fact.
    const { rows: kept } = await db.query(
      `SELECT cert_pem FROM nodes WHERE id = $1`, [rows[0].id])
    expect(kept[0].cert_pem).toBeTruthy()
  })

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
      method: 'POST', headers: asUser(fx.operatorToken) })
    expect(approve.status).toBe(200)

    const poll = await fetch(`${base}/agent/v1/enroll/${e.nodeId}`, {
      headers: { 'x-enrollment-token': e.enrollmentToken } })
    expect(poll.status).toBe(200)
    const issued = await poll.json()
    expect(issued.certPem).toContain('BEGIN CERTIFICATE')
    // Both CAs, and they are not interchangeable. The server CA is what a node
    // pins to verify the control plane; the node CA is what it needs to verify
    // another node, now that one machine holding half a model has to trust the
    // machine holding the other half. Handing over only the server CA - which
    // is what this used to do - fails a peer handshake with "unknown CA", an
    // error that reads like a network problem.
    expect(issued.nodeCaPem).toContain('BEGIN CERTIFICATE')
    expect(issued.nodeCaPem).not.toBe(issued.serverCaPem)
    // Asked of a verifier rather than of the string, because what matters is
    // that this is the CA under which the certificate just issued checks out.
    writeFileSync(join(e.dir, 'node.crt'), issued.certPem)
    writeFileSync(join(e.dir, 'node-ca.crt'), issued.nodeCaPem)
    expect(execSync(
      `openssl verify -CAfile ${e.dir}/node-ca.crt ${e.dir}/node.crt`).toString(),
    ).toContain('OK')

    // The stored fingerprint must match what a TLS handshake would report, or
    // the node authenticates once and never again.
    const { rows } = await db.query(`SELECT cert_fingerprint FROM nodes WHERE id=$1`, [e.nodeId])
    expect(rows[0].cert_fingerprint).toBe(fingerprintOfPem(issued.certPem))
    rmSync(e.dir, { recursive: true, force: true })
  })

  /**
   * Renewal, which is what makes short-lived certificates affordable.
   *
   * Thirty-day certificates are a deliberate choice: a machine that leaves the
   * building should stop being a fleet member on its own. That is only workable
   * if the machines still in the building renew without anybody visiting them.
   */
  async function approvedNode() {
    const e = await enroll()
    await fetch(`${base}/admin/v1/nodes/${e.nodeId}/approve`, {
      method: 'POST', headers: asUser(fx.operatorToken) })
    const poll = await fetch(`${base}/agent/v1/enroll/${e.nodeId}`, {
      headers: { 'x-enrollment-token': e.enrollmentToken } })
    const issued = await poll.json()
    return { ...e, certPem: issued.certPem as string }
  }

  const renew = (fingerprint: string, csrPem: string) =>
    fetch(`${base}/agent/v1/renew`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-node-fingerprint': fingerprint },
      body: JSON.stringify({ csrPem }),
    })

  it('renews without an admin, and the new certificate is the one that works', async () => {
    const node = await approvedNode()
    const before = fingerprintOfPem(node.certPem)

    const r = await renew(before, csrForExistingKey(node.dir))
    expect(r.status).toBe(200)
    const renewed = await r.json()
    expect(renewed.certPem).not.toBe(node.certPem)
    expect(new Date(renewed.notAfter).getTime()).toBeGreaterThan(Date.now())

    // The point of the exercise: the node authenticates with the new
    // certificate, and the old one stops being an identity. A renewal that left
    // both working would mean a copy taken before renewal outlived it.
    const after = fingerprintOfPem(renewed.certPem)
    expect((await fetch(`${base}/agent/v1/policy`,
      { headers: { 'x-node-fingerprint': after } })).status).toBe(200)
    expect((await fetch(`${base}/agent/v1/policy`,
      { headers: { 'x-node-fingerprint': before } })).status).toBe(401)
    rmSync(node.dir, { recursive: true, force: true })
  })

  it('hands back both CAs, so a node picks up what it was never given', async () => {
    // Nodes enrolled before machines talked to each other have no node CA on
    // disk, and cannot be the listening half of a split model without it.
    // Renewal is how they acquire it, rather than being re-enrolled by hand.
    const node = await approvedNode()
    const renewed = await (await renew(
      fingerprintOfPem(node.certPem), csrForExistingKey(node.dir))).json()
    writeFileSync(join(node.dir, 'node.crt'), renewed.certPem)
    writeFileSync(join(node.dir, 'node-ca.crt'), renewed.nodeCaPem)
    expect(execSync(
      `openssl verify -CAfile ${node.dir}/node-ca.crt ${node.dir}/node.crt`).toString(),
    ).toContain('OK')
    rmSync(node.dir, { recursive: true, force: true })
  })

  it('records whether the key changed', async () => {
    // The Enclave key does not normally change, so a renewal that carries a new
    // one is worth a line in the log: it is the only trace of a machine's key
    // being rebuilt.
    const node = await approvedNode()
    const same = await (await renew(
      fingerprintOfPem(node.certPem), csrForExistingKey(node.dir))).json()
    expect(same.rekeyed).toBe(false)

    const other = makeCsr('whatever', 'ec')
    const changed = await (await renew(fingerprintOfPem(same.certPem), other.csr)).json()
    expect(changed.rekeyed).toBe(true)

    const { rows } = await db.query(
      `SELECT detail FROM activity_log WHERE node_id=$1 AND event='node.renewed'
        ORDER BY at`, [node.nodeId])
    expect(rows.map((r: any) => r.detail.rekeyed)).toEqual([false, true])
    rmSync(node.dir, { recursive: true, force: true })
    rmSync(other.dir, { recursive: true, force: true })
  })

  it('will not renew a revoked node', async () => {
    // Otherwise revocation lasts until the certificate expires and no longer,
    // because the stolen machine renews itself back into the fleet.
    const node = await approvedNode()
    await fetch(`${base}/admin/v1/nodes/${node.nodeId}/revoke`,
      { method: 'POST', headers: asUser(fx.operatorToken) })
    const r = await renew(fingerprintOfPem(node.certPem), csrForExistingKey(node.dir))
    expect(r.status).toBe(401)
    expect((await r.json()).detail).toMatch(/revoked/)
    rmSync(node.dir, { recursive: true, force: true })
  })

  it('will not renew a certificate that has already expired', async () => {
    // Renewal extends an identity, it does not resurrect one. A certificate
    // that lapsed unnoticed belongs to a machine nobody has accounted for in a
    // month, and that should need a human.
    const node = await approvedNode()
    await db.query(`UPDATE nodes SET cert_not_after = now() - interval '1 day' WHERE id=$1`,
      [node.nodeId])
    const r = await renew(fingerprintOfPem(node.certPem), csrForExistingKey(node.dir))
    expect(r.status).toBe(401)
    rmSync(node.dir, { recursive: true, force: true })
  })

  it('will not renew a node whose hardware has come back as a new record', async () => {
    // Two live certificates on one machine would make the fleet count its
    // capacity twice and hand the same work to itself.
    const node = await approvedNode()
    await db.query(`UPDATE nodes SET state='superseded' WHERE id=$1`, [node.nodeId])
    const r = await renew(fingerprintOfPem(node.certPem), csrForExistingKey(node.dir))
    // 401 rather than the route's own 403: a superseded identity is now refused
    // at authentication, for every agent endpoint rather than this one. The
    // route keeps its check, which still answers for paused and offline nodes.
    expect(r.status).toBe(401)
    expect((await r.json()).detail).toMatch(/superseded/)
    rmSync(node.dir, { recursive: true, force: true })
  })

  it('refuses a CSR it cannot sign rather than issuing something else', async () => {
    const node = await approvedNode()
    const r = await renew(fingerprintOfPem(node.certPem), 'not a csr')
    expect(r.status).toBe(400)
    // The certificate it already holds must keep working, or a malformed
    // request would take a machine out of the fleet.
    expect((await fetch(`${base}/agent/v1/policy`,
      { headers: { 'x-node-fingerprint': fingerprintOfPem(node.certPem) } })).status).toBe(200)
    rmSync(node.dir, { recursive: true, force: true })
  })

  it('will not hand the certificate over twice', async () => {
    const e = await enroll()
    await fetch(`${base}/admin/v1/nodes/${e.nodeId}/approve`, {
      method: 'POST', headers: asUser(fx.operatorToken) })
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
      method: 'POST', headers: asUser(fx.operatorToken) })
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
      method: 'POST', headers: asUser(fx.operatorToken) })
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
