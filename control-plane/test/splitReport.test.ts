import { describe, expect, it } from 'vitest'
import { parseLayerPlan, splitReport, type GangMember } from '../src/lib/splitReport.js'

const gang = (n: number): GangMember[] =>
  Array.from({ length: n }, (_, rank) => ({
    nodeId: `id-${rank}`, hostname: rank === 0 ? 'orca' : `node-${rank}`,
    rank, address: '192.168.99.1',
  }))

/**
 * The instrumentation that did not exist.
 *
 * The control plane assembled a gang, assigned ranks, picked rank 0 to answer,
 * and then returned the same `dai` block a single-machine completion returns.
 * A split answer and an ordinary one were identical to the caller, so the only
 * way to confirm a split had run was to ssh to both machines and read the agent
 * log.
 */
describe('evidence that more than one machine served a request', () => {
  it('says nothing at all when nothing was split', () => {
    // Absent, not `split: false`. Every ordinary completion this fleet has ever
    // served would otherwise carry a field denying something, and a caller
    // writing `if (dai.split)` reads both the same way.
    expect(splitReport(null, null)).toBeUndefined()
    expect(splitReport([], null)).toBeUndefined()
    expect(splitReport(gang(1), null)).toBeUndefined()
  })

  it('names the machines that actually served it', () => {
    const out = splitReport(gang(2), [[24, 48], [0, 24]])!
    expect(out.machines).toBe(2)
    expect(out.ranks.map((r) => r.hostname)).toEqual(['orca', 'node-1'])
  })

  it('says what each rank was for rather than leaving it to be inferred', () => {
    // Ranks are numbered in reverse and rank 0 holds the output head. Nobody
    // reading a completion should have to know that to understand the answer.
    const out = splitReport(gang(2), [[24, 48], [0, 24]])!
    expect(out.ranks.find((r) => r.rank === 0)!.role).toBe('output head')
    expect(out.ranks.find((r) => r.rank === 1)!.role).toBe('feeds the next rank')
  })

  it('carries the layer ranges, which are the actual proof', () => {
    // Two hostnames prove two machines were sent work. Layer ranges prove
    // neither of them held the whole model, which is the claim being checked.
    const out = splitReport(gang(2), [[24, 48], [0, 24]])!
    expect(out.layersReported).toBe(true)
    expect(out.ranks.find((r) => r.rank === 0)!.layers).toEqual([24, 48])
    expect(out.ranks.find((r) => r.rank === 1)!.layers).toEqual([0, 24])
  })

  it('still reports the machines when the agent is too old to send layers', () => {
    // The machine most in need of upgrading must not be the one that reports
    // nothing at all, and "which two machines" is worth having on its own.
    const out = splitReport(gang(2), undefined)!
    expect(out.machines).toBe(2)
    expect(out.layersReported).toBe(false)
    expect(out.ranks[0]!.layers).toBeUndefined()
  })

  it('orders by rank whatever order the router produced', () => {
    const shuffled = [...gang(3)].reverse()
    expect(splitReport(shuffled, null)!.ranks.map((r) => r.rank)).toEqual([0, 1, 2])
  })
})

describe('a layer plan that cannot be believed is not shown', () => {
  it('refuses a plan that does not cover the gang', () => {
    // Three machines and two ranges means one machine's share is unknown.
    // Showing two of three would read as a complete account of the split.
    expect(parseLayerPlan([[0, 24], [24, 48]], 3)).toBeNull()
    expect(splitReport(gang(3), [[0, 24], [24, 48]])!.layersReported).toBe(false)
  })

  it('refuses ranges that are not ranges', () => {
    expect(parseLayerPlan([[24, 24]], 1)).toBeNull()     // owns nothing
    expect(parseLayerPlan([[48, 24]], 1)).toBeNull()     // reversed
    expect(parseLayerPlan([[-1, 24]], 1)).toBeNull()     // before the start
    expect(parseLayerPlan([[0.5, 24]], 1)).toBeNull()    // not whole layers
    expect(parseLayerPlan([['0', '24']], 1)).toBeNull()  // not numbers
    expect(parseLayerPlan('0..24', 1)).toBeNull()
    expect(parseLayerPlan(null, 2)).toBeNull()
  })
})

/**
 * The maths the head does before reporting, checked here as well as in Swift.
 *
 * Boundaries accumulate rather than multiply. With 80 layers over 3 machines the
 * ranks hold 27, 27 and 26, and the obvious formula - this rank's count times
 * this rank's index - leaves layer 26 owned by nobody. A skipped layer does not
 * fail: the model computes without it and answers fluently from the wrong
 * network. So the control plane checks that what it was handed actually covers
 * the model.
 */
describe('a plan that leaves a layer to nobody', () => {
  const covers = (plan: [number, number][]) => {
    const sorted = [...plan].sort((a, b) => a[0] - b[0])
    if (sorted[0]![0] !== 0) return false
    for (let i = 1; i < sorted.length; i++) {
      if (sorted[i]![0] !== sorted[i - 1]![1]) return false
    }
    return true
  }

  it('accepts the accumulated split of 80 layers over 3', () => {
    // 27, 27, 26 - contiguous, nothing skipped.
    expect(covers([[0, 27], [27, 54], [54, 80]])).toBe(true)
  })

  it('detects the gap the multiplied formula leaves', () => {
    expect(covers([[0, 27], [28, 55], [55, 81]])).toBe(false)
  })
})
