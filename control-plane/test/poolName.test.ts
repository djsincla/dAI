import { describe as group, expect, it } from 'vitest'
import { checkPoolName, TIER_NAMES } from '../src/lib/pools.js'

/**
 * What a group may be called.
 *
 * The rule exists because of one group. "Cluster" was harvest tier:
 * preemptible, presence gated, scheduled as independent units, which is the
 * opposite of everything the name claims. Reading a pool listing meant knowing
 * to ignore the name and look at the tier column, and an operator standing it
 * up expecting a dedicated box got the other thing.
 */
group('a group name', () => {
  it('refuses a tier name', () => {
    for (const n of ['cluster', 'Cluster', 'CLUSTER', 'harvest', 'Harvest']) {
      const out = checkPoolName(n)
      expect('error' in out, n).toBe(true)
      // The message has to say why, because the caller's next move is to think
      // of a different name and the reason is what shapes it.
      expect((out as { error: string }).error).toMatch(/tier/)
    }
  })

  it('allows a name that merely contains one', () => {
    // "split-cluster" describes what the group does. Refusing every name with
    // the substring in it would ban the useful ones along with the misleading
    // one.
    expect(checkPoolName('split-cluster')).toEqual({ name: 'split-cluster' })
    expect(checkPoolName('overnight-harvest')).toEqual({ name: 'overnight-harvest' })
  })

  it('trims, and refuses what is left when that is nothing', () => {
    expect(checkPoolName('  studio-macs  ')).toEqual({ name: 'studio-macs' })
    expect('error' in checkPoolName('   ')).toBe(true)
    expect('error' in checkPoolName('')).toBe(true)
  })

  it('refuses a name that is not a string at all', () => {
    for (const v of [undefined, null, 42, {}, []]) {
      expect('error' in checkPoolName(v), String(v)).toBe(true)
    }
  })

  it('refuses one too long to read in a listing', () => {
    expect('error' in checkPoolName('x'.repeat(65))).toBe(true)
    expect(checkPoolName('x'.repeat(64))).toEqual({ name: 'x'.repeat(64) })
  })

  it('a trimmed tier name is still a tier name', () => {
    expect('error' in checkPoolName('  cluster ')).toBe(true)
  })

  it('knows which names are tiers', () => {
    // Pinned so that adding a tier to the schema without adding it here shows
    // up as a failing test rather than as a group named after it.
    expect(TIER_NAMES).toEqual(['harvest', 'cluster'])
  })
})
