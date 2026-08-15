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
