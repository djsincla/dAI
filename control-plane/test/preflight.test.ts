import { describe, expect, it } from 'vitest'
import { certDecision } from '../src/lib/preflight.js'

/**
 * The installer's most dangerous branch.
 *
 * It generates a certificate authority when it does not find one, which is
 * right on a new machine and catastrophic beside a database that already holds
 * a fleet: every node's certificate was issued by a CA that lives somewhere
 * else, and a fresh one locks all of them out at once while the install reports
 * success.
 *
 * This runs on somebody else's machine, once, with root. It is worth testing.
 */
describe('what an installer may do about certificates', () => {
  it('keeps what it finds, whatever else is true', () => {
    // The upgrade case, and the one that already worked: replacing a server
    // certificate on an established fleet means every agent that pinned the old
    // CA stops connecting, which looks exactly like the network going away.
    expect(certDecision({ caPresent: true, enrolledNodes: 0 }).action).toBe('keep')
    expect(certDecision({ caPresent: true, enrolledNodes: 12 }).action).toBe('keep')
  })

  it('generates on a genuinely new machine', () => {
    expect(certDecision({ caPresent: false, enrolledNodes: 0 }).action).toBe('generate')
  })

  it('refuses to mint a new authority next to an existing fleet', () => {
    // The pairing is the whole signal: no CA here, and nodes there. Neither half
    // alone means anything - an empty state directory is a first install, and a
    // populated one is an upgrade.
    const out = certDecision({ caPresent: false, enrolledNodes: 2 })
    expect(out.action).toBe('refuse')
    expect(out.detail).toContain('2 machines')
    expect(out.detail).toContain('lock every one of them out')
  })

  it('says what to do instead, and names the flag', () => {
    // A refusal that does not say how to proceed is a refusal somebody works
    // around by deleting the check.
    const out = certDecision({ caPresent: false, enrolledNodes: 2 })
    expect(out.detail).toContain('--adopt-certs')
    expect(out.detail).toContain('ca.crt')
    expect(out.detail).toContain('control-plane/certs')
    // And the way out if the fleet really is gone, so the check cannot become a
    // dead end on a machine somebody is rebuilding deliberately.
    expect(out.detail).toContain('empty the nodes table')
  })

  it('counts one machine as one', () => {
    expect(certDecision({ caPresent: false, enrolledNodes: 1 }).detail)
      .toContain('1 machine enrolled')
  })

  it('names the directory it would have written to', () => {
    // The operator has to be able to find the CA that is missing, and the path
    // differs between a package install and a working tree.
    expect(certDecision({ caPresent: false, enrolledNodes: 3, stateDir: '/opt/dai' }).detail)
      .toContain('/opt/dai')
  })
})
