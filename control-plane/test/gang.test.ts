import { describe, expect, it } from 'vitest'
import { isRefusal, selectGang, type Candidate, type Refusal } from '../src/lib/router.js'

/**
 * Admitting a whole gang, or none of it.
 *
 * A split model runs across N machines in lockstep. Half a pipeline is not a
 * slower answer - it is a request that hangs while holding memory on machines
 * that could have been doing something else.
 */

const node = (id: string, over: Partial<Candidate> = {}): Candidate => ({
  id,
  hostname: id,
  tier: 'cluster',
  group_id: 'cluster-1',
  presence_state: 'ABSENT',
  resident_models: {},
  capability_profiles: {},
  in_flight: 0,
  ...over,
})

const refusal = (x: Candidate[] | Refusal): Refusal => {
  expect(Array.isArray(x)).toBe(false)
  return x as Refusal
}

describe('assembling a gang', () => {
  it('returns every rank when a group can field them', () => {
    const got = selectGang([node('a'), node('b')], 'generate', null, 2)
    expect(Array.isArray(got)).toBe(true)
    expect((got as Candidate[]).map((c) => c.id).sort()).toEqual(['a', 'b'])
  })

  it('refuses rather than returning a partial gang', () => {
    // The failure this exists to prevent. One rank is not a smaller pipeline.
    const got = refusal(selectGang([node('a')], 'generate', null, 2))
    expect(got.refused).toBe('gang-short')
    expect(got.detail).toContain('needs 2 machines')
    expect(got.detail).toContain('has 1')
  })

  it('will not build a gang from harvest machines', () => {
    // Never-preempted is what the work depends on. One rank yielding because
    // somebody touched a keyboard takes the whole job down with it.
    const got = refusal(selectGang(
      [node('a', { tier: 'harvest' }), node('b', { tier: 'harvest' })],
      'generate', null, 2))
    expect(got.refused).toBe('gang-not-cluster')
    expect(got.detail).toContain('never')
  })

  it('will not span two groups', () => {
    // Machines in a group agree about what they serve. Machines in different
    // groups have not been said to agree about anything, so a gang across them
    // could be handed ranks of models that are not the same model.
    const got = refusal(selectGang(
      [node('a', { group_id: 'cluster-1' }), node('b', { group_id: 'cluster-2' })],
      'generate', null, 2))
    expect(got.refused).toBe('gang-short')
  })

  it('does not pool machines that belong to no group', () => {
    // Two ungrouped machines have not been declared to agree either, and
    // treating absence of a group as a shared one is how a gang gets assembled
    // from machines nobody put together.
    const got = refusal(selectGang(
      [node('a', { group_id: null }), node('b', { group_id: null })],
      'generate', null, 2))
    expect(got.refused).toBe('gang-short')
  })

  it('prefers the group that already holds the weights', () => {
    // N cold loads is N times the delay, not one, so residency counts for more
    // in a gang than it does for a single node.
    const cold = [node('c1', { group_id: 'cold' }), node('c2', { group_id: 'cold' })]
    const warm = [
      node('w1', { group_id: 'warm', resident_models: { m1: 20 } }),
      node('w2', { group_id: 'warm', resident_models: { m1: 20 } }),
    ]
    const got = selectGang([...cold, ...warm], 'generate', 'm1', 2) as Candidate[]
    expect(got.map((c) => c.group_id)).toEqual(['warm', 'warm'])
  })

  it('takes the least loaded machines within the group', () => {
    // A pipeline runs at the speed of its slowest rank, so the gang is built
    // from the machines least likely to make the rest of it wait.
    const got = selectGang([
      node('busy', { in_flight: 3 }),
      node('free', { in_flight: 0 }),
      node('some', { in_flight: 1 }),
    ], 'generate', null, 2) as Candidate[]
    expect(got.map((c) => c.id)).toEqual(['free', 'some'])
  })

  it('falls back to ordinary selection for a model that needs one machine', () => {
    // size 1 is not a gang, and routing it through the gang path would refuse
    // every harvest node for a model that never needed a cluster.
    const got = selectGang([node('a', { tier: 'harvest' })], 'generate', null, 1)
    expect(Array.isArray(got)).toBe(true)
    expect((got as Candidate[])[0]!.id).toBe('a')
  })

  it('says so when nothing is connected at all', () => {
    expect(refusal(selectGang([], 'generate', null, 2)).refused).toBe('no-nodes')
  })
})
