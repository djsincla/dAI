/**
 * The capacity graph's time window.
 *
 * Duplicated from the browser's `view.js` rather than imported, because the two
 * run in different places and one of them has no build step. They are kept
 * identical by a test that reads both, which is a better guarantee than a
 * shared module that only one side can actually load.
 *
 * The bucket is derived from the window rather than accepted from the caller.
 * They have to agree, and a client that could set them independently could ask
 * for ten second buckets over three days and receive twenty-six thousand rows
 * for a chart nine hundred pixels wide.
 */
export const MIN_WINDOW_S = 10 * 60
export const MAX_WINDOW_S = 72 * 60 * 60

export function clampWindow(seconds: number): number {
  const n = Number(seconds)
  if (!Number.isFinite(n)) return 24 * 60 * 60
  return Math.min(MAX_WINDOW_S, Math.max(MIN_WINDOW_S, Math.round(n)))
}

export function bucketFor(windowSeconds: number): number {
  const target = clampWindow(windowSeconds) / 60
  const steps = [10, 30, 60, 300, 600, 1800, 3600, 7200, 14400]
  return steps.find((s) => s >= target) ?? steps[steps.length - 1]!
}
