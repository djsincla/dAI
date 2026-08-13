import { describe, expect, it } from 'vitest'
import { capacity, DEFAULT_RANGE, nextFree, rangeFrom } from '../src/lib/ports.js'

/**
 * Which socket a group gets.
 *
 * A group's port is how a caller says which machines it wants, so two groups
 * sharing one would silently send work to the wrong fleet - and a group that
 * failed to get one would be unreachable while looking created.
 */
describe('allocating a group its socket', () => {
  it('gives the first group the bottom of the range', () => {
    expect(nextFree([])).toBe(DEFAULT_RANGE.from)
  })

  it('never hands out one already held', () => {
    expect(nextFree([8460, 8461])).toBe(8462)
  })

  it('fills a gap in the range rather than walking off the end', () => {
    // Lowest free rather than next after the highest, so a range with a hole in
    // it is usable. Worth knowing that this is also what would hand a deleted
    // group's port straight to the next group created - there is no way to
    // delete a group today, and when there is, the port has to be held back:
    // a client left pointing at the old URL would otherwise start talking to
    // somebody else's machines.
    expect(nextFree([8460, 8462])).toBe(8461)
  })

  it('says the range is full rather than inventing a port', () => {
    const range = { from: 9000, to: 9002 }
    expect(nextFree([9000, 9001, 9002], range)).toBe(null)
    expect(capacity(range)).toBe(3)
  })

  it('ignores ports held outside its range', () => {
    // Something else on the machine holding 9100 is not this range's business,
    // and treating it as taken would shrink the range for no reason.
    expect(nextFree([9100, 9101], { from: 9000, to: 9002 })).toBe(9000)
  })
})

describe('where the range comes from', () => {
  it('defaults when nothing is configured', () => {
    expect(rangeFrom(undefined)).toEqual(DEFAULT_RANGE)
    expect(rangeFrom('')).toEqual(DEFAULT_RANGE)
  })

  it('takes a range a deployment asked for', () => {
    expect(rangeFrom('9000-9010')).toEqual({ from: 9000, to: 9010 })
    expect(rangeFrom(' 9000 - 9010 ')).toEqual({ from: 9000, to: 9010 })
  })

  it('refuses a value it cannot read rather than quietly defaulting', () => {
    // Somebody who set this meant something by it. Binding forty sockets
    // somewhere other than where they said is worse than not starting.
    expect(() => rangeFrom('8460')).toThrow(/8460-8499/)
    expect(() => rangeFrom('nine thousand')).toThrow()
  })

  it('refuses a range that is not one', () => {
    expect(() => rangeFrom('9010-9000')).toThrow(/not a usable range/)
    expect(() => rangeFrom('0-10')).toThrow(/not a usable range/)
    expect(() => rangeFrom('60000-70000')).toThrow(/not a usable range/)
  })
})
