import { describe, expect, it } from 'vitest'
import {
  capacityOf, isSynthetic, kindsFor, pauseAction, progressOf, runsGpu, servingFor,
} from '../ui/view.js'

/**
 * The judgements the fleet view makes on a reader's behalf.
 *
 * These were previously reachable only by loading a page against a live control
 * plane, so nothing checked them - and they are exactly the claims somebody
 * will trust without checking: whether a machine is available, whether work is
 * real or a load test, whether a pause is one they may lift. A fleet view that
 * is confidently wrong is worse than no fleet view.
 */
describe('what the fleet view says about a node', () => {
  const node = (over: Record<string, unknown> = {}) => ({
    id: 'n1', hostname: 'rotorua', state: 'active', tier: 'harvest',
    presenceState: 'ACTIVE', userPaused: false, models: [], serving: false,
    inFlight: 0, ...over,
  }) as any

  it('withholds GPU work while somebody is at the machine', () => {
    expect(runsGpu(node({ presenceState: 'ACTIVE' }))).toBe(false)
    expect(kindsFor(node({ presenceState: 'ACTIVE' }))).toEqual(['embed'])
  })

  it('offers GPU work once the machine is locked', () => {
    expect(runsGpu(node({ presenceState: 'LOCKED' }))).toBe(true)
    expect(kindsFor(node({ presenceState: 'LOCKED' }))).toContain('generate')
  })

  it('does not presence-gate a cluster node', () => {
    // A dedicated box has nobody sitting at it, and gating it on presence would
    // make an interactive session depend on whether a keyboard attached to a
    // server had been touched.
    expect(runsGpu(node({ tier: 'cluster', presenceState: 'ACTIVE' }))).toBe(true)
  })

  it('shows no work at all for a machine its owner paused', () => {
    // Not a machine that happens to be idle. Listing what it could do implies
    // the pause is advisory.
    expect(kindsFor(node({ presenceState: 'LOCKED', userPaused: true }))).toEqual([])
    expect(runsGpu(node({ presenceState: 'LOCKED', userPaused: true }))).toBe(false)
  })

  it('offers an operator no way to lift the owner\'s pause', () => {
    // A control that must either lie or fail is worse than a plain statement.
    expect(pauseAction(node({ userPaused: true })).kind).toBe('none')
    expect(pauseAction(node({ state: 'paused' })).kind).toBe('resume')
    expect(pauseAction(node()).kind).toBe('pause')
  })

  it('counts no capacity for a paused or inactive machine', () => {
    // Counting them overstates the fleet by exactly the machines whose owners
    // have opted out.
    expect(capacityOf(node({ userPaused: true }), 30)).toEqual({ gpu: 0, ane: 0 })
    expect(capacityOf(node({ state: 'offline' }), 30)).toEqual({ gpu: 0, ane: 0 })
    expect(capacityOf(node({ presenceState: 'LOCKED' }), 30)).toEqual({ gpu: 30, ane: 30 })
    // ANE work runs in every state, so a machine in use still contributes.
    expect(capacityOf(node({ presenceState: 'ACTIVE' }), 30)).toEqual({ gpu: 0, ane: 30 })
  })
})

describe('what the fleet view says about serving', () => {
  const node = (over: Record<string, unknown> = {}) => ({
    state: 'active', tier: 'cluster', presenceState: 'ACTIVE', userPaused: false,
    models: ['mlx-community/Qwen2.5-Coder-32B-Instruct-4bit'], serving: true,
    inFlight: 0, ...over,
  }) as any

  it('says busy, not gone, while a node is mid-request', () => {
    // A node reading a large prompt is off the channel for minutes while being
    // entirely healthy. Reporting that as unavailable sent somebody looking for
    // a crash that had not happened.
    expect(servingFor(node({ serving: false })).state).toBe('busy')
  })

  it('says how many requests are in flight', () => {
    expect(servingFor(node({ inFlight: 1 })).label).toBe('answering 1 request')
    expect(servingFor(node({ inFlight: 3 })).label).toBe('answering 3 requests')
  })

  it('says nothing for a node serving no models', () => {
    expect(servingFor(node({ models: [] })).state).toBe('none')
  })

  it('is ready when it holds a model and is on the channel', () => {
    expect(servingFor(node()).state).toBe('ready')
  })
})

describe('what the fleet view says about work', () => {
  it('marks work that was generated rather than asked for', () => {
    // This repository produced exactly this kind of load for days; unmarked, its
    // throughput reads as the studio's real activity.
    expect(isSynthetic({ source: 'test-harness' } as any)).toBe(true)
    expect(isSynthetic({ source: 'demo-seed' } as any)).toBe(true)
    expect(isSynthetic({ source: 'api' } as any)).toBe(false)
    expect(isSynthetic({ source: 'cli' } as any)).toBe(false)
    // Absent means ordinary traffic, not synthetic.
    expect(isSynthetic({} as any)).toBe(false)
  })

  it('reports progress without dividing by zero', () => {
    expect(progressOf({ counts: { pending: 3, leased: 1, done: 6, failed: 0 } } as any))
      .toEqual({ done: 6, total: 10, percent: 60 })
    expect(progressOf({ counts: {} } as any)).toEqual({ done: 0, total: 0, percent: 0 })
    expect(progressOf({} as any)).toEqual({ done: 0, total: 0, percent: 0 })
  })
})
