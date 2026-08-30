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

/**
 * Preferring the machine nobody is sitting at.
 *
 * Cluster nodes skip the presence gate, which is what lets an interactive
 * conversation run at all. That exemption also made presence irrelevant to the
 * choice, so a machine somebody was typing on was as likely to be picked as an
 * idle one beside it - and the three "somebody is here" states cap completions
 * at 256 tokens against 2,048 locked and 4,096 logged out. The cost of choosing
 * wrong is not politeness, it is an answer that stops mid sentence.
 */
describe('preferring a machine nobody is using', () => {
  it('sends work to the idle machine rather than the one in use', () => {
    const pool = [
      node('rotorua', { presence_state: 'ACTIVE' }),
      node('orca', { presence_state: 'ABSENT' }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('orca')
  })

  it('ranks the five states by what they actually allow', () => {
    const order = ['ACTIVE', 'PASSIVE', 'IDLE', 'LOCKED', 'ABSENT'] as const
    for (let i = 0; i < order.length - 1; i++) {
      const pool = [
        node('busier', { presence_state: order[i] }),
        node('freer', { presence_state: order[i + 1] }),
      ]
      expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('freer')
    }
  })

  /**
   * The trade this makes explicit: 256 tokens against 4,096 is a sixteen fold
   * difference in what can be said, and no measured throughput gap here has
   * ever been close to that.
   */
  it('takes the free machine even when the busy one is measurably faster', () => {
    const pool = [
      node('rotorua', { presence_state: 'ACTIVE',
                        capability_profiles: { m: 200 } }),
      node('orca', { presence_state: 'ABSENT',
                     capability_profiles: { m: 50 } }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('orca')
  })

  /** Queueing behind a busy machine helps nobody, however free it is. */
  it('does not queue behind a free machine that is already working', () => {
    const pool = [
      node('rotorua', { presence_state: 'ACTIVE', in_flight: 0 }),
      node('orca', { presence_state: 'ABSENT', in_flight: 3 }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('rotorua')
  })

  /** Not knowing whether somebody is there is not a reason to assume nobody is. */
  it('treats an unreported presence as cautiously as ACTIVE', () => {
    const pool = [
      node('unknown', { presence_state: null }),
      node('idle', { presence_state: 'IDLE' }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('idle')
  })

  /** With presence equal, the earlier rules still decide. */
  it('falls through to fairness when both machines are equally free', () => {
    const pool = [
      node('rotorua', { presence_state: 'ABSENT', last_dispatch_at: AGO(1) }),
      node('orca', { presence_state: 'ABSENT', last_dispatch_at: AGO(30) }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('orca')
  })

  /** A machine in use is still better than no machine. */
  it('uses the machine somebody is on when it is the only one', () => {
    const pool = [node('rotorua', { presence_state: 'ACTIVE' })]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('rotorua')
  })
})

/**
 * Residency against presence.
 *
 * This is the case the first presence fix shipped without. Every presence test
 * above used machines with nothing loaded, so all of them passed against a
 * router that filtered by residency before it ever sorted - and on the real
 * fleet, where one machine held the model, the fix did nothing at all. The
 * deployed behaviour was unchanged and the tests were green.
 */
describe('residency against presence', () => {
  /** The live failure, as a test. */
  it('moves to the free machine even though the busy one holds the model', () => {
    const pool = [
      node('rotorua', { presence_state: 'ACTIVE',
                        resident_models: { m: 1 } }),
      node('orca', { presence_state: 'LOCKED' }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('orca')
  })

  /**
   * And the property that has to survive it: with nobody at either machine,
   * the model does not wander.
   */
  it('leaves a loaded model where it is when presence is equal', () => {
    const pool = [
      node('rotorua', { presence_state: 'ABSENT', resident_models: { m: 1 },
                        last_dispatch_at: AGO(1) }),
      node('orca', { presence_state: 'ABSENT', last_dispatch_at: AGO(240) }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('rotorua')
  })

  /** Residency still beats raw throughput, which is the cheap outcome. */
  it('prefers the machine holding the model over a faster empty one', () => {
    const pool = [
      node('rotorua', { resident_models: { m: 1 }, capability_profiles: { m: 40 } }),
      node('orca', { capability_profiles: { m: 400 } }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('rotorua')
  })

  /** A request naming no model has no residency to weigh. */
  it('ignores residency when no model was named', () => {
    const pool = [
      node('rotorua', { presence_state: 'ACTIVE', resident_models: { m: 1 } }),
      node('orca', { presence_state: 'LOCKED' }),
    ]
    expect(chosen(selectNode(pool, 'generate', null))).toBe('orca')
  })

  /** Nobody holds it: the choice falls through to the rules below. */
  it('falls through when neither machine holds the model', () => {
    const pool = [
      node('rotorua', { last_dispatch_at: AGO(1) }),
      node('orca', { last_dispatch_at: AGO(90) }),
    ]
    expect(chosen(selectNode(pool, 'generate', 'm'))).toBe('orca')
  })
})
