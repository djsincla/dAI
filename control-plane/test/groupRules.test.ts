import { describe, expect, it } from 'vitest'
import { coupledWith, groupsFor, violations, type Group } from '../src/lib/groupRules.js'
import type { NodeFacts } from '../src/lib/pools.js'

/**
 * The rules that decide whether a fleet of groups can exist.
 *
 * Both are about what one machine can promise at once, and both are refused on
 * write rather than discovered later from a behaviour.
 */

const node = (hostname: string, over: Partial<NodeFacts> = {}): NodeFacts => ({
  id: `id-${hostname}`,
  hostname,
  tier: 'cluster',
  chip: 'Apple M2 Max',
  memory_gb: 64,
  ...over,
})

const group = (name: string, over: Partial<Group> = {}): Group => ({
  id: `pool-${name}`,
  name,
  tier: 'harvest',
  membership: {},
  servingModelId: null,
  ...over,
})

describe('a machine is in at most one group per tier', () => {
  it('allows one of each tier', () => {
    // The arrangement the design is built around: a workstation lent to a
    // harvest group and also part of a dedicated cluster group.
    const nodes = [node('rotorua')]
    const groups = [group('overnight'), group('serving', { tier: 'cluster' })]
    expect(violations(nodes, groups)).toEqual([])
  })

  it('refuses two groups of the same tier, and names the machine', () => {
    // Membership is a rule rather than a list, so a node joins every group whose
    // rules it matches. Two rule-based harvest groups therefore both claim it
    // without anybody having said so.
    const nodes = [node('rotorua')]
    const groups = [group('overnight'), group('weekends')]
    const found = violations(nodes, groups)
    expect(found).toHaveLength(1)
    expect(found[0]!.rule).toBe('one-group-per-tier')
    expect(found[0]!.detail).toContain('rotorua')
    expect(found[0]!.detail).toContain('overnight')
    expect(found[0]!.detail).toContain('weekends')
  })

  it('says nothing about a machine in no group at all', () => {
    // Neither is a legitimate state, not an error: a machine nobody has claimed.
    const nodes = [node('spare', { tier: 'harvest' })]
    const groups = [group('serving', { tier: 'cluster' })]
    expect(violations(nodes, groups)).toEqual([])
  })
})

describe('groups that share a machine agree on what it serves', () => {
  it('allows two groups serving the same model', () => {
    const nodes = [node('rotorua')]
    const groups = [
      group('overnight', { servingModelId: 'qwen3-30b' }),
      group('serving', { tier: 'cluster', servingModelId: 'qwen3-30b' }),
    ]
    expect(violations(nodes, groups)).toEqual([])
  })

  it('refuses a disagreement, naming the machine and both claims', () => {
    // A machine loads one model. Without this nothing decides which group wins,
    // and the fleet cannot answer why a machine is not serving what it was
    // assigned.
    const nodes = [node('rotorua')]
    const groups = [
      group('overnight', { servingModelId: 'qwen3-30b' }),
      group('serving', { tier: 'cluster', servingModelId: 'coder-32b' }),
    ]
    const found = violations(nodes, groups)
    expect(found).toHaveLength(1)
    expect(found[0]!.rule).toBe('groups-must-agree')
    expect(found[0]!.detail).toContain('rotorua')
    expect(found[0]!.detail).toContain('qwen3-30b')
    expect(found[0]!.detail).toContain('coder-32b')
  })

  it('lets a group that names no model sit beside one that does', () => {
    // Otherwise the order an operator does two legitimate things in decides
    // whether they are allowed to, which is a rule nobody can hold in their head.
    const nodes = [node('rotorua')]
    const groups = [
      group('overnight'),
      group('serving', { tier: 'cluster', servingModelId: 'qwen3-30b' }),
    ]
    expect(violations(nodes, groups)).toEqual([])
  })

  it('reports one machine once, not once per direction', () => {
    const nodes = [node('rotorua')]
    const groups = [
      group('a', { servingModelId: 'x' }),
      group('b', { tier: 'cluster', servingModelId: 'y' }),
    ]
    expect(violations(nodes, groups).filter((v) => v.rule === 'groups-must-agree'))
      .toHaveLength(1)
  })

  it('names every machine that is affected, not just the first', () => {
    const nodes = [node('rotorua'), node('orca')]
    const groups = [
      group('a', { servingModelId: 'x' }),
      group('b', { tier: 'cluster', servingModelId: 'y' }),
    ]
    const detail = violations(nodes, groups).map((v) => v.detail).join(' ')
    expect(detail).toContain('rotorua')
    expect(detail).toContain('orca')
  })
})

describe('which groups are coupled to which', () => {
  it('finds a group forced to agree through a machine it does not share', () => {
    // The transitive consequence. cluster-1 touches both harvest groups, so
    // harvest-1 and harvest-2 are forced to agree with each other though they
    // share no machine and nobody said so.
    const a = node('a', { hostname: 'a' })
    const b = node('b', { hostname: 'b' })
    const cluster = group('cluster-1', { tier: 'cluster' })
    const h1 = group('harvest-1', { membership: { hostnames: ['a'] } })
    const h2 = group('harvest-2', { membership: { hostnames: ['b'] } })

    const coupled = coupledWith(h1, [a, b], [cluster, h1, h2]).map((g) => g.name)
    expect(coupled).toContain('cluster-1')
    expect(coupled).toContain('harvest-2')
  })

  it('leaves a group sharing no machine uncoupled', () => {
    const a = node('a', { hostname: 'a' })
    const h1 = group('harvest-1', { membership: { hostnames: ['a'] } })
    const h2 = group('harvest-2', { membership: { hostnames: ['nobody'] } })
    expect(coupledWith(h1, [a], [h1, h2])).toEqual([])
  })
})

describe('reading which groups a machine is in', () => {
  it('groups them by tier', () => {
    const byTier = groupsFor(node('rotorua'), [
      group('overnight'),
      group('serving', { tier: 'cluster' }),
    ])
    expect(byTier.get('harvest')?.map((g) => g.name)).toEqual(['overnight'])
    expect(byTier.get('cluster')?.map((g) => g.name)).toEqual(['serving'])
  })
})
