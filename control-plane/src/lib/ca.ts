// @peculiar/x509 resolves its ASN.1 converters through tsyringe, which needs
// this loaded before the library is imported. It has to be the first import in
// the file or the decorators run against a missing Reflect.metadata.
import 'reflect-metadata'
import { createHash, createPrivateKey, randomBytes, webcrypto } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import * as x509 from '@peculiar/x509'

const crypto = webcrypto as unknown as Crypto
x509.cryptoProvider.set(crypto)

/**
 * Certificate authority for node identity.
 *
 * Until now enrollment recorded a hash of the CSR and every deployment ran on
 * DAI_TRUST_FINGERPRINT_HEADER, which the auth module correctly describes as
 * not being authentication at all. This is what makes the security design real:
 * a node's identity becomes a certificate this CA signed, and nothing else.
 *
 * Three properties the design depends on:
 *
 * **Signing happens at approval, never at enrollment.** A join token gets a node
 * into a queue. An admin decides whether it becomes a member. A leaked token is
 * then a nuisance rather than a fleet compromise.
 *
 * **Certificates are short-lived.** These live on laptops that leave the
 * building. A stolen machine should stop being a fleet member on its own, so
 * expiry is measured in days and renewal is routine rather than exceptional.
 *
 * **The CA private key never goes in the database.** It is read from disk at a
 * path the process is given, so a database compromise does not mint node
 * identities. In production that path is a mounted secret.
 *
 * This runs on WebCrypto rather than node-forge because forge cannot sign
 * elliptic-curve CSRs, and the agent's key has to be EC: the Secure Enclave
 * generates P-256 and nothing else. That is not a preference. A key held in the
 * Enclave cannot be copied off the disk it lives on, which is the difference
 * between a certificate being an identity and a certificate being a file
 * somebody can take. RSA CSRs still sign, because certificates already issued
 * against RSA keys must keep working through their remaining validity.
 */

export const DEFAULT_CERT_DAYS = 30

export interface CaMaterial {
  certPem: string
  keyPem: string
}

/**
 * Load the CA, creating one if absent.
 *
 * Generating on first run makes a local deployment work without ceremony, which
 * matters because the alternative is people disabling TLS to get started and
 * never turning it back on. A real deployment supplies its own and never lets
 * this branch run.
 */
export async function loadOrCreateCa(certPath: string, keyPath: string): Promise<CaMaterial> {
  if (existsSync(certPath) && existsSync(keyPath)) {
    return { certPem: readFileSync(certPath, 'utf8'), keyPem: readFileSync(keyPath, 'utf8') }
  }

  const alg = { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' }
  const keys = await crypto.subtle.generateKey(alg, true, ['sign', 'verify'])
  const cert = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: randomBytes(16).toString('hex'),
    name: 'CN=dAI node CA',
    notBefore: new Date(),
    notAfter: new Date(Date.now() + 365 * 24 * 3600 * 1000),
    keys,
    signingAlgorithm: alg,
    extensions: [
      new x509.BasicConstraintsExtension(true, undefined, true),
      // Without keyUsage, Python's ssl module rejects the chain outright with
      // "CA cert does not include key usage extension". Browsers do not care,
      // which is how it survived until an agent tried to verify against it.
      new x509.KeyUsagesExtension(
        x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign, true),
    ],
  })

  const pkcs8 = await crypto.subtle.exportKey('pkcs8', keys.privateKey)
  const material = {
    certPem: cert.toString('pem'),
    keyPem: x509.PemConverter.encode(pkcs8, 'PRIVATE KEY'),
  }
  for (const p of [certPath, keyPath]) mkdirSync(dirname(p), { recursive: true })
  writeFileSync(certPath, material.certPem)
  writeFileSync(keyPath, material.keyPem, { mode: 0o600 })
  return material
}

/**
 * Import the CA private key for signing, whichever algorithm it happens to be.
 *
 * A CA generated before this change is RSA and a fresh one is EC, and both must
 * keep issuing: rotating a CA invalidates every certificate under it, which
 * would mean re-approving the whole fleet by hand.
 */
async function importCaKey(keyPem: string): Promise<{ key: CryptoKey, algorithm: Algorithm }> {
  const parsed = createPrivateKey(keyPem)
  const pkcs8 = parsed.export({ type: 'pkcs8', format: 'der' }) as Buffer
  const algorithm = parsed.asymmetricKeyType === 'ec'
    ? { name: 'ECDSA', hash: 'SHA-256' }
    : { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }
  const importAlg = parsed.asymmetricKeyType === 'ec'
    ? { name: 'ECDSA', namedCurve: 'P-256' }
    : { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }
  const key = await crypto.subtle.importKey('pkcs8', new Uint8Array(pkcs8), importAlg, false, ['sign'])
  return { key, algorithm }
}

