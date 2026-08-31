import { describe, expect, it } from 'vitest'
import { servingWidth, RUNTIME_HEADROOM, runnability, shapeOf, whyGroupCannotHost } from '../src/lib/shape.js'

/**
 * What a model needs, and whether a group can give it.
 *
 * Answered at assignment. The alternative is discovering it at dispatch, as a
 * request that hangs, by whoever happens to send one weeks later.
 */

// E7's 72B: 4-bit weights, 41.10 GB resident on one machine, 21.31 GB on each
// of two. The numbers below are that model unless said otherwise.
const GIB = 1073741824
const SEVENTY_TWO_B = Math.round(40.4 * GIB)

describe('what a model needs', () => {
  it('defaults to one machine', () => {
    // Everything that fits is a model that needs one machine, and most models
    // fit. The split is the exception and has to be declared.
    expect(shapeOf({ size_bytes: SEVENTY_TWO_B }).machines).toBe(1)
  })

  it('divides the weights across the machines it declares', () => {
    // Which is what pipelining does: each machine loads its own layers.
    const one = shapeOf({ size_bytes: SEVENTY_TWO_B })
    const two = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2 })
    expect(two.perMachineGb).toBeCloseTo(one.perMachineGb / 2, 1)
  })

  it('lands near what E7 actually measured', () => {
    // 21.31 GB each, measured. A derived figure that missed by a lot would put
    // models on machines that cannot load them, or refuse machines that can.
    const two = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2 })
    expect(two.perMachineGb).toBeGreaterThan(21)
    expect(two.perMachineGb).toBeLessThan(24)
  })

  it('leaves room for what the runtime needs beyond the weights', () => {
    const gib = SEVENTY_TWO_B / GIB
    expect(shapeOf({ size_bytes: SEVENTY_TWO_B }).perMachineGb)
      .toBeCloseTo(gib * RUNTIME_HEADROOM, 1)
  })

  it('prefers a measured figure over a derived one', () => {
    // Derivation is a rule of thumb. Somebody who has run the model knows
    // better, and should be able to say so.
    expect(shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2, min_memory_gb: 19.5 })
      .perMachineGb).toBe(19.5)
  })

  it('ignores a declared figure that says nothing', () => {
    for (const bad of [0, -1, null, undefined]) {
      const s = shapeOf({ size_bytes: SEVENTY_TWO_B, min_memory_gb: bad as never })
      expect(s.perMachineGb).toBeGreaterThan(1)
    }
  })
})

describe('whether a group can run it', () => {
  const m = (hostname: string, gb: number | null) => ({ hostname, metalWorkingSetGb: gb })

  it('accepts a group with enough machines, each big enough', () => {
    const shape = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2 })
    expect(whyGroupCannotHost([m('rotorua', 51.8), m('orca', 37.4)], shape)).toBeNull()
  })

  it('says how many machines are short, not just no', () => {
    const shape = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2 })
    const why = whyGroupCannotHost([m('rotorua', 51.8)], shape)
    expect(why).toContain('needs 2 machines')
    expect(why).toContain('has 1')
  })

  it('names the machines that are too small', () => {
    // An operator told "cannot host" learns nothing. One told which machine and
    // how much it has knows whether to move a machine or split further.
    // Enough machines by count, not enough by size: the group has two, the
    // model needs two, and only one of them can load a rank.
    const shape = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2 })
    const why = whyGroupCannotHost([m('rotorua', 51.8), m('mini', 8)], shape)
    expect(why).toContain('mini')
    expect(why).toContain('8.0 GB')
    expect(why).toContain('only 1 qualify')
  })

  it('fails a machine whose working set was never probed', () => {
    // Guessing upward puts a model on a machine that cannot load it, and the
    // symptom arrives after the transfer rather than before it.
    const shape = shapeOf({ size_bytes: SEVENTY_TWO_B })
    const why = whyGroupCannotHost([m('unknown', null)], shape)
    expect(why).toContain('unknown working set')
  })

  it('lets a split model onto machines that could not hold it whole', () => {
    // The entire point. Neither machine can load 44 GB; both can load 22.
    const whole = shapeOf({ size_bytes: SEVENTY_TWO_B })
    const split = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2 })
    const pair = [m('a', 37.4), m('b', 37.4)]
    expect(whyGroupCannotHost(pair, whole)).not.toBeNull()
    expect(whyGroupCannotHost(pair, split)).toBeNull()
  })
})

