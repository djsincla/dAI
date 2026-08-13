import { describe, expect, it } from 'vitest'
import { coupledWith, effectiveModel, groupsFor, overrides, violations,
         type Group } from '../src/lib/groupRules.js'
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

describe('when a machine\'s groups disagree about what it runs', () => {
  it('lets the cluster group win rather than refusing the pair', () => {
    // The two tiers are not equal claims. A cluster group promises never to be
    // preempted and is the only place a split can run; a harvest group promises
    // that the machine may be taken away. Only one of those survives contact
    // with a single machine, and it is not the harvest one.
    const nodes = [node('rotorua')]
    const groups = [
      group('overnight', { servingModelId: 'qwen3-30b' }),
      group('serving', { tier: 'cluster', servingModelId: 'coder-32b' }),
    ]
    expect(violations(nodes, groups)).toEqual([])
    expect(effectiveModel(nodes[0]!, groups)).toBe('coder-32b')
  })

  it('follows the harvest group when there is no cluster group to override it', () => {
    const nodes = [node('rotorua')]
    const groups = [group('overnight', { servingModelId: 'qwen3-30b' })]
    expect(effectiveModel(nodes[0]!, groups)).toBe('qwen3-30b')
  })

  it('says nobody has said, rather than serve nothing', () => {
    // Null is not an instruction to unload. A group that has not been given a
    // model is not a claim about anything.
    const nodes = [node('rotorua')]
    expect(effectiveModel(nodes[0]!, [group('overnight')])).toBe(null)
  })

  it('still refuses a disagreement nothing can resolve', () => {
    // Two groups of the same tier have no ordering between them, so there is
    // nothing to prefer. One-group-per-tier already makes this unreachable;
    // this is the check that would catch it if that rule were relaxed.
    const nodes = [node('rotorua')]
    const groups = [
      group('a', { servingModelId: 'x' }),
      group('b', { servingModelId: 'y' }),
    ]
    const found = violations(nodes, groups).filter((v) => v.rule === 'groups-must-agree')
    expect(found).toHaveLength(1)
    expect(found[0]!.detail).toContain('rotorua')
  })
})

describe('which harvest groups are being overridden', () => {
  it('names the machine, the group, and what it runs instead', () => {
    // Not a fault - it is the rule working - but a harvest group whose machines
    // all run somebody else's model is a group whose own declaration means
    // nothing at the moment, and reading it would be reading something untrue.
    const nodes = [node('rotorua')]
    const groups = [
      group('overnight', { servingModelId: 'qwen3-30b' }),
      group('serving', { tier: 'cluster', servingModelId: 'coder-32b' }),
    ]
    const found = overrides(nodes, groups)
    expect(found).toHaveLength(1)
    expect(found[0]).toMatchObject({
      hostname: 'rotorua', harvest: 'overnight',
      runs: 'coder-32b', insteadOf: 'qwen3-30b', by: 'serving',
    })
  })

  it('says nothing when the two agree', () => {
    const nodes = [node('rotorua')]
    const groups = [
      group('overnight', { servingModelId: 'same' }),
      group('serving', { tier: 'cluster', servingModelId: 'same' }),
    ]
    expect(overrides(nodes, groups)).toEqual([])
  })

  it('says nothing when the harvest group has named nothing', () => {
    // Nothing is being overridden: the group has made no claim to lose.
    const nodes = [node('rotorua')]
    const groups = [
      group('overnight'),
      group('serving', { tier: 'cluster', servingModelId: 'coder-32b' }),
    ]
    expect(overrides(nodes, groups)).toEqual([])
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
