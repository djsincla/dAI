import { randomBytes, scrypt as scryptCb, timingSafeEqual } from 'node:crypto'
import { promisify } from 'node:util'

const scrypt = promisify(scryptCb) as (
  password: string, salt: Buffer, keylen: number, options: Record<string, number>,
) => Promise<Buffer>

/**
 * Storing a password so that a copy of the database is not a list of passwords.
 *
 * scrypt from node's own crypto rather than a dependency. It is a real
 * memory-hard KDF, it ships with the runtime, and adding a native module to a
 * control plane that issues certificates for a fleet is a supply chain decision
 * rather than a convenience one.
 *
 * The stored form carries its own parameters, so raising the cost later does not
 * invalidate existing passwords: an old hash still verifies with the parameters
 * it was made with, and can be upgraded the next time someone signs in.
 */
const FORMAT = 'scrypt'
const KEY_LENGTH = 64

/** Cost parameters. N is the expensive one; 2^17 is roughly 100ms on this hardware. */
const N = 1 << 17
const r = 8
const p = 1

export interface PasswordRule {
  ok: boolean
  reason?: string
}

/** The default every fresh deployment starts with, and must not keep. */
export const DEFAULT_PASSWORD = 'admin'
export const DEFAULT_USERNAME = 'admin'

export const MIN_LENGTH = 10

/**
 * Whether a proposed password may be used.
 *
 * Deliberately short. Length is the only rule that reliably helps, and
 * composition rules push people toward `Password1!` while blocking passphrases
 * that are genuinely stronger. The one specific refusal is the shipped default,
 * because a deployment still on `admin` is the failure this whole change exists
 * to prevent.
 */
export function checkPassword(candidate: string, username?: string): PasswordRule {
  if (candidate.length < MIN_LENGTH) {
    return { ok: false, reason: `must be at least ${MIN_LENGTH} characters` }
  }
  if (candidate.trim().length !== candidate.length) {
    return { ok: false, reason: 'must not start or end with a space' }
  }
  if (candidate.toLowerCase() === DEFAULT_PASSWORD) {
    return { ok: false, reason: 'cannot be the default password' }
  }
  if (username && candidate.toLowerCase() === username.toLowerCase()) {
    return { ok: false, reason: 'cannot be the same as the username' }
  }
  return { ok: true }
}

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16)
  const key = await scrypt(password, salt, KEY_LENGTH,
    { N, r, p, maxmem: 256 * 1024 * 1024 })
  return [FORMAT, N, r, p, salt.toString('base64'), key.toString('base64')].join('$')
}

/**
 * Whether a password matches a stored hash.
 *
 * Compared with a timing-safe equality, and returns false rather than throwing
 * on a malformed stored value: a corrupt row should fail the sign-in, not take
 * the endpoint down.
 */
export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const parts = stored.split('$')
  if (parts.length !== 6 || parts[0] !== FORMAT) return false

  const storedN = Number(parts[1])
  const storedR = Number(parts[2])
  const storedP = Number(parts[3])
  if (!Number.isFinite(storedN) || !Number.isFinite(storedR) || !Number.isFinite(storedP)) {
    return false
  }

  let salt: Buffer
  let expected: Buffer
  try {
    salt = Buffer.from(parts[4]!, 'base64')
    expected = Buffer.from(parts[5]!, 'base64')
  } catch {
    return false
  }
  if (expected.length === 0) return false

  const key = await scrypt(password, salt, expected.length,
    { N: storedN, r: storedR, p: storedP, maxmem: 256 * 1024 * 1024 })
  // Lengths are equal by construction above, but timingSafeEqual throws when
  // they are not, and a throw here would leak the difference as a 500.
  if (key.length !== expected.length) return false
  return timingSafeEqual(key, expected)
}
