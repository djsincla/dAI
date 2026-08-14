import { describe, expect, it } from 'vitest'
import { Broker } from '../src/lib/broker.js'

/**
 * What a gang does when one of its ranks is gone.
 *
 * A pipeline missing a rank produces nothing, so the moment one rank fails the
 * request is over. Waiting for the others is only worth a moment - and on this
 * fleet the silent one is usually the machine that caused the failure, which
 * had gone to sleep and would not have answered for another ten minutes.
 */
describe('a gang that loses a rank', () => {
  const members = [
    { nodeId: 'n0', hostname: 'orca', rank: 0 },
    { nodeId: 'n1', hostname: 'rotorua', rank: 1 },
  ]

  it('ends when the first rank fails, without waiting for the silent one', async () => {
    const broker = new Broker()
    const waitingA = broker.waitForWork('n0')
    const waitingB = broker.waitForWork('n1')

    const started = Date.now()
    const gang = broker.dispatchGang(members, 'generate', 'model', () => ({}))
    const [, toB] = await Promise.all([waitingA, waitingB])

    // Rank 1 says it could not reach its peer. Rank 0 is asleep and says
    // nothing at all, which is the case this exists for.
    broker.complete(toB!.id, 'n1', { error: 'rank 1 failed: Connect timeout (10 s)' })

    const out = await gang
    const took = Date.now() - started

    expect(out.ok).toBe(false)
    expect((out as { error: string }).error).toContain('rotorua')
    // Every rank is named, not only the one that spoke: a gang that broke is
    // worth seeing in full, and the ranks that did their share should not read
    // as the problem.
    expect((out as { error: string }).error).toContain('orca')
    expect((out as { error: string }).error).toContain('did not report')
    // The default dispatch timeout is minutes. This has to be seconds.
    expect(took).toBeLessThan(6_000)
  })

  it('still answers from the head when every rank reports', async () => {
    const broker = new Broker()
    const waitingA = broker.waitForWork('n0')
    const waitingB = broker.waitForWork('n1')
    const gang = broker.dispatchGang(members, 'generate', 'model', () => ({}))
    const [toA, toB] = await Promise.all([waitingA, waitingB])

    broker.complete(toB!.id, 'n1', { body: null })
    broker.complete(toA!.id, 'n0', { body: { choices: ['hello'] } })

    const out = await gang
    expect(out.ok).toBe(true)
    // Rank 0 holds the output head, so its answer is the request's answer.
    expect((out as { body: unknown }).body).toEqual({ choices: ['hello'] })
  })
})
