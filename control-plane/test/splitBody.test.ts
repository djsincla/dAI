import { describe, expect, it } from 'vitest'
import { PIPELINE_PORT, splitBody } from '../src/routes/serving.js'

/**
 * What each rank is told.
 *
 * The two plans have to be complementary: exactly one machine listens and every
 * other dials it, at the same port, for the same model. A pair that disagrees
 * does not fail - it hangs, with each machine waiting for the other.
 */
describe('the plan sent to each rank', () => {
  const base = { messages: [], max_tokens: 64 }
  const plan = (rank: number) =>
    (splitBody(rank, 2, '192.168.99.1', 'org/model', base) as {
      split: { rank: number; role: string; peer: string | null; port: number; model: string }
    }).split

  it('makes rank 0 listen and everyone else dial it', () => {
    expect(plan(0).role).toBe('listen')
    expect(plan(1).role).toBe('dial')
    expect(plan(1).peer).toBe('192.168.99.1')
  })

  it('tells the listener nothing to dial', () => {
    // A listener with a peer would dial itself, given the chance.
    expect(plan(0).peer).toBeNull()
  })

  it('agrees on the port and the model', () => {
    expect(plan(0).port).toBe(plan(1).port)
    expect(plan(0).port).toBe(PIPELINE_PORT)
    expect(plan(0).model).toBe(plan(1).model)
  })

  it('names the role rather than leaving it to be inferred from the rank', () => {
    // Both machines are told their job. Deriving it from the rank number is the
    // kind of implicit agreement that holds right up until somebody renumbers.
    expect(plan(0)).toHaveProperty('role')
    expect(plan(1)).toHaveProperty('role')
  })

  it('keeps the request itself intact', () => {
    // The split is added to a completion, not substituted for one: the rank
    // holding the head still has to answer the question that was asked.
    const body = splitBody(0, 2, '192.168.99.1', 'org/model', base) as Record<string, unknown>
    expect(body.messages).toEqual([])
    expect(body.max_tokens).toBe(64)
  })

  it('says how many ranks there are, so each knows its share of the layers', () => {
    const two = (splitBody(0, 2, 'x', 'm', base) as { split: { size: number } }).split
    expect(two.size).toBe(2)
  })
})
