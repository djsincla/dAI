import { describe, expect, it } from 'vitest'
import { splitReadiness, type RankFacts } from '../src/lib/splitReadiness.js'

const MODEL = 'mlx-community/Qwen2.5-Coder-32B-Instruct-4bit'

const machine = (hostname: string, over: Partial<RankFacts> = {}): RankFacts => ({
  nodeId: `id-${hostname}`, hostname,
  connected: true, assigned: MODEL, onDisk: [MODEL], loaded: [MODEL],
  pipelineAddress: '192.168.99.1', syncFault: null, ...over,
})

const group = (members: RankFacts[], over = {}) =>
  splitReadiness({ enabled: true, model: MODEL, machines: 2, members, ...over })

/**
 * Standing a split up meant enabling the group and then waiting with nothing to
 * look at, while ~18 GB reached both machines. The first sign it was not ready
 * came from sending a request and reading the refusal - a diagnostic disguised
 * as a failure, arriving minutes after an operator could have acted on it.
 */
describe('whether a split could serve a request right now', () => {
  it('is ready when both machines hold it and can reach each other', () => {
    const out = group([machine('orca'), machine('rotorua', { pipelineAddress: '192.168.99.2' })])
    expect(out.state).toBe('ready')
    expect(out.ranks.map((r) => r.rank)).toEqual([0, 1])
  })

  it('assigns the output head to a machine that can be dialled', () => {
    // The same rule the router applies. A readiness view that disagrees with
    // the router is worse than none, because it is believed.
    const out = group([
      machine('rotorua', { pipelineAddress: null }),
      machine('orca'),
    ])
    expect(out.ranks[0]!.hostname).toBe('orca')
    expect(out.ranks[0]!.role).toBe('output head')
    expect(out.ranks[1]!.role).toBe('feeds the next rank')
  })
})

describe('what is missing, and whether anybody has to act', () => {
  it('is preparing while weights are still arriving', () => {
    // Resolves on its own. The operator waits.
    const out = group([machine('orca'), machine('rotorua', { onDisk: [], loaded: [] })])
    expect(out.state).toBe('preparing')
    expect(out.detail).toContain('fetching the weights')
  })

  it('is preparing while a machine builds its share', () => {
    const out = group([machine('orca'), machine('rotorua', { loaded: [] })])
    expect(out.state).toBe('preparing')
    expect(out.detail).toContain('not built yet')
  })

  it('is blocked when a machine cannot be reached', () => {
    // Somebody has to go and look. Distinct from preparing, and the distinction
    // is the difference between waiting and walking to a machine.
    const out = group([machine('orca'), machine('rotorua', { connected: false })])
    expect(out.state).toBe('blocked')
  })

  it('is blocked when the link is down, and names the setting', () => {
    // bridge0 stays up with no address when the cable comes out, so every naive
    // check passes and the group simply never forms.
    const out = group([
      machine('orca', { pipelineAddress: null }),
      machine('rotorua', { pipelineAddress: null }),
    ])
    expect(out.state).toBe('blocked')
    expect(out.detail + JSON.stringify(out.ranks)).toContain('DAI_PIPELINE_INTERFACE')
    expect(out.ranks.every((r) => r.rank === null)).toBe(true)
  })

  it('is blocked when the group is short a machine', () => {
    const out = group([machine('orca')])
    expect(out.state).toBe('blocked')
    expect(out.detail).toContain('all at once or not at all')
  })

  it('reports a sync fault rather than guessing from a missing file', () => {
    const out = group([machine('orca'),
                       machine('rotorua', { syncFault: 'disk full' })])
    expect(out.state).toBe('blocked')
    expect(out.detail).toContain('disk full')
  })

  it('says a machine has not been told to hold it yet', () => {
    // Different from fetching: nothing is on its way.
    const out = group([machine('orca'),
                       machine('rotorua', { assigned: null, onDisk: [], loaded: [] })])
    expect(out.detail).toContain('not been told')
  })
})

describe('a group nobody is asking anything of', () => {
  it('is idle when stood down, not broken', () => {
    // Reporting an operator's own decision as a fault teaches them to ignore it.
    const out = group([machine('orca')], { enabled: false })
    expect(out.state).toBe('idle')
    expect(out.detail).toContain('stood down')
  })

  it('is idle when no model has been assigned', () => {
    const out = group([machine('orca')], { model: null })
    expect(out.state).toBe('idle')
  })
})


