import { describe, expect, it } from 'vitest'
import { DEFAULT_IDLE_UNLOAD_SECONDS, effectiveServing, type Group }
  from '../src/lib/groupRules.js'

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
      .toEqual({ model: '30B', keepLoaded: false, machines: 1, idleUnloadSeconds: 300,
         groupId: 'g-Cluster' })
  })

  it('a cluster machine holds its model loaded', () => {
    expect(effectiveServing(node, [cluster]))
      .toEqual({ model: '32B', keepLoaded: true, machines: 1, idleUnloadSeconds: null,
         groupId: 'g-split-cluster' })
  })

  it('cluster preempts harvest where a machine is in both', () => {
    // A split rank cannot be preempted and harvest membership is the promise
    // that a machine can be taken away. Only one survives contact with one
    // machine, and it is the split.
    expect(effectiveServing(node, [harvest, cluster]))
      .toEqual({ model: '32B', keepLoaded: true, machines: 1, idleUnloadSeconds: null,
         groupId: 'g-split-cluster' })
  })

  it('hands the machine back when the cluster group is stood down', () => {
    // The whole lifecycle in one assertion: disable the split and the harvest
    // group's model applies again, lazily, as though the split had never been.
    expect(effectiveServing(node, [harvest, { ...cluster, enabled: false }]))
      .toEqual({ model: '30B', keepLoaded: false, machines: 1, idleUnloadSeconds: 300,
         groupId: 'g-Cluster' })
  })

  it('says nothing when no enabled group names a model', () => {
    // Which the node reads as "keep what you have" unless what it holds was
    // adopted - the machine decides that, not the control plane.
    expect(effectiveServing(node, [{ ...harvest, servingModelId: null }]))
      .toEqual({ model: null, keepLoaded: false, machines: 1, idleUnloadSeconds: null,
         groupId: null })
    expect(effectiveServing(node, []))
      .toEqual({ model: null, keepLoaded: false, machines: 1, idleUnloadSeconds: null,
         groupId: null })
  })

  it('a disabled cluster group does not keep anything warm', () => {
    expect(effectiveServing(node, [{ ...cluster, enabled: false }]))
      .toEqual({ model: null, keepLoaded: false, machines: 1, idleUnloadSeconds: null,
         groupId: null })
  })
})


/**
 * How wide the model is, sent because the node cannot work it out.
 *
 * Warming a model that runs across machines by loading the whole thing is worse
 * than not warming: it holds roughly twice what the share needs, and the warm
 * copy is never used - the split path builds its own model with
 * num_hidden_layers cut to this rank's range from the same weights.
 */
describe('how wide the model is', () => {
  const harvest = group({ name: 'Cluster', tier: 'harvest', servingModelId: '30B' })
  const cluster = group({ name: 'split-cluster', tier: 'cluster', servingModelId: '32B' })
  const widths = (id: string) => ({ '32B': 2, '30B': 1 } as Record<string, number>)[id] ?? 1

  it('reports the declared width of the model that won', () => {
    expect(effectiveServing(node, [cluster], widths).machines).toBe(2)
    expect(effectiveServing(node, [harvest], widths).machines).toBe(1)
  })

  it('is the winning group\'s model, not any model on the machine', () => {
    // Cluster preempts harvest, so the width follows the same winner as the
    // model does. Reporting the harvest group's width beside the cluster
    // group's model is how a node would warm the wrong thing correctly.
    expect(effectiveServing(node, [harvest, cluster], widths))
      .toEqual({ model: '32B', keepLoaded: true, machines: 2, idleUnloadSeconds: null,
         groupId: 'g-split-cluster' })
  })

  it('is 1 when nothing is being served', () => {
    expect(effectiveServing(node, [], widths).machines).toBe(1)
  })

  it('is 1 when nobody supplied widths, so an old caller is unchanged', () => {
    // The lookup is optional: a caller that has not been taught about widths
    // gets the behaviour it had, which is whole models only.
    expect(effectiveServing(node, [cluster]).machines).toBe(1)
  })

  it('never reports less than one machine', () => {
    expect(effectiveServing(node, [cluster], () => 0).machines).toBe(1)
    expect(effectiveServing(node, [cluster], () => -2).machines).toBe(1)
  })
})


/**
 * How long a machine holds a model when nothing is being asked of it.
 *
 * The presence policy already covered "somebody wants their machine back".
 * Nothing covered "nobody wants anything", so a harvest machine that answered
 * one request held gigabytes until its owner returned.
 */
describe('how long to hold when nothing is being asked', () => {
  const harvest = group({ name: 'Cluster', tier: 'harvest', servingModelId: '30B' })
  const cluster = group({ name: 'split-cluster', tier: 'cluster', servingModelId: '32B' })

  it('gives a harvest group the fleet default when it has not chosen', () => {
    expect(effectiveServing(node, [harvest]).idleUnloadSeconds)
      .toBe(DEFAULT_IDLE_UNLOAD_SECONDS)
  })

  it('lets a group choose its own', () => {
    // An overnight batch pool and a daytime ad-hoc pool want different answers,
    // which is why this lives on the group beside every other decision of the
    // same kind.
    expect(effectiveServing(node, [{ ...harvest, idleUnloadSeconds: 60 }])
      .idleUnloadSeconds).toBe(60)
  })

  it('sends a dedicated group no window at all', () => {
    // Not a very long one. A number somebody can see is a number somebody
    // eventually sets short, and a split that unloads between requests rebuilds
    // its share every time.
    expect(effectiveServing(node, [cluster]).idleUnloadSeconds).toBeNull()
    expect(effectiveServing(node, [{ ...cluster, idleUnloadSeconds: 30 }])
      .idleUnloadSeconds).toBeNull()
  })

  it('follows the same winner as the model does', () => {
    // Cluster preempts harvest. A machine holding the cluster group's model on
    // the harvest group's window would release the split's share underneath it.
    expect(effectiveServing(node, [{ ...harvest, idleUnloadSeconds: 60 }, cluster])
      .idleUnloadSeconds).toBeNull()
  })

  it('gives a machine no window when nothing is served', () => {
    expect(effectiveServing(node, []).idleUnloadSeconds).toBeNull()
  })

  it('hands the window back once the cluster group stands down', () => {
    // The whole lifecycle: the machine is handed back and becomes an ordinary
    // harvest machine again, window and all.
    expect(effectiveServing(node, [harvest, { ...cluster, enabled: false }])
      .idleUnloadSeconds).toBe(DEFAULT_IDLE_UNLOAD_SECONDS)
  })

  it('defaults to five minutes, which protects the prompt cache', () => {
    // Unloading clears the prompt cache with the weights, and that is the
    // expensive half - releasing too eagerly once turned a 0.5s warm request
    // into 37.5s. Five minutes covers an agentic client whose turns are seconds
    // apart with room to spare.
    expect(DEFAULT_IDLE_UNLOAD_SECONDS).toBe(300)
  })
})
