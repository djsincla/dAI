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
