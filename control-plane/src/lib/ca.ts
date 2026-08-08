import { createHash, randomBytes } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import forge from 'node-forge'

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
export function loadOrCreateCa(certPath: string, keyPath: string): CaMaterial {
  if (existsSync(certPath) && existsSync(keyPath)) {
    return { certPem: readFileSync(certPath, 'utf8'), keyPem: readFileSync(keyPath, 'utf8') }
  }

  const keys = forge.pki.rsa.generateKeyPair(2048)
  const cert = forge.pki.createCertificate()
  cert.publicKey = keys.publicKey
  cert.serialNumber = '01'
  cert.validity.notBefore = new Date()
  cert.validity.notAfter = new Date(Date.now() + 365 * 24 * 3600 * 1000)

  const attrs = [{ name: 'commonName', value: 'dAI node CA' }]
  cert.setSubject(attrs)
  cert.setIssuer(attrs)
  cert.setExtensions([
    { name: 'basicConstraints', cA: true, critical: true },
    { name: 'keyUsage', keyCertSign: true, cRLSign: true, critical: true },
  ])
  cert.sign(keys.privateKey, forge.md.sha256.create())

  const material = {
    certPem: forge.pki.certificateToPem(cert),
    keyPem: forge.pki.privateKeyToPem(keys.privateKey),
  }
  for (const p of [certPath, keyPath]) mkdirSync(dirname(p), { recursive: true })
  writeFileSync(certPath, material.certPem)
  writeFileSync(keyPath, material.keyPem, { mode: 0o600 })
  return material
}

export class Ca {
  private readonly caCert: forge.pki.Certificate
  private readonly caKey: forge.pki.rsa.PrivateKey
  readonly certPem: string

  constructor(material: CaMaterial) {
    this.certPem = material.certPem
    this.caCert = forge.pki.certificateFromPem(material.certPem)
    this.caKey = forge.pki.privateKeyFromPem(material.keyPem) as forge.pki.rsa.PrivateKey
  }

  static fromEnv(): Ca {
    const dir = process.env.CA_DIR ?? join(process.cwd(), 'certs')
    return new Ca(loadOrCreateCa(
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
  sign(csrPem: string, nodeId: string, hostname: string, days = DEFAULT_CERT_DAYS): {
    certPem: string
    fingerprint: string
    notAfter: Date
  } {
    let csr: forge.pki.CertificateSigningRequest
    try {
      csr = forge.pki.certificationRequestFromPem(csrPem)
    } catch (err) {
      throw new Error(`unparseable CSR: ${(err as Error).message}`)
    }
    // A CSR is self-signed by definition; if that check fails the key does not
    // match the request and signing it would bind an identity to a key its
    // holder does not control.
    if (!csr.verify()) throw new Error('CSR signature does not verify')
    if (!csr.publicKey) throw new Error('CSR carries no public key')

    const cert = forge.pki.createCertificate()
    cert.publicKey = csr.publicKey
    cert.serialNumber = randomBytes(16).toString('hex')
    cert.validity.notBefore = new Date(Date.now() - 60_000) // clock skew
    cert.validity.notAfter = new Date(Date.now() + days * 24 * 3600 * 1000)
    cert.setSubject([
      { name: 'commonName', value: nodeId },
      { name: 'organizationalUnitName', value: hostname },
    ])
    cert.setIssuer(this.caCert.subject.attributes)
    cert.setExtensions([
      { name: 'basicConstraints', cA: false, critical: true },
      { name: 'keyUsage', digitalSignature: true, keyEncipherment: true, critical: true },
      // Client auth only. A node certificate must not be usable to impersonate
      // the control plane to another node.
      { name: 'extKeyUsage', clientAuth: true },
    ])
    cert.sign(this.caKey, forge.md.sha256.create())

    const certPem = forge.pki.certificateToPem(cert)
    return { certPem, fingerprint: fingerprintOfPem(certPem), notAfter: cert.validity.notAfter }
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
  const der = forge.util.decode64(
    certPem.replace(/-----(BEGIN|END) CERTIFICATE-----/g, '').replace(/\s/g, ''),
  )
  const hex = createHash('sha256').update(Buffer.from(der, 'binary')).digest('hex').toUpperCase()
  return hex.match(/.{2}/g)!.join(':')
}

/** One-time secret a node uses to collect its certificate after approval. */
export function newEnrollmentToken(): string {
  return randomBytes(24).toString('base64url')
}
