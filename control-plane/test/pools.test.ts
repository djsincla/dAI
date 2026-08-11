import { describe, expect, it } from 'vitest'
import { nodeMatchesPool, poolMode, poolsFor, whyNotInPool } from '../src/lib/pools.js'

/**
 * Which nodes a pool is made of.
 *
 * The `membership` column shipped in the first migration and nothing read it,
 * so every job ran anywhere that would take it. These tests exist because the
 * consequence is not visible with one pool and is unrecoverable with two: gang
 * work on a preemptible node dies the moment somebody touches that keyboard,
 * and takes every other node's model load with it.
 */
const node = (over: Partial<Record<string, unknown>> = {}) => ({
  id: 'n-rotorua', tier: 'harvest', hostname: 'rotorua',
  chip: 'Apple M2 Max', memory_gb: 64, ...over,
}) as any

const pool = (over: Partial<Record<string, unknown>> = {}) => ({
  id: 'p1', tier: 'harvest', membership: {}, ...over,
}) as any

describe('the tier rule', () => {
  it('keeps harvest nodes out of a cluster pool', () => {
    // The asymmetry that matters. A workstation cannot promise never-preempted
    // at any memory ceiling or QoS, and gang work depends on that promise.
    expect(nodeMatchesPool(node({ tier: 'harvest' }), pool({ tier: 'cluster' }))).toBe(false)
    expect(whyNotInPool(node({ tier: 'harvest' }), pool({ tier: 'cluster' })))
      .toMatch(/cluster tier/)
  })

  it('lets a cluster node take harvest work', () => {
    // A dedicated box is strictly more reliable than a workstation, so barring
    // it would idle hardware for symmetry's sake. Harvest units survive
    // preemption by construction and do not care that their node is reliable.
    expect(nodeMatchesPool(node({ tier: 'cluster' }), pool({ tier: 'harvest' }))).toBe(true)
  })

  it('admits a cluster node to a cluster pool', () => {
    expect(nodeMatchesPool(node({ tier: 'cluster' }), pool({ tier: 'cluster' }))).toBe(true)
  })
})

describe('explicit narrowing', () => {
  it('enforces a memory floor', () => {
    const big = pool({ membership: { minMemoryGb: 32 } })
    expect(nodeMatchesPool(node({ memory_gb: 64 }), big)).toBe(true)
    expect(nodeMatchesPool(node({ memory_gb: 16 }), big)).toBe(false)
    expect(nodeMatchesPool(node({ memory_gb: 32 }), big)).toBe(true)
  })

  it('reads memory that Postgres returned as a string', () => {
    // numeric comes back as a string from pg. Comparing it to a number without
    // a cast makes "16" >= 32 true, which admits exactly the machines the floor
    // exists to keep out.
    expect(nodeMatchesPool(node({ memory_gb: '16' }), pool({ membership: { minMemoryGb: 32 } })))
      .toBe(false)
    expect(nodeMatchesPool(node({ memory_gb: '64' }), pool({ membership: { minMemoryGb: 32 } })))
      .toBe(true)
  })

  it('fails a node whose memory was never probed', () => {
    // Guessing upward would place work on a machine that cannot hold it.
    expect(nodeMatchesPool(node({ memory_gb: null }), pool({ membership: { minMemoryGb: 32 } })))
      .toBe(false)
  })

  it('matches named hosts and exact chips', () => {
    expect(nodeMatchesPool(node(), pool({ membership: { hostnames: ['rotorua', 'orca'] } })))
      .toBe(true)
    expect(nodeMatchesPool(node({ hostname: 'other' }),
      pool({ membership: { hostnames: ['rotorua'] } }))).toBe(false)
    expect(nodeMatchesPool(node(), pool({ membership: { chips: ['Apple M4 Pro'] } }))).toBe(false)
    expect(nodeMatchesPool(node({ chip: null }), pool({ membership: { chips: ['Apple M2 Max'] } })))
      .toBe(false)
  })

  it('treats an absent or empty membership as unconstrained', () => {
    // Every pool in the fleet today has `{}`, so this is the live path and not
    // a degenerate case.
    expect(nodeMatchesPool(node(), pool({ membership: {} }))).toBe(true)
    expect(nodeMatchesPool(node(), pool({ membership: null }))).toBe(true)
  })

  it('applies every constraint, not the first that passes', () => {
    const narrow = pool({ membership: { minMemoryGb: 32, chips: ['Apple M2 Max'] } })
    expect(nodeMatchesPool(node({ memory_gb: 64, chip: 'Apple M2 Max' }), narrow)).toBe(true)
    expect(nodeMatchesPool(node({ memory_gb: 16, chip: 'Apple M2 Max' }), narrow)).toBe(false)
    expect(nodeMatchesPool(node({ memory_gb: 64, chip: 'Apple M1' }), narrow)).toBe(false)
  })
})

