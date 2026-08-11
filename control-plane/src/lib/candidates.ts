import { lstat, readdir } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'

/**
 * Models that could be added to the fleet.
 *
 * Deliberately a shortlist and not a mirror of a public hub. Presenting
 * everything on HuggingFace would be a worse answer than presenting nothing:
 * most of it will not run on Apple Silicon, most of the rest will not fit the
 * memory ceiling, and picking from thousands is not a choice anybody can make
 * well.
 *
 * Local candidates come first, and that ordering is the substantive part. A
 * model already on this machine costs a copy; one from the internet costs the
 * building's uplink and contradicts the reason this system exists at all. The
 * fleet's weights should reach the internet once per site, deliberately, and
 * never as a side effect of somebody clicking a name in a list.
 */
export interface Candidate {
  id: string
  source: 'local' | 'remote'
  path?: string | null
  sizeBytes?: number | null
  kind: 'generate' | 'embed'
  contextLength?: number | null
  family?: string | null
  note?: string | null
  registered: boolean
}

/**
 * Directories searched for models already on this machine.
 *
 * Both layouts, because they are not the same: swift-transformers writes
 * `<base>/models/<org>/<repo>`, the Python hub client writes
 * `models--org--repo`, and a copy in the wrong one is a directory that looks
 * right and is never found.
 */
export function localSearchPaths(): string[] {
  const configured = process.env.DAI_IMPORT_PATHS
  if (configured) return configured.split(':').filter(Boolean)
  return [
    join(homedir(), 'Library', 'Caches', 'models'),
    join(homedir(), '.cache', 'huggingface', 'hub'),
  ]
}

/**
 * Total bytes under a directory, which is what an import would move.
 *
 * lstat rather than stat, so a symbolic link counts as a link and not as the
 * thing it points at. The Python hub layout keeps every file once under
 * `blobs/` and again as a symlink under `snapshots/`, so following them
 * reported a 1.8GB model as 3.6GB - and a size used to decide whether a machine
 * can hold a model is one that has to be right.
 */
async function sizeOf(dir: string): Promise<number> {
  let total = 0
  const walk = async (d: string) => {
    let entries
    try { entries = await readdir(d, { withFileTypes: true }) } catch { return }
    for (const e of entries) {
      if (e.name.startsWith('.')) continue
      const full = join(d, e.name)
      if (e.isDirectory()) await walk(full)
      else if (!e.isSymbolicLink()) {
        try { total += (await lstat(full)).size } catch { /* unreadable */ }
      }
    }
  }
  await walk(dir)
  return total
}

/**
 * Models found on this machine's disk.
 *
 * Deduplicated by id, first search path winning. The same weights commonly sit
 * in two caches at once, and offering both meant one model appearing twice with
 * two different sizes, which reads as two different models to anybody who did
 * not already know the layouts.
 */
export async function localCandidates(): Promise<Candidate[]> {
  const out: Candidate[] = []
  const seen = new Set<string>()
  const add = (c: Candidate) => {
    if (seen.has(c.id)) return
    seen.add(c.id)
    out.push(c)
  }
  for (const base of localSearchPaths()) {
    let entries
    try { entries = await readdir(base, { withFileTypes: true }) } catch { continue }
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith('.')) continue

      // models--org--repo, the Python hub layout.
      if (entry.name.startsWith('models--')) {
        const id = entry.name.slice('models--'.length).replace(/--/g, '/')
        const path = join(base, entry.name)
        add({ id, source: 'local', path, sizeBytes: await sizeOf(path),
          kind: 'generate', registered: false })
        continue
      }

      // org/repo, the swift-transformers layout. The directory is the org, so
      // the models are one level down.
      let repos
      try { repos = await readdir(join(base, entry.name), { withFileTypes: true }) } catch {
        continue
      }
      for (const repo of repos) {
        if (!repo.isDirectory() || repo.name.startsWith('.')) continue
        const path = join(base, entry.name, repo.name)
        add({ id: `${entry.name}/${repo.name}`, source: 'local', path,
          sizeBytes: await sizeOf(path), kind: 'generate', registered: false })
      }
    }
  }
  return out
}

/**
 * The curated remote shortlist.
 *
 * Chosen to span the fleet rather than to be comprehensive: something every
 * machine can hold, something for a 16GB laptop, and something that needs a
 * Max or better. Sizes are approximate on purpose - they are here to answer
 * "will this fit" before a download, not to be authoritative, and the real
 * numbers are recorded from the files once a model is imported.
 */
export const REMOTE_CANDIDATES: Candidate[] = [
  {
    id: 'mlx-community/Qwen2.5-0.5B-Instruct-4bit', source: 'remote', sizeBytes: 3e8,
    kind: 'generate', contextLength: 32768, family: 'hermes-qwen',
    note: 'Fits anywhere. Useful for testing the fleet, not for answers.',
    registered: false,
  },
  {
    id: 'mlx-community/Llama-3.2-3B-Instruct-4bit', source: 'remote', sizeBytes: 1.8e9,
    kind: 'generate', contextLength: 32768, family: 'llama-3',
    note: 'Smallest model that holds a conversation. Runs on a 16GB machine.',
    registered: false,
  },
  {
    id: 'mlx-community/Qwen2.5-7B-Instruct-4bit', source: 'remote', sizeBytes: 4.3e9,
    kind: 'generate', contextLength: 32768, family: 'hermes-qwen',
    note: 'The general default. Every machine in this fleet can hold it.',
    registered: false,
  },
  {
    id: 'mlx-community/Qwen2.5-Coder-32B-Instruct-4bit', source: 'remote', sizeBytes: 1.84e10,
    kind: 'generate', contextLength: 32768, family: 'hermes-qwen',
    note: 'Needs 48GB or more. Currently the only model this fleet serves.',
    registered: false,
  },
  {
    id: 'mlx-community/Llama-3.3-70B-Instruct-4bit', source: 'remote', sizeBytes: 4e10,
    kind: 'generate', contextLength: 32768, family: 'llama-3',
    note: 'Max or Ultra only. Above the ceiling on every other machine here.',
    registered: false,
  },
]

/**
 * Everything that could be added, local first, with what is already registered
 * marked rather than hidden.
 *
 * Hidden would be worse: somebody looking for a model they know they imported
 * and not finding it will import it again.
 */
export async function candidates(registered: Set<string>): Promise<Candidate[]> {
  const local = await localCandidates()
  const seen = new Set(local.map((c) => c.id))
  const remote = REMOTE_CANDIDATES.filter((c) => !seen.has(c.id))
  return [...local, ...remote]
    .map((c) => ({ ...c, registered: registered.has(c.id) }))
    .sort((a, b) => (a.source === b.source
      ? a.id.localeCompare(b.id)
      : a.source === 'local' ? -1 : 1))
}
