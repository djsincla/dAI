import { describe, expect, it } from 'vitest'
import { RUNTIME_HEADROOM, shapeOf, whyGroupCannotHost } from '../src/lib/shape.js'

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
