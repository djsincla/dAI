import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { bucketFor, clampWindow, MAX_WINDOW_S, MIN_WINDOW_S } from '../src/lib/window.js'
import * as view from '../ui/view.js'

/**
 * The window rule exists twice, once per runtime, and the two must agree.
 *
 * The browser has no build step, so it cannot import the server's TypeScript,
 * and the server should not import a module written for a browser. Duplication
 * is the honest answer; a test that reads both is a better guarantee than a
 * shared file only one side can load, because it fails when they drift rather
 * than when somebody notices a graph looks wrong.
 */
describe('the server and the browser agree about time windows', () => {
  it('clamps to the same range', () => {
    expect(MIN_WINDOW_S).toBe(view.MIN_WINDOW_S)
    expect(MAX_WINDOW_S).toBe(view.MAX_WINDOW_S)
  })

  it('buckets identically at every window a client can ask for', () => {
    for (const w of [600, 900, 1800, 3600, 7200, 21600, 43200, 86400, 172800, 259200]) {
      expect(bucketFor(w), `window ${w}`).toBe(view.bucketFor(w))
      expect(clampWindow(w), `window ${w}`).toBe(view.clampWindow(w))
    }
  })

  it('agrees on values outside the range too', () => {
    for (const w of [0, -5, 1, 999999999, Number.NaN]) {
      expect(clampWindow(w), `window ${w}`).toBe(view.clampWindow(w))
    }
  })

  it('is declared in the specification with the same bounds', () => {
    // A window the server clamps but the spec rejects is a 400 for a request
    // the server would have answered, and the validator runs first.
    const spec = readFileSync(join(process.cwd(), 'openapi', 'dai.yaml'), 'utf8')
    expect(spec).toContain(`minimum: ${MIN_WINDOW_S}`)
    expect(spec).toContain(`maximum: ${MAX_WINDOW_S}`)
  })
})
