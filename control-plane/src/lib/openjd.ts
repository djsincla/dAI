/**
 * Open Job Description, as the way work is submitted.
 *
 * OpenJD is the open specification for portable render jobs, so a studio's
 * existing submitter should be able to point at dAI without knowing what dAI
 * is. That is the reason to speak it rather than an invented shape: a render
 * job that only this fleet understands is a render job nobody can send.
 *
 * ## The one place this deliberately departs from the specification
 *
 * OpenJD describes a step's work as `script.actions.onRun.command` and `args` -
 * an executable and its arguments. That is the correct design for a farm you
 * own, where a worker running what the job says is the point.
 *
 * These are not machines the fleet owns. They belong to the people sitting at
 * them, borrowed on the promise that the agent does what it says and nothing
 * else. Executing an arbitrary command from a submission would make "submit a
 * job" mean "run this binary on fifty of your colleagues' workstations", which
 * is a different product with a different threat model.
 *
 * So `command` is *resolved*, never executed. It is matched against the
 * adapters this fleet has, and the matching adapter decides what actually runs.
 * A template asking for something with no adapter is refused at submission,
 * with a message saying so, rather than accepted and then failed on fifty
 * machines one at a time.
 *
 * Everything else - the parameter space, the range expressions, the job
 * parameters and their data flow, the host requirements - is the specification
 * as written, because that is the part that makes a submitter portable.
 */

export const SPECIFICATION_VERSION = 'jobtemplate-2023-09'

export type ParameterType = 'INT' | 'FLOAT' | 'STRING' | 'PATH'
export type DataFlow = 'NONE' | 'IN' | 'OUT' | 'INOUT'

export interface JobParameterDefinition {
  name: string
  type: ParameterType
  objectType?: 'FILE' | 'DIRECTORY'
  dataFlow?: DataFlow
  default?: string | number
}

export interface TaskParameterDefinition {
  name: string
  type: ParameterType
  range: string | (string | number)[]
}

export interface StepTemplate {
  name: string
  parameterSpace?: { taskParameterDefinitions: TaskParameterDefinition[] }
  script: { actions: { onRun: { command: string; args?: string[]; timeout?: number } } }
  hostRequirements?: HostRequirements
}

export interface HostRequirements {
  amounts?: { name: string; min?: number; max?: number }[]
  attributes?: { name: string; anyOf?: string[]; allOf?: string[] }[]
}

export interface JobTemplate {
  specificationVersion: string
  name: string
  description?: string
  parameterDefinitions?: JobParameterDefinition[]
  steps: StepTemplate[]
}

/**
 * The adapters this fleet has, keyed by the command an OpenJD template names.
 *
 * Deliberately a short list of basenames rather than a path match. A submitter
 * writes whatever `blender` happens to be called on the machine it was authored
 * on - `/Applications/Blender.app/Contents/MacOS/Blender`, `blender.exe`,
 * `/usr/bin/blender` - and none of those paths mean anything on the machine
 * that will run it. The basename is the only portable part, and it is the only
 * part read.
 */
export const ADAPTERS: Record<string, { kind: 'render'; renderer: 'blender' }> = {
  blender: { kind: 'render', renderer: 'blender' },
  'blender.exe': { kind: 'render', renderer: 'blender' },
  // Deadline Cloud's submitters emit the adapter wrapper rather than the
  // application, so a template authored for that farm arrives here unchanged.
  'blender-openjd': { kind: 'render', renderer: 'blender' },
  blenderadaptor: { kind: 'render', renderer: 'blender' },
}

export function adapterFor(command: string): { kind: 'render'; renderer: 'blender' } | null {
  // The basename, lowercased. A template may name an absolute path from
  // somebody else's workstation; the directories in it are meaningless here and
  // are not consulted for anything.
  const base = command.split(/[\\/]/).pop()?.toLowerCase() ?? ''
  return ADAPTERS[base] ?? null
}

/**
 * An OpenJD range expression, expanded.
 *
 * `"1-100"`, `"1-100:2"`, `"10-15:2,1-5"`, `"-1-1"`. The specification forbids
 * overlapping ranges, and that is enforced rather than tolerated: two ranges
 * that overlap mean a frame rendered twice, which for an idempotent task is
 * merely wasteful, and means the submitter believes something about the job
 * that is not true.
 */
export function expandRange(expr: string): { values: number[] } | { error: string } {
  const seen = new Set<number>()
  const values: number[] = []
  const parts = expr.split(',').map((p) => p.trim()).filter((p) => p !== '')
  if (parts.length === 0) return { error: `empty range: ${JSON.stringify(expr)}` }

  for (const part of parts) {
    // Leading '-' is a negative bound, not a separator, so the split has to
    // look for a hyphen that follows a digit.
    const m = /^(-?\d+)(?:-(-?\d+))?(?::(\d+))?$/.exec(part)
    if (!m) return { error: `cannot read range ${JSON.stringify(part)}` }
    const start = Number(m[1])
    const end = m[2] === undefined ? start : Number(m[2])
    const step = m[3] === undefined ? 1 : Number(m[3])
    if (step < 1) return { error: `step must be at least 1 in ${JSON.stringify(part)}` }
    if (end < start) return { error: `range ${JSON.stringify(part)} ends before it starts` }
    for (let v = start; v <= end; v += step) {
      if (seen.has(v)) return { error: `${v} appears more than once in ${JSON.stringify(expr)}` }
      seen.add(v)
      values.push(v)
    }
  }
  return { values }
}

/** A cap, because "1-100000" is indistinguishable from a typo until the fleet
 *  has been busy for a week. */
export const MAX_TASKS = 20_000

export interface Task {
  /** Every task parameter, by name, as the template defined them. */
  parameters: Record<string, string | number>
}

