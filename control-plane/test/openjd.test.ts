import { describe, expect, it } from 'vitest'
import {
  ADAPTERS, MAX_TASKS, SPECIFICATION_VERSION, adapterFor, expandParameterSpace,
  expandRange, frameOf, resolve, type JobTemplate,
} from '../src/lib/openjd.js'

/**
 * Open Job Description, which is how work arrives.
 *
 * The point of speaking a standard is that a studio's existing submitter works
 * against this fleet without knowing what this fleet is. So these tests are
 * written against the specification's own examples rather than against what
 * happens to be convenient here.
 */
describe('range expressions', () => {
  it('expands the forms the specification gives', () => {
    expect(expandRange('1-5')).toEqual({ values: [1, 2, 3, 4, 5] })
    expect(expandRange('1-5:2')).toEqual({ values: [1, 3, 5] })
    expect(expandRange('1-10:4')).toEqual({ values: [1, 5, 9] })
    expect(expandRange('-1-1')).toEqual({ values: [-1, 0, 1] })
  })

  it('combines comma-separated ranges', () => {
    expect(expandRange('10-15:2,1-5')).toEqual({ values: [10, 12, 14, 1, 2, 3, 4, 5] })
  })

  it('takes a bare number as itself', () => {
    expect(expandRange('7')).toEqual({ values: [7] })
  })

  it('refuses overlapping ranges, which the specification forbids', () => {
    // A frame rendered twice is merely wasteful. The reason to refuse is that
    // the submitter believes something about the job that is not true.
    const r = expandRange('1-5,3-8')
    expect(r).toHaveProperty('error')
    expect((r as { error: string }).error).toContain('3 appears more than once')
  })

  it('refuses a range that ends before it starts', () => {
    expect(expandRange('9-2')).toEqual({ error: 'range "9-2" ends before it starts' })
  })

  it('refuses something that is not a range at all', () => {
    expect(expandRange('every other frame')).toHaveProperty('error')
    expect(expandRange('')).toHaveProperty('error')
  })
})

describe('resolving a command to an adapter', () => {
  it('reads the basename and ignores the path it came from', () => {
    // A submitter writes whatever the application is called on the workstation
    // it was authored on. None of those paths mean anything on the machine that
    // will run it, so the basename is the only portable part and the only part
    // read.
    expect(adapterFor('/Applications/Blender.app/Contents/MacOS/blender')?.renderer)
      .toBe('blender')
    expect(adapterFor('C:\\Program Files\\Blender\\blender.exe')?.renderer).toBe('blender')
    expect(adapterFor('/usr/bin/BLENDER')?.renderer).toBe('blender')
  })

  it('accepts the adapter wrapper a Deadline Cloud submitter emits', () => {
    expect(adapterFor('blender-openjd')?.renderer).toBe('blender')
  })

  it('has no adapter for anything else', () => {
    expect(adapterFor('/bin/sh')).toBeNull()
    expect(adapterFor('python3')).toBeNull()
    expect(adapterFor('')).toBeNull()
  })
})