export class Ca {
  private readonly caCert: x509.X509Certificate
  private readonly caKeyPem: string
  readonly certPem: string

  constructor(material: CaMaterial) {
    this.certPem = material.certPem
    this.caCert = new x509.X509Certificate(material.certPem)
    this.caKeyPem = material.keyPem
  }

  static async fromEnv(): Promise<Ca> {
    const dir = process.env.CA_DIR ?? join(process.cwd(), 'certs')
    return new Ca(await loadOrCreateCa(
      process.env.CA_CERT ?? join(dir, 'ca.crt'),
      process.env.CA_KEY ?? join(dir, 'ca.key'),
    ))
  }

  /**
   * Sign a node's CSR.
   *
   * The subject is taken from this CA, not from the CSR: a node does not get to
   * choose the name it is known by. The common name is the node's id, so a
   * certificate cannot be quietly reused for a different node record even if the
   * same key is presented again.
   */
  async sign(csrPem: string, nodeId: string, hostname: string, days = DEFAULT_CERT_DAYS): Promise<{
    certPem: string
    fingerprint: string
    notAfter: Date
  }> {
    let csr: x509.Pkcs10CertificateRequest
    try {
      csr = new x509.Pkcs10CertificateRequest(csrPem)
    } catch (err) {
      throw new Error(`unparseable CSR: ${(err as Error).message}`)
    }
    // A CSR is self-signed by definition; if that check fails the key does not
    // match the request and signing it would bind an identity to a key its
    // holder does not control.
    if (!(await csr.verify())) throw new Error('CSR signature does not verify')

    const publicKey = await csr.publicKey.export(crypto)
    const isEC = publicKey.algorithm.name.startsWith('EC')

    // keyEncipherment describes RSA key transport and means nothing for an EC
    // key, which can only sign. Asserting it anyway would be a claim the key
    // cannot honour, and some verifiers check.
    const usages = x509.KeyUsageFlags.digitalSignature
      | (isEC ? 0 : x509.KeyUsageFlags.keyEncipherment)

    const notBefore = new Date(Date.now() - 60_000) // clock skew
    const notAfter = new Date(Date.now() + days * 24 * 3600 * 1000)
    const { key: signingKey, algorithm: signingAlgorithm } = await importCaKey(this.caKeyPem)

    const cert = await x509.X509CertificateGenerator.create({
      serialNumber: randomBytes(16).toString('hex'),
      // Built from parts rather than a formatted string: a hostname containing
      // a comma or an equals sign would otherwise inject an extra RDN and let a
      // node influence the name it is known by.
      subject: new x509.Name([{ CN: [nodeId] }, { OU: [hostname] }]),
      issuer: this.caCert.subjectName,
      notBefore,
      notAfter,
      publicKey,
      signingKey,
      signingAlgorithm,
      extensions: [
        new x509.BasicConstraintsExtension(false, undefined, true),
        new x509.KeyUsagesExtension(usages, true),
        // Both, because a node is now sometimes the server.
        //
        // Nodes talk to each other: one holding half a model listens, and the
        // one holding the other half connects. The listener presents this
        // certificate, and a client-only certificate is refused for
        // "unsuitable certificate purpose" - a message that names the
        // extension rather than the situation, and reads like a broken link.
        //
        // This does not let a node pose as the control plane. The control
        // plane's certificate is signed by a different CA, and agents pin that
        // one; nothing signed here can satisfy it. The separation of the two
        // CAs is what enforces that, not the key usage bits.
        new x509.ExtendedKeyUsageExtension([
          x509.ExtendedKeyUsage.clientAuth,
          x509.ExtendedKeyUsage.serverAuth,
        ]),
      ],
    })

    const certPem = cert.toString('pem')
    return { certPem, fingerprint: fingerprintOfPem(certPem), notAfter }
  }
}

/**
 * SHA-256 fingerprint in the form Node's TLS layer reports it.
 *
 * `getPeerCertificate().fingerprint256` returns uppercase hex separated by
 * colons. Storing any other format means every mTLS lookup silently misses, so
 * this exists to keep the two ends in the same shape.
 */
export function fingerprintOfPem(certPem: string): string {
  const der = Buffer.from(
    certPem.replace(/-----(BEGIN|END) CERTIFICATE-----/g, '').replace(/\s/g, ''), 'base64')
  const hex = createHash('sha256').update(der).digest('hex').toUpperCase()
  return hex.match(/.{2}/g)!.join(':')
}

/** One-time secret a node uses to collect its certificate after approval. */
export function newEnrollmentToken(): string {
  return randomBytes(24).toString('base64url')
}
