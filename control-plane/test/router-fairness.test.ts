import { describe, expect, it } from 'vitest'
import { isRefusal, selectNode, type Candidate } from '../src/lib/router.js'

/**
 * Which of two equal machines gets the work.
 *
 * This exists because of a bug that looked like a decision. On a cold fleet
 * nothing is in flight anywhere and no machine has a throughput profile for a
 * model that has never run, so both of the router's sorts tied, the comparator
 * returned zero, and a stable sort left whichever row the database returned
 * first. The same machine answered every request. Worse, it was self
 * reinforcing: throughput is only learned by running work, so the machine that
 * was never chosen could never earn the number that would have got it chosen.
 *
 * A two machine fleet served everything from one machine for weeks and looked
 * deliberate doing it.
 */

const node = (id: string, over: Partial<Candidate> = {}): Candidate => ({
  id,
  hostname: id,
  tier: 'cluster',
  presence_state: 'ABSENT',
  resident_models: {},
  capability_profiles: {},
  in_flight: 0,
  ...over,
})

const chosen = (x: ReturnType<typeof selectNode>): string => {
  expect(isRefusal(x)).toBe(false)
  return (x as Candidate).hostname
}

const AGO = (minutes: number) =>
  new Date(Date.UTC(2026, 7, 29, 4, 0, 0) - minutes * 60_000).toISOString()

describe('choosing between equals', () => {
  it('gives the work to whichever machine waited longest', () => {
    const pool = [
      node('rotorua', { last_dispatch_at: AGO(1) }),
      node('orca', { last_dispatch_at: AGO(30) }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'some-model'))).toBe('orca')
  })

  /** The bug, stated as a test: order in must not decide the answer. */
  it('does not simply take the first row', () => {
    const rotorua = node('rotorua', { last_dispatch_at: AGO(1) })
    const orca = node('orca', { last_dispatch_at: AGO(30) })
    expect(chosen(selectNode([rotorua, orca], 'generate', 'm'))).toBe('orca')
    expect(chosen(selectNode([orca, rotorua], 'generate', 'm'))).toBe('orca')
  })

  /**
   * A machine that has never been given anything is the one most worth trying,
   * and it is the only state from which a machine cannot earn a profile alone.
   */
  it('prefers a machine that has never been given work', () => {
    const pool = [
      node('rotorua', { last_dispatch_at: AGO(60) }),
      node('orca', { last_dispatch_at: null }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('orca')
  })

  it('accepts a Date as well as a string, since the driver returns one', () => {
    const pool = [
      node('rotorua', { last_dispatch_at: new Date(AGO(1)) }),
      node('orca', { last_dispatch_at: new Date(AGO(30)) }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('orca')
  })
})

describe('what the tie break must not override', () => {
  /** Being busy still loses to being free, whoever waited longer. */
  it('never sends work to a busy machine to be fair', () => {
    const pool = [
      node('rotorua', { in_flight: 0, last_dispatch_at: AGO(1) }),
      node('orca', { in_flight: 2, last_dispatch_at: AGO(90) }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('rotorua')
  })

  /** Measured throughput still wins. Fairness is the last word, not the first. */
  it('never gives up a faster machine to be fair', () => {
    const pool = [
      node('rotorua', { capability_profiles: { m: 120 }, last_dispatch_at: AGO(1) }),
      node('orca', { capability_profiles: { m: 60 }, last_dispatch_at: AGO(90) }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('rotorua')
  })

  /**
   * The reason this does not thrash a 17 GB model between machines: residency
   * narrows the pool before the tie break is ever consulted.
   */
  it('does not move a loaded model to the machine that has waited longer', () => {
    const pool = [
      node('rotorua', { resident_models: { m: 1 }, last_dispatch_at: AGO(1) }),
      node('orca', { last_dispatch_at: AGO(240) }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('rotorua')
  })

  /** Presence still gates a harvest machine, however long it has been idle. */
  it('does not wake a harvested machine somebody is using', () => {
    const pool = [
      node('rotorua', { tier: 'cluster', last_dispatch_at: AGO(1) }),
      node('orca', { tier: 'harvest', presence_state: 'ACTIVE',
                     last_dispatch_at: AGO(500) }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('rotorua')
  })
})