export interface ResolvedStep {
  name: string
  kind: 'render'
  renderer: 'blender'
  tasks: Task[]
  hostRequirements?: HostRequirements
}

export interface ResolvedJob {
  name: string
  steps: ResolvedStep[]
  /** PATH parameters the submitter says are inputs, which is what has to reach
   *  the machines, and outputs, which is what has to come back. */
  inputs: string[]
  outputs: string[]
}

/**
 * Read a template, or say precisely why it cannot be run here.
 *
 * Refusal happens at submission on purpose. A template accepted and then failed
 * by every node in turn burns a lease per machine and reports as a fleet-wide
 * fault; refusing it once, to the person who submitted it, tells the only
 * people who can fix it.
 */
export function resolve(
  template: JobTemplate,
  parameterValues: Record<string, string | number> = {},
): { job: ResolvedJob } | { error: string } {
  if (template?.specificationVersion !== SPECIFICATION_VERSION) {
    return {
      error: `unsupported specificationVersion ${JSON.stringify(template?.specificationVersion)}`
        + `; this fleet speaks ${SPECIFICATION_VERSION}`,
    }
  }
  if (!template.name) return { error: 'the template has no name' }
  if (!Array.isArray(template.steps) || template.steps.length === 0) {
    return { error: 'the template has no steps' }
  }

  // Job parameters, defaults applied, so a template that declares a default is
  // submittable without restating it.
  const params: Record<string, string | number> = {}
  for (const def of template.parameterDefinitions ?? []) {
    const given = parameterValues[def.name]
    const value = given ?? def.default
    if (value === undefined) return { error: `no value for job parameter ${def.name}` }
    params[def.name] = value
  }

  const inputs: string[] = []
  const outputs: string[] = []
  for (const def of template.parameterDefinitions ?? []) {
    if (def.type !== 'PATH') continue
    const flow = def.dataFlow ?? 'NONE'
    if (flow === 'IN' || flow === 'INOUT') inputs.push(String(params[def.name]))
    if (flow === 'OUT' || flow === 'INOUT') outputs.push(String(params[def.name]))
  }

  const steps: ResolvedStep[] = []
  let total = 0
  for (const step of template.steps) {
    if (!step?.name) return { error: 'a step has no name' }
    const command = step.script?.actions?.onRun?.command
    if (!command) return { error: `step ${step.name} has no onRun command` }

    const adapter = adapterFor(command)
    if (!adapter) {
      return {
        error: `no adapter for ${JSON.stringify(command)} in step ${step.name}. `
          + `This fleet resolves commands to installed adapters rather than `
          + `running them, because the machines belong to the people using them. `
          + `Known: ${Object.keys(ADAPTERS).sort().join(', ')}`,
      }
    }

    const expanded = expandParameterSpace(step)
    if ('error' in expanded) return { error: `step ${step.name}: ${expanded.error}` }
    total += expanded.tasks.length
    if (total > MAX_TASKS) {
      return { error: `more than ${MAX_TASKS} tasks; split the job` }
    }

    steps.push({
      name: step.name,
      kind: adapter.kind,
      renderer: adapter.renderer,
      tasks: expanded.tasks,
      hostRequirements: step.hostRequirements,
    })
  }

  return { job: { name: template.name, steps, inputs, outputs } }
}

/**
 * The cross product of a step's task parameters.
 *
 * A step with no parameter space is one task, which is the specification's own
 * reading and the right one: a single composite at the end of a sequence is a
 * step with nothing to vary.
 */
export function expandParameterSpace(
  step: StepTemplate,
): { tasks: Task[] } | { error: string } {
  const defs = step.parameterSpace?.taskParameterDefinitions ?? []
  if (defs.length === 0) return { tasks: [{ parameters: {} }] }

  let tasks: Task[] = [{ parameters: {} }]
  for (const def of defs) {
    if (!def?.name) return { error: 'a task parameter has no name' }
    const values = valuesOf(def)
    if ('error' in values) return values
    if (values.values.length === 0) return { error: `${def.name} has an empty range` }

    const next: Task[] = []
    for (const task of tasks) {
      for (const value of values.values) {
        next.push({ parameters: { ...task.parameters, [def.name]: value } })
      }
    }
    tasks = next
    if (tasks.length > MAX_TASKS) return { error: `more than ${MAX_TASKS} tasks; split the job` }
  }
  return { tasks }
}

function valuesOf(
  def: TaskParameterDefinition,
): { values: (string | number)[] } | { error: string } {
  if (Array.isArray(def.range)) return { values: def.range }
  if (typeof def.range !== 'string') return { error: `${def.name} has no range` }
  if (def.type === 'INT') {
    const expanded = expandRange(def.range)
    if ('error' in expanded) return expanded
    return { values: expanded.values }
  }
  // A non-INT parameter given a string range is a single value, not an
  // expression: "1-5" is a perfectly good string.
  return { values: [def.range] }
}

/**
 * The frame a task is for, if it is about a frame at all.
 *
 * OpenJD does not have a notion of a frame - it has parameter spaces, and a
 * frame is a convention. `Frame` is what every submitter in practice calls it;
 * a single INT parameter under another name is taken to be the same thing,
 * because refusing it would reject working templates over a spelling.
 */
export function frameOf(task: Task, defs: TaskParameterDefinition[] = []): number | null {
  const named = task.parameters.Frame ?? task.parameters.frame
  if (typeof named === 'number') return named

  const ints = defs.filter((d) => d.type === 'INT')
  if (ints.length === 1) {
    const only = task.parameters[ints[0]!.name]
    if (typeof only === 'number') return only
  }
  const numbers = Object.values(task.parameters).filter((v) => typeof v === 'number')
  return numbers.length === 1 ? (numbers[0] as number) : null
}