/**
 * A cluster group that is not split.
 *
 * Dedicated and loaded, every machine holding the whole model and able to answer
 * alone, which is an ordinary thing to want. The loading already works -
 * keepLoaded with machines 1 warms it. This view was written for splits and
 * applied to every cluster group, so it described a pipeline whether or not one
 * existed.
 */
describe('a dedicated group with nothing to dial', () => {
  const whole = (members: RankFacts[]) =>
    splitReadiness({ enabled: true, model: MODEL, machines: 1, members })

  it('is ready without any pipeline address, because there is no peer', () => {
    // The rule: an address only matters when there is somebody to dial. A
    // machine holding a whole model answers on its own.
    const out = whole([machine('orca', { pipelineAddress: null })])
    expect(out.state).toBe('ready')
  })

  it('names no ranks, because there is no pipeline to have a head of', () => {
    // "output head" and "feeds the next rank" describe a division. Printing
    // them for a machine holding the whole model is fiction.
    const out = whole([machine('orca'), machine('rotorua')])
    expect(out.ranks.every((r) => r.rank === null)).toBe(true)
    expect(out.ranks.every((r) => r.role === null)).toBe(true)
  })

  it('still reports what each machine is missing', () => {
    // The rest of the view is just as useful without a split: weights arriving,
    // a model not built yet, a machine that has gone away.
    const out = whole([machine('orca', { onDisk: [], loaded: [] })])
    expect(out.state).toBe('preparing')
    expect(out.detail).toContain('fetching')
  })

  it('is still blocked when a machine is unreachable', () => {
    const out = whole([machine('orca', { connected: false })])
    expect(out.state).toBe('blocked')
  })
})

/**
 * Whether the machines were ever told to hold the model.
 *
 * Serving a model and holding it are different tables: pools.serving_model_id
 * decides what a group's machines run, pool_models decides what they fetch.
 * Setting the first without the second leaves a group waiting forever with
 * nothing fetching anything - and this view could not say so, because the route
 * fed the check the same value it compared against.
 */
describe('told to hold it, or not', () => {
  it('separates fetching from never having been asked', () => {
    const fetching = group([machine('orca'),
                            machine('rotorua', { onDisk: [], loaded: [],
                                                 assigned: MODEL })])
    expect(fetching.detail).toContain('fetching the weights')

    const never = group([machine('orca'),
                         machine('rotorua', { onDisk: [], loaded: [],
                                              assigned: null })])
    expect(never.detail).toContain('not been told')
  })
})

/**
 * A group that names no model.
 *
 * It used to be reported idle - "no model assigned" - which read as a group
 * nobody had finished setting up. It now serves whichever staged model is asked
 * for, and that is a different question with a different answer: not "are the
 * shares built" but "what could be asked for, and would it be served".
 *
 * The difference that matters most is `loaded`. A dynamic group deliberately
 * warms nothing, so a machine holding weights with nothing built is ready.
 * Judged by the pinned rules it would report as perpetually loading, and an
 * operator would wait for something that is never going to happen.
 */
