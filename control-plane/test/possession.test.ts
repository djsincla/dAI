import { describe, expect, it } from 'vitest'
import { holdsModel } from '../src/lib/possession.js'

/**
 * Having a model, as against having started to fetch one.
 *
 * Both counts in the catalogue asked only whether the node had reported the key
 * at all, and a transfer reports it from its first block. On this fleet a node
 * one gigabyte into a 17.2GB model was counted as holding it, which took
 * nodesWanting to zero and told the operator distribution was finished when one
 * machine had six percent of the weights.
 */
describe('whether a node holds a model', () => {
  // 17.2 GB, which the node reports as 16.0 - the units differ, and that is
  // most of why nobody spotted the two numbers were not comparable.
  const SIZE = 17_197_084_801

  it('counts a complete copy', () => {
    expect(holdsModel(16.0, SIZE)).toBe(true)
  })

  it('does not count a transfer that has barely started', () => {
    // The case that prompted this.
    expect(holdsModel(1.0, SIZE)).toBe(false)
  })

  it('does not count a transfer that stopped near the end', () => {
    // Worth its own case: this is the one a percentage-based rule gets wrong if
    // the tolerance is set carelessly, and a model missing its last shard loads
    // no better than one missing all of them.
    expect(holdsModel(15.0, SIZE)).toBe(false)
  })

  it('tolerates the small disagreement between a disk and a sum of file sizes', () => {
    // The node measures its disk; the catalogue sums what it ingested. They are
    // allowed to differ slightly without a healthy machine reading as empty.
    expect(holdsModel(15.95, SIZE)).toBe(true)
  })

  it('treats a model of unknown size as held when reported', () => {
    // Nothing to compare against, so the old rule stands. Refusing here would
    // make every such model look absent on every machine.
    expect(holdsModel(4.0, null)).toBe(true)
    expect(holdsModel(4.0, 0)).toBe(true)
  })

  it('does not count a model the node never mentioned', () => {
    expect(holdsModel(undefined, SIZE)).toBe(false)
    expect(holdsModel(0, SIZE)).toBe(false)
  })
})
