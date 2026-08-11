import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { candidates, localCandidates } from '../src/lib/candidates.js'

/**
 * What the fleet offers as a model somebody could add.
 *
 * The list is a shortlist rather than a mirror of a public hub, and the
 * ordering is the substantive part: a model already on this machine costs a
 * copy, one from the internet costs the building's uplink. A system whose
 * premise is that data does not leave the building should not have weights
 * arriving from outside it as a side effect of somebody clicking a name.
 */
let root: string
const originalPaths = process.env.DAI_IMPORT_PATHS

beforeEach(() => { root = mkdtempSync(join(tmpdir(), 'dai-cand-')) })
afterEach(() => {
  rmSync(root, { recursive: true, force: true })
  if (originalPaths === undefined) delete process.env.DAI_IMPORT_PATHS
  else process.env.DAI_IMPORT_PATHS = originalPaths
})

const file = (path: string, bytes: number) => {
  mkdirSync(join(path, '..'), { recursive: true })
  writeFileSync(path, Buffer.alloc(bytes))
}

describe('models already on this machine', () => {
  it('finds the swift-transformers layout', () => {
    const cache = join(root, 'a')
    file(join(cache, 'mlx-community', 'Qwen2.5-7B-Instruct-4bit', 'weights.safetensors'), 1000)
    process.env.DAI_IMPORT_PATHS = cache
    return localCandidates().then((found) => {
      expect(found.map((c) => c.id)).toEqual(['mlx-community/Qwen2.5-7B-Instruct-4bit'])
    })
  })

  it('finds the Python hub layout, which spells the id differently', async () => {
    // models--org--repo rather than org/repo. A copy in the wrong layout is a
    // directory that looks right and is never found by the runtime, so both
    // have to be recognised here or half the machine's models are invisible.
    const cache = join(root, 'b')
    file(join(cache, 'models--mlx-community--Llama-3.2-3B-Instruct-4bit', 'blobs', 'x'), 500)
    process.env.DAI_IMPORT_PATHS = cache
    const found = await localCandidates()
    expect(found.map((c) => c.id)).toEqual(['mlx-community/Llama-3.2-3B-Instruct-4bit'])
  })

  it('does not count a symlinked file twice', async () => {
    // The Python hub keeps each file once under blobs/ and again as a symlink
    // under snapshots/. Following them reported a 1.8GB model as 3.6GB, and a
    // size used to decide whether a machine can hold a model has to be right.
    const cache = join(root, 'c')
    const model = join(cache, 'models--org--model')
    file(join(model, 'blobs', 'abc123'), 1000)
    mkdirSync(join(model, 'snapshots', 'rev1'), { recursive: true })
    symlinkSync(join(model, 'blobs', 'abc123'), join(model, 'snapshots', 'rev1', 'weights.bin'))

    process.env.DAI_IMPORT_PATHS = cache
    const found = await localCandidates()
    expect(found[0]!.sizeBytes).toBe(1000)
  })

  it('offers the same weights once when they sit in two caches', async () => {
    // Common, and it read as two different models with two different sizes to
    // anybody who did not already know the two layouts.
    const first = join(root, 'first')
    const second = join(root, 'second')
    file(join(first, 'org', 'model', 'w.bin'), 100)
    file(join(second, 'models--org--model', 'w.bin'), 100)

    process.env.DAI_IMPORT_PATHS = `${first}:${second}`
    const found = await localCandidates()
    expect(found).toHaveLength(1)
    expect(found[0]!.path).toContain('first')
  })

  it('reports nothing rather than failing when a cache does not exist', async () => {
    process.env.DAI_IMPORT_PATHS = join(root, 'nothing-here')
    expect(await localCandidates()).toEqual([])
  })
})

describe('the combined list', () => {
  it('puts local models before ones that would be downloaded', async () => {
    const cache = join(root, 'd')
    file(join(cache, 'org', 'zzz-local', 'w.bin'), 10)
    process.env.DAI_IMPORT_PATHS = cache

    const all = await candidates(new Set())
    expect(all[0]!.source).toBe('local')
    expect(all.some((c) => c.source === 'remote')).toBe(true)
  })

  it('marks what is registered rather than hiding it', async () => {
    // Hiding it is worse: somebody looking for a model they know they imported
    // and not finding it will import it again.
    process.env.DAI_IMPORT_PATHS = join(root, 'empty')
    const all = await candidates(new Set(['mlx-community/Qwen2.5-7B-Instruct-4bit']))
    const it2 = all.find((c) => c.id === 'mlx-community/Qwen2.5-7B-Instruct-4bit')
    expect(it2?.registered).toBe(true)
  })

  it('does not offer a download for something already on disk', async () => {
    // The 32B is both a curated suggestion and already here. Listing it twice
    // would offer an eighteen gigabyte download of a file on the disk.
    const cache = join(root, 'e')
    file(join(cache, 'mlx-community', 'Qwen2.5-7B-Instruct-4bit', 'w.bin'), 10)
    process.env.DAI_IMPORT_PATHS = cache

    const all = await candidates(new Set())
    const matches = all.filter((c) => c.id === 'mlx-community/Qwen2.5-7B-Instruct-4bit')
    expect(matches).toHaveLength(1)
    expect(matches[0]!.source).toBe('local')
  })
})