describe('resolving a job template', () => {
  const template = (over: Partial<JobTemplate> = {}): JobTemplate => ({
    specificationVersion: SPECIFICATION_VERSION,
    name: 'shot-050-lighting',
    parameterDefinitions: [
      { name: 'SceneFile', type: 'PATH', objectType: 'FILE', dataFlow: 'IN' },
      { name: 'OutputDir', type: 'PATH', objectType: 'DIRECTORY', dataFlow: 'OUT' },
    ],
    steps: [{
      name: 'Render',
      parameterSpace: {
        taskParameterDefinitions: [{ name: 'Frame', type: 'INT', range: '1-10' }],
      },
      script: {
        actions: {
          onRun: {
            command: 'blender',
            args: ['-b', '{{Param.SceneFile}}', '-f', '{{Task.Param.Frame}}'],
          },
        },
      },
    }],
    ...over,
  })

  const values = { SceneFile: '/proj/shot050/shot.blend', OutputDir: '/proj/shot050/out' }

  it('turns a parameter space into one task per frame', () => {
    const r = resolve(template(), values)
    expect(r).toHaveProperty('job')
    const { job } = r as any
    expect(job.steps[0].tasks).toHaveLength(10)
    expect(job.steps[0].tasks[0].parameters.Frame).toBe(1)
    expect(job.steps[0].kind).toBe('render')
  })

  it('reads which paths come in and which go back', () => {
    // dataFlow is how a submitter says what has to reach the machines and what
    // has to come back. Without it a fleet either ships everything or guesses.
    const { job } = resolve(template(), values) as any
    expect(job.inputs).toEqual(['/proj/shot050/shot.blend'])
    expect(job.outputs).toEqual(['/proj/shot050/out'])
  })

  it('applies a declared default rather than demanding it again', () => {
    const t = template({
      parameterDefinitions: [
        { name: 'SceneFile', type: 'PATH', objectType: 'FILE', dataFlow: 'IN',
          default: '/proj/default.blend' },
      ],
    })
    const { job } = resolve(t, {}) as any
    expect(job.inputs).toEqual(['/proj/default.blend'])
  })

  it('says which parameter it is missing', () => {
    const r = resolve(template(), {})
    expect((r as { error: string }).error).toContain('SceneFile')
  })

  it('refuses a specification version it does not speak', () => {
    const r = resolve(template({ specificationVersion: 'jobtemplate-2029-01' }), values)
    expect((r as { error: string }).error).toContain('jobtemplate-2023-09')
  })

  it('refuses a command it has no adapter for, at submission', () => {
    // The whole point of refusing here. A template accepted and then failed by
    // every node in turn burns a lease per machine and reads as a fleet-wide
    // fault; refused once, it tells the only person who can fix it.
    const t = template()
    t.steps[0]!.script.actions.onRun.command = '/bin/sh'
    const r = resolve(t, values)
    expect(r).toHaveProperty('error')
    const message = (r as { error: string }).error
    expect(message).toContain('no adapter')
    expect(message).toContain('resolves commands to installed adapters rather than')
    // And it says what it does know, so the submitter can act.
    for (const known of Object.keys(ADAPTERS)) expect(message).toContain(known)
  })

  it('never carries the submitted command or its arguments through', () => {
    // The deliberate departure from the specification, asserted rather than
    // described. What the template asked to execute must not survive into
    // anything a node can reach; what survives is the name of an adapter this
    // fleet chose.
    const t = template()
    t.steps[0]!.script.actions.onRun.command = '/Volumes/artist-home/blender'
    t.steps[0]!.script.actions.onRun.args = ['--python', '/tmp/evil.py']
    const { job } = resolve(t, values) as any

    const carried = JSON.stringify(job)
    expect(carried).not.toContain('/Volumes/artist-home')
    expect(carried).not.toContain('--python')
    expect(carried).not.toContain('evil.py')
    // Chosen by us, from our own list, not copied from the submission.
    expect(job.steps[0].renderer).toBe('blender')
  })

  it('caps a job that is probably a typo', () => {
    const t = template()
    t.steps[0]!.parameterSpace!.taskParameterDefinitions[0]!.range = `1-${MAX_TASKS + 1}`
    expect((resolve(t, values) as { error: string }).error).toContain('split the job')
  })
})

describe('parameter spaces with more than one dimension', () => {
  const step = (defs: any[]) => ({
    name: 'Render',
    parameterSpace: { taskParameterDefinitions: defs },
    script: { actions: { onRun: { command: 'blender' } } },
  })

  it('takes the cross product, which is what a layer sweep is', () => {
    const r = expandParameterSpace(step([
      { name: 'Frame', type: 'INT', range: '1-2' },
      { name: 'Layer', type: 'STRING', range: ['bg', 'fg'] },
    ]) as any)
    expect(r).toEqual({
      tasks: [
        { parameters: { Frame: 1, Layer: 'bg' } },
        { parameters: { Frame: 1, Layer: 'fg' } },
        { parameters: { Frame: 2, Layer: 'bg' } },
        { parameters: { Frame: 2, Layer: 'fg' } },
      ],
    })
  })

  it('a step with nothing to vary is one task', () => {
    const r = expandParameterSpace({
      name: 'Composite',
      script: { actions: { onRun: { command: 'blender' } } },
    } as any)
    expect(r).toEqual({ tasks: [{ parameters: {} }] })
  })

  it('does not read a string range as an expression', () => {
    // "1-5" is a perfectly good string, and a STRING parameter given one means
    // the string.
    const r = expandParameterSpace(step([
      { name: 'Pass', type: 'STRING', range: '1-5' },
    ]) as any)
    expect(r).toEqual({ tasks: [{ parameters: { Pass: '1-5' } }] })
  })
})

describe('finding the frame a task is for', () => {
  it('takes the parameter every submitter calls Frame', () => {
    expect(frameOf({ parameters: { Frame: 12 } })).toBe(12)
    expect(frameOf({ parameters: { frame: 12 } })).toBe(12)
  })

  it('takes a single INT under another name rather than rejecting it', () => {
    // OpenJD has no notion of a frame; it has parameter spaces, and "Frame" is
    // a convention. Refusing a working template over a spelling would be worse
    // than reading the obvious meaning.
    const defs = [{ name: 'FrameNumber', type: 'INT' as const, range: '1-3' }]
    expect(frameOf({ parameters: { FrameNumber: 3 } }, defs)).toBe(3)
  })

  it('declines to guess when there is more than one number', () => {
    expect(frameOf({ parameters: { Tile: 2, Sample: 7 } })).toBeNull()
    expect(frameOf({ parameters: {} })).toBeNull()
  })
})
