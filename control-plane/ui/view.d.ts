/**
 * Types for the fleet view's judgement layer.
 *
 * The view is plain JavaScript with no build step, deliberately: it runs
 * wherever the control plane runs and can be read without tooling. This file
 * exists so its tests can be type-checked without the module acquiring a build.
 */
export declare const GPU_STATES: Set<string>

export interface NodeView {
  id?: string
  hostname?: string
  state: string
  tier?: string
  presenceState: string | null
  userPaused?: boolean
  models?: string[]
  serving?: boolean
  inFlight?: number
}

export interface JobView {
  source?: string
  counts?: { pending?: number; leased?: number; done?: number; failed?: number }
}

export declare function runsGpu(node: NodeView): boolean
export declare function kindsFor(node: NodeView): string[]
export declare function servingFor(node: NodeView): {
  state: 'none' | 'busy' | 'answering' | 'ready'
  label: string
  models: string[]
}
export declare function pauseAction(node: NodeView): {
  kind: 'none' | 'pause' | 'resume'
  label: string
}
export declare function isSynthetic(job: JobView): boolean
export declare function progressOf(job: JobView): {
  done: number; total: number; percent: number
}
export declare function capacityOf(node: NodeView, headroomGb?: number): {
  gpu: number; ane: number
}

export interface Distribution {
  state: 'drift' | 'complete' | 'unused' | 'idle'
  label: string
  holding: number
  wanting: number
}
export function distributionOf(model: any): Distribution
export function humanBytes(n: number): string
export function copyState(placement: any): { state: string; label: string }

export function machinesThatCouldHold(sizeBytes: number, nodes: any[]): {
  fits: number; total: number
}
export function importCost(candidate: any): { state: string; label: string }

export interface Attention {
  level: 'decide' | 'warn' | 'ok'
  key: string
  text: string
  detail?: string | null
  view?: string
}
export function attentionItems(state: any): Attention[]

export const STALE_AFTER_MS: number
export function isStale(node: any, now?: number): boolean
export function withFreshness(nodes: any[], now?: number): any[]

export function importProgress(row: any): {
  state: 'running' | 'done' | 'failed'
  percent: number | null
  label: string
}

export function matchesQuery(row: any, query: string, fields: any[]): boolean
export function sortRows(rows: any[], key: string, dir: string, accessors: any): any[]
export function nextSort(current: any, key: string): { key: string; dir: string } | null

export const MIN_WINDOW_S: number
export const MAX_WINDOW_S: number
export function windowFromDrag(current: number, deltaPx: number, widthPx: number): number
export function clampWindow(seconds: number): number
export function bucketFor(windowSeconds: number): number
export function describeWindow(seconds: number): string

export function rolloutState(row: any): { state: string; label: string }
export function upgradeOutcome(row: any): { state: string; label: string }

export function groupMode(pool: any): 'list' | 'rule'
export function groupMismatches(pool: any, nodes: any[], models: any[]): any[]
export function groupWarning(mismatches: any[]): { level: string; label: string; reasons: string[] } | null
export function groupMachines(nodes: any[], pools: any[], matcher: (n: any, p: any) => boolean): {
  groups: { pool: any; mode: string; nodes: any[] }[]
  ungrouped: any[]
}

export function matchesGroup(node: any, pool: any): boolean