describe('a group that serves whichever model it is staged with', () => {
  const OTHER = 'mlx-community/Qwen3-30B-A3B-8bit'

  const dynamicGroup = (members: RankFacts[],
                        staged: { modelId: string; machines: number }[]) =>
    splitReadiness({ enabled: true, model: null, machines: 1, members, staged })

  const pair = (over: Partial<RankFacts> = {}) => [
    machine('orca', { assigned: null, ...over }),
    machine('rotorua', { assigned: null, pipelineAddress: '192.168.99.2', ...over }),
  ]

  it('is ready when the machines hold a staged model, built or not', () => {
    // Nothing is pre-warmed, by definition: there is nothing to warm until a
    // caller chooses. Holding weights and building nothing is the resting
    // state here, not a stage on the way to somewhere.
    const out = dynamicGroup(pair({ loaded: [] }), [{ modelId: MODEL, machines: 2 }])
    expect(out.state).toBe('ready')
    expect(out.ranks.every((r) => r.state === 'ready')).toBe(true)
  })

  it('says what it can be asked for, and what it cannot', () => {
    // The actual information. A staged model on fewer machines than it needs is
    // a request that will be refused, and this is where that gets said instead
    // of being discovered at dispatch.
    const members = [
      machine('orca', { assigned: null, onDisk: [MODEL, OTHER] }),
      machine('rotorua', { assigned: null, onDisk: [MODEL],
                           pipelineAddress: '192.168.99.2' }),
    ]
    const out = dynamicGroup(members, [
      { modelId: MODEL, machines: 2 }, { modelId: OTHER, machines: 2 },
    ])
    expect(out.staged).toEqual([
      { modelId: MODEL, machines: 2, held: 2, ready: true },
      { modelId: OTHER, machines: 2, held: 1, ready: false },
    ])
    expect(out.state).toBe('ready')
    expect(out.detail).toContain('1 still arriving')
  })

  it('warns that the first request pays the build', () => {
    // ~40 seconds on this fleet for both machines to build their shares of the
    // 32B with the weights already on disk. It is the trade for not committing
    // the machines, and it belongs where an operator reads about the group
    // rather than in the latency of a request they have already sent.
    const out = dynamicGroup(pair({ loaded: [] }), [{ modelId: MODEL, machines: 2 }])
    expect(out.detail).toContain('pays the build')
  })

  it('is preparing while no staged model is on enough machines', () => {
    // Resolves on its own - model sync is still working. Nobody has to act.
    const out = dynamicGroup(
      pair({ onDisk: [], loaded: [] }), [{ modelId: MODEL, machines: 2 }])
    expect(out.state).toBe('preparing')
  })

  it('is idle when it has been staged with nothing', () => {
    // Not blocked: the group is asserting nothing and nothing is broken. But it
    // can serve nothing either, and the detail has to say what to do about it.
    const out = dynamicGroup(pair(), [])
    expect(out.state).toBe('idle')
    expect(out.detail).toContain('nothing has been staged')
  })

  it('is blocked when a machine cannot be dialled for pipeline traffic', () => {
    // The same question the router asks, and usually a cable.
    const out = dynamicGroup(
      pair({ pipelineAddress: null }), [{ modelId: MODEL, machines: 2 }])
    expect(out.state).toBe('blocked')
  })

  it('needs no peer address when nothing staged is split', () => {
    // A group of workstations each holding a whole model. Reporting it
    // unreachable would describe a link it will never use.
    const out = dynamicGroup(
      pair({ pipelineAddress: null, onDisk: [OTHER], loaded: [] }),
      [{ modelId: OTHER, machines: 1 }])
    expect(out.state).toBe('ready')
    expect(out.ranks.every((r) => r.rank === null)).toBe(true)
  })

  it('is blocked when it is too small for the widest thing staged to it', () => {
    // Two machines staged with a three-machine model can never serve it, and
    // no amount of waiting changes that.
    const out = dynamicGroup(pair(), [{ modelId: MODEL, machines: 3 }])
    expect(out.state).toBe('blocked')
    expect(out.detail).toContain('needs 3 machines')
  })

  it('assigns ranks before anything has been asked for', () => {
    // Ranks come from addresses, not from the model, so they can be settled
    // while the group sits waiting - which is the state it is normally in.
    const out = dynamicGroup(pair(), [{ modelId: MODEL, machines: 2 }])
    expect(out.ranks.map((r) => r.rank)).toEqual([0, 1])
    expect(out.ranks[0]!.role).toBe('output head')
  })

  it('is stood down rather than dynamic when it is not standing', () => {
    const out = splitReadiness({ enabled: false, model: null, machines: 1,
      members: pair(), staged: [{ modelId: MODEL, machines: 2 }] })
    expect(out.state).toBe('idle')
    expect(out.detail).toContain('stood down')
  })

  it('leaves a pinned group judged against its own model', () => {
    // Staging is not consulted for a group that named a model. It asserts one
    // thing and is measured against it.
    const out = splitReadiness({ enabled: true, model: MODEL, machines: 2,
      members: [machine('orca'), machine('rotorua', { pipelineAddress: '192.168.99.2' })],
      staged: [{ modelId: OTHER, machines: 2 }] })
    expect(out.state).toBe('ready')
    expect(out.model).toBe(MODEL)
    expect(out.staged).toEqual([])
  })
})
