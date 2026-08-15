import { describe, expect, it } from 'vitest'
import { effectiveServing, type Group } from '../src/lib/groupRules.js'

const node = { id: 'n1', hostname: 'orca', tier: 'cluster',
               chip: 'Apple M4 Pro', memory_gb: 48 } as never

const group = (over: Partial<Group>): Group => ({
  id: `g-${over.name}`, name: over.name ?? 'g', tier: 'harvest',
  membership: {}, servingModelId: null, enabled: true, ...over,
})

/**
 * What a machine serves, and whether it holds it in memory.
 *
 * These came from one decision and were returned as one answer, so every
 * machine loaded lazily - right for harvest and wrong for a cluster. A split
 * cannot begin until every rank has built its share, so a cold gang pays the
 * slowest machine's load before the first token and pays it again whenever the
 * group falls idle.
 */
describe('what a machine serves', () => {
  const harvest = group({ name: 'Cluster', tier: 'harvest', servingModelId: '30B' })
  const cluster = group({ name: 'split-cluster', tier: 'cluster', servingModelId: '32B' })

  it('a harvest machine loads on demand', () => {
    // Somebody is sitting at it. Holding gigabytes for a request that may not
    // come today is what the presence policy exists to prevent.
    expect(effectiveServing(node, [harvest]))
      .toEqual({ model: '30B', keepLoaded: false })
  })

  it('a cluster machine holds its model loaded', () => {
    expect(effectiveServing(node, [cluster]))
      .toEqual({ model: '32B', keepLoaded: true })
  })

  it('cluster preempts harvest where a machine is in both', () => {
    // A split rank cannot be preempted and harvest membership is the promise
    // that a machine can be taken away. Only one survives contact with one
    // machine, and it is the split.
    expect(effectiveServing(node, [harvest, cluster]))
      .toEqual({ model: '32B', keepLoaded: true })
  })

  it('hands the machine back when the cluster group is stood down', () => {
    // The whole lifecycle in one assertion: disable the split and the harvest
    // group's model applies again, lazily, as though the split had never been.
    expect(effectiveServing(node, [harvest, { ...cluster, enabled: false }]))
      .toEqual({ model: '30B', keepLoaded: false })
  })

  it('says nothing when no enabled group names a model', () => {
    // Which the node reads as "keep what you have" unless what it holds was
    // adopted - the machine decides that, not the control plane.
    expect(effectiveServing(node, [{ ...harvest, servingModelId: null }]))
      .toEqual({ model: null, keepLoaded: false })
    expect(effectiveServing(node, [])).toEqual({ model: null, keepLoaded: false })
  })

  it('a disabled cluster group does not keep anything warm', () => {
    expect(effectiveServing(node, [{ ...cluster, enabled: false }]))
      .toEqual({ model: null, keepLoaded: false })
  })
})
