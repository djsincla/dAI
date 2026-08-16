import { describe, expect, it } from 'vitest'
import { assignRanks, rankOf } from '../src/lib/splitRanks.js'

const m = (id: string, pipelineAddress: string | null = '192.168.99.1') =>
  ({ id, hostname: id, pipelineAddress })

/**
 * Who holds which layers, decided once.
 *
 * This rule was about to exist in three places - the router at dispatch, the
 * readiness view telling an operator what would happen, and the heartbeat
 * telling a machine what to build before anything is asked of it. Three copies
 * of one rule is how a disabled group came to be counted by two call sites and
 * not a third, found separately and fixed separately.
 */
describe('assigning ranks', () => {
  it('gives the output head to a machine that can be dialled', () => {
    // Rank 0 holds the last layers and the head, so it is the one that answers
    // and the one the others dial. A machine with no address cannot be dialled.
    const out = assignRanks([m('a', null), m('b')])!
    expect(out[0]!.member.id).toBe('b')
    expect(out[0]!.role).toBe('output head')
    expect(out[1]!.role).toBe('feeds the next rank')
  })

  it('refuses to order a group nobody can dial', () => {
    // Null, not an empty list: those are different answers. Empty reads as "no
    // machines"; the truth is machines that cannot form a pipeline, and a
    // caller showing rank 0 anyway would name a role nobody holds.
    expect(assignRanks([m('a', null), m('b', null)])).toBeNull()
    expect(assignRanks([])).toBeNull()
  })

  it('is stable, so a machine does not change rank between heartbeats', () => {
    // A rank that moved would make a machine rebuild its share for no reason -
    // 9.45 GB of work to arrive back where it started.
    const first = assignRanks([m('b'), m('a'), m('c')])!.map((r) => r.member.id)
    const again = assignRanks([m('c'), m('b'), m('a')])!.map((r) => r.member.id)
    expect(first).toEqual(again)
  })

  it('numbers every machine once', () => {
    const out = assignRanks([m('a'), m('b'), m('c')])!
    expect(out.map((r) => r.rank)).toEqual([0, 1, 2])
  })

  it('says what one machine was given, or that it was given nothing', () => {
    const out = assignRanks([m('a'), m('b')])
    expect(rankOf(out, 'a')).not.toBeNull()
    expect(rankOf(out, 'missing')).toBeNull()
    expect(rankOf(null, 'a')).toBeNull()
  })

  it('puts every dialable machine ahead of every undialable one', () => {
    // Not merely rank 0: a machine with no address cannot be dialled by anyone,
    // so it belongs at the end however many there are.
    const out = assignRanks([m('a', null), m('b'), m('c', null), m('d')])!
    expect(out.slice(0, 2).every((r) => r.member.pipelineAddress)).toBe(true)
    expect(out.slice(2).every((r) => !r.member.pipelineAddress)).toBe(true)
  })
})