describe('choosing pools for a node', () => {
  it('returns only the pools that will have it', () => {
    const pools = [
      pool({ id: 'harvest', tier: 'harvest' }),
      pool({ id: 'cluster', tier: 'cluster' }),
      pool({ id: 'big', tier: 'harvest', membership: { minMemoryGb: 128 } }),
    ]
    expect(poolsFor(node({ tier: 'harvest', memory_gb: 64 }), pools).map((p) => p.id))
      .toEqual(['harvest'])
    expect(poolsFor(node({ tier: 'cluster', memory_gb: 64 }), pools).map((p) => p.id))
      .toEqual(['harvest', 'cluster'])
  })

  it('returns nothing rather than everything when no pool matches', () => {
    // The failure that matters: an empty list must mean no work, never all
    // work. A membership check that falls open is worse than none, because it
    // reads as enforced.
    expect(poolsFor(node({ tier: 'harvest' }), [pool({ tier: 'cluster' })])).toEqual([])
  })
})

describe('groups somebody picked by hand', () => {
  it('holds machines by id, not by name', () => {
    // A hostname is not stable. A machine on this fleet enrolled as its own
    // IPv6 address this morning and was renamed afterwards; a group holding it
    // by name would have silently emptied itself.
    const group = pool({ membership: { nodeIds: ['n-rotorua'] } })
    expect(nodeMatchesPool(node({ hostname: 'renamed-later' }), group)).toBe(true)
    expect(nodeMatchesPool(node({ id: 'n-orca' }), group)).toBe(false)
  })

  it('ignores the rules once it is a list', () => {
    // Applying a memory floor on top would quietly drop a machine out of a
    // group it was visibly dragged into, which nobody would predict from
    // looking at the screen.
    const group = pool({ membership: { nodeIds: ['n-rotorua'], minMemoryGb: 512 } })
    expect(nodeMatchesPool(node({ memory_gb: 64 }), group)).toBe(true)
  })

  it('still refuses a harvest node in a cluster group', () => {
    // The one rule a list cannot override: gang work on a preemptible machine
    // dies the moment somebody touches that keyboard.
    const group = pool({ tier: 'cluster', membership: { nodeIds: ['n-rotorua'] } })
    expect(nodeMatchesPool(node({ tier: 'harvest' }), group)).toBe(false)
  })

  it('says which kind of group it is', () => {
    expect(poolMode(pool({ membership: {} }))).toBe('rule')
    expect(poolMode(pool({ membership: { minMemoryGb: 32 } }))).toBe('rule')
    expect(poolMode(pool({ membership: { nodeIds: [] } }))).toBe('rule')
    expect(poolMode(pool({ membership: { nodeIds: ['n-1'] } }))).toBe('list')
  })

  it('names a machine that is simply not in the group', () => {
    expect(whyNotInPool(node({ id: 'n-orca' }), pool({ membership: { nodeIds: ['n-1'] } })))
      .toBe('not in this group')
  })
})