/**
 * Now, later, or not as things stand.
 *
 * Three answers rather than two, because "cannot" and "not yet" call for
 * different actions and look identical from a boolean. Reporting both as no is
 * how somebody waits for what is not coming, or reassigns what was about to
 * work.
 */
describe('whether a group can run it now', () => {
  const m = (hostname: string, gb: number | null, holds = true) =>
    ({ hostname, metalWorkingSetGb: gb, holds })

  it('is ready when enough big machines hold the weights', () => {
    const shape = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2 })
    expect(runnability([m('rotorua', 51.8), m('orca', 37.4)], shape))
      .toEqual({ state: 'ready' })
  })

  it('is pending while a transfer is still running', () => {
    // Nothing to do but wait. Distinguishing this from blocked is the point:
    // the group is correct and the bytes are on their way.
    const shape = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2 })
    const got = runnability([m('rotorua', 51.8), m('orca', 37.4, false)], shape)
    expect(got.state).toBe('pending')
    expect((got as { detail: string }).detail).toContain('1 of 2')
  })

  it('is blocked when the machines could never load it', () => {
    // However long anybody waits. Somebody has to change the group, or the
    // model's shape.
    const shape = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2 })
    const got = runnability([m('rotorua', 51.8), m('mini', 8)], shape)
    expect(got.state).toBe('blocked')
    expect((got as { detail: string }).detail).toContain('mini')
  })

  it('prefers blocked over pending when both are true', () => {
    // A group that is too small and also has not fetched the weights is not
    // waiting for anything. Saying pending would send somebody away to wait.
    const shape = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 2 })
    expect(runnability([m('mini', 8, false), m('mini2', 8, false)], shape).state)
      .toBe('blocked')
  })

  it('does not count a machine that holds the weights but cannot load them', () => {
    // Holding is disk and loading is memory. A machine with the bytes and no
    // room for them contributes nothing to whether the group can run it.
    const shape = shapeOf({ size_bytes: SEVENTY_TWO_B, machines: 1 })
    expect(runnability([m('mini', 8, true), m('rotorua', 51.8, false)], shape).state)
      .toBe('pending')
  })
})

/**
 * How wide a group runs a model, against how wide the model can run at all.
 *
 * The two were one column, so a model had a single shape fleet-wide and testing
 * a split with an 8.3 GB model left it requiring two machines for every caller
 * afterwards. A group can now choose, within what the weights allow.
 */
describe('serving width', () => {
  it('uses the model minimum when the group has not chosen', () => {
    expect(servingWidth({ modelMinimum: 1, groupWants: null }).machines).toBe(1)
    expect(servingWidth({ modelMinimum: 2, groupWants: null }).machines).toBe(2)
  })

  /** The case this exists for: one model, two deployments. */
  it('lets one group split a model another runs whole', () => {
    expect(servingWidth({ modelMinimum: 1, groupWants: 2 }).machines).toBe(2)
    expect(servingWidth({ modelMinimum: 1, groupWants: 1 }).machines).toBe(1)
  })

  /**
   * Wider is a choice; narrower is a model that will not fit. Refused here
   * rather than discovered when a machine tries to load it.
   */
  it('refuses a group that asks for fewer machines than the model needs', () => {
    const r = servingWidth({ modelMinimum: 2, groupWants: 1 })
    expect(r.refused).toContain('at least 2')
    expect(r.machines).toBe(2)
  })

  it('treats nonsense as unset rather than as zero machines', () => {
    expect(servingWidth({ modelMinimum: 2, groupWants: 0 }).machines).toBe(2)
    expect(servingWidth({ modelMinimum: 1, groupWants: -3 }).machines).toBe(1)
    expect(servingWidth({ modelMinimum: 1, groupWants: NaN }).machines).toBe(1)
  })
})
