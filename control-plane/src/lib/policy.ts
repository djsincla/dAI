/**
 * Presence policy. These are E2 and E5 measurements, not estimates, and the
 * agent's Python implementation (spike/presence/presence.py) is the reference.
 *
 * Both sides must agree, so the contract tests assert this table against the
 * agent's. A drift here is a drift in what runs on someone's machine.
 */

export type PresenceState = 'ACTIVE' | 'PASSIVE' | 'IDLE' | 'LOCKED' | 'ABSENT'
export type WorkKind = 'embed' | 'generate' | 'render'

export interface StatePolicy {
  gpu: boolean
  ane: boolean
  qos: 'background' | 'standard'
  dutyMax: number
  memFrac: number
  /**
   * Largest completion a harvest node may accept, in tokens.
   *
   * Batch work yields between items and hands back the remainder. A single
   * interactive request has no such seam, so a user returning mid-completion
   * either waits for it or loses it. Capping the completion bounds that wait:
   * at ~40 tok/s a 256-token cap is a worst case of a few seconds.
   *
   * The cluster tier has no cap because it is never preempted, which is another
   * reason interactive serving belongs there.
   */
  maxCompletionTokens: number
}

/**
 * GPU work is forbidden wherever a user is logged in. E2 swept QoS against duty
 * cycle and found every configuration perceptible: the gentlest tested
 * (background QoS, 25% duty) still cost 46% of viewport p95.
 *
 * ANE work is permitted everywhere. E5 measured a saturating ANE workload as
 * indistinguishable from no load, which makes it the only daytime option and
 * the only thing three of five states allow at all.
 *
 * memFrac is NOT a politeness dial. E2 measured a 32 GB load disturbing a
 * viewport less than an 8 GB one at identical duty. Footprint governs what
 * fits; occupancy governs disturbance.
 */
export const POLICY: Record<PresenceState, StatePolicy> = {
  ACTIVE: { gpu: false, ane: true, qos: 'background', dutyMax: 0.0, memFrac: 0.0, maxCompletionTokens: 256 },
  PASSIVE: { gpu: false, ane: true, qos: 'background', dutyMax: 0.0, memFrac: 0.15, maxCompletionTokens: 256 },
  IDLE: { gpu: false, ane: true, qos: 'background', dutyMax: 0.0, memFrac: 0.35, maxCompletionTokens: 256 },
  LOCKED: { gpu: true, ane: true, qos: 'standard', dutyMax: 1.0, memFrac: 0.7, maxCompletionTokens: 2048 },
  ABSENT: { gpu: true, ane: true, qos: 'standard', dutyMax: 1.0, memFrac: 0.85, maxCompletionTokens: 4096 },
}

const GPU_KINDS: WorkKind[] = ['generate', 'render']

/** Work kinds a node in this state may run. Mirrors the agent's own check. */
export function permittedKinds(state: PresenceState): WorkKind[] {
  const p = POLICY[state]
  const kinds: WorkKind[] = []
  if (p.ane) kinds.push('embed')
  if (p.gpu && p.dutyMax > 0) kinds.push(...GPU_KINDS)
  return kinds
}

/**
 * The control plane never hands out work a node's state forbids, even if the
 * node asks for it. The agent applies the same rule locally; this is the second
 * of the two, because a compromised or buggy agent must not be able to talk the
 * scheduler into dispatching GPU work to a machine someone is using.
 */
export function filterRequestedKinds(state: PresenceState | null, requested: WorkKind[]): WorkKind[] {
  // No heartbeat yet means unknown presence. Fail closed to ANE-only rather
  // than assuming nobody is there.
  const allowed = permittedKinds(state ?? 'ACTIVE')
  return requested.filter((k) => allowed.includes(k))
}
