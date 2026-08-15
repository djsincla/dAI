import { describe, expect, it } from 'vitest'
import { Acl } from '../src/lib/netacl.js'

/**
 * Loopback has two spellings and an allowlist knew only one.
 *
 * `localhost` resolves to `::1` before `127.0.0.1` on macOS, so the status app
 * asking its own control plane for fleet numbers was refused by a range that
 * plainly permitted loopback - and the message said only "address not
 * permitted", which sends somebody looking for a permission that does not
 * exist.
 */
describe('loopback, in both spellings', () => {
  it('accepts ::1 when the operator allowed 127.0.0.1', () => {
    const acl = new Acl('127.0.0.1/32')
    expect(acl.allows('127.0.0.1')).toBe(true)
    expect(acl.allows('::1')).toBe(true)
  })

  it('accepts 127.0.0.1 when the operator allowed ::1', () => {
    const acl = new Acl('::1')
    expect(acl.allows('::1')).toBe(true)
    expect(acl.allows('127.0.0.1')).toBe(true)
  })

  it('works however loopback was spelled in the range', () => {
    // Decided from the finished list, not by matching strings, so a subnet that
    // happens to contain loopback behaves the same as naming it.
    for (const spec of ['127.0.0.1/32', '127.0.0.0/8', '127.0.0.1', '::1/128']) {
      const acl = new Acl(spec)
      expect(acl.allows('::1'), spec).toBe(true)
      expect(acl.allows('127.0.0.1'), spec).toBe(true)
    }
  })

  it('the real case: loopback beside a LAN range', () => {
    // Exactly what DAI_MONITOR_CIDRS holds on this fleet.
    const acl = new Acl('127.0.0.1/32,192.168.4.0/24')
    expect(acl.allows('::1')).toBe(true)
    expect(acl.allows('192.168.4.24')).toBe(true)
    expect(acl.allows('192.168.5.1')).toBe(false)
  })
})

describe('and it widens nothing else', () => {
  it('does not admit loopback to a range that never had it', () => {
    // The whole justification is that ::1 and 127.0.0.1 are the same machine.
    // Neither belongs in a list that permitted only a LAN.
    const acl = new Acl('192.168.4.0/24')
    expect(acl.allows('127.0.0.1')).toBe(false)
    expect(acl.allows('::1')).toBe(false)
  })

  it('does not pair up any other address', () => {
    // Only loopback has two forms meaning one host. A v6 range must not drag in
    // its v4 numerical lookalike.
    const acl = new Acl('::2')
    expect(acl.allows('::2')).toBe(true)
    expect(acl.allows('0.0.0.2')).toBe(false)
    expect(acl.allows('127.0.0.1')).toBe(false)
  })

  it('leaves an unset list open, as before', () => {
    expect(new Acl(undefined).allows('8.8.8.8')).toBe(true)
    expect(new Acl('').open).toBe(true)
  })

  it('still refuses everything outside the list', () => {
    const acl = new Acl('127.0.0.1/32')
    expect(acl.allows('192.168.4.24')).toBe(false)
    expect(acl.allows('::ffff:8.8.8.8')).toBe(false)
    expect(acl.allows(undefined)).toBe(false)
  })

  it('still unwraps an IPv4-mapped peer, which is a different problem', () => {
    // Node reports IPv4 peers on a dual-stack socket as ::ffff:a.b.c.d. That is
    // a wrapped v4 address; ::1 is not, and conflating the two is how this bug
    // would come back.
    expect(new Acl('192.168.4.0/24').allows('::ffff:192.168.4.24')).toBe(true)
  })
})
