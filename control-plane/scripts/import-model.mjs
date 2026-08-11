#!/usr/bin/env node
//
// Register a model directory in the catalogue.
//
// Usage:
//   node scripts/import-model.mjs <dir> --id <model-id> --runtime mlx --kind generate \
//        [--context 32768] [--quant 4bit] [--family hermes-qwen] \
//        [--url https://localhost:8452] [--session <user-id>]
//
// This is what hand-staging was standing in for. Weights were copied machine to
// machine with scp and checked by reading file sizes off a terminal, which
// cannot distinguish a complete file from a truncated one that stopped on a
// block boundary - and a truncated shard surfaces much later as a corrupt-model
// crash on whichever machine loads it first.
//
// Hashing is per file rather than per model on purpose: a 17GB model is four
// shards, and knowing which one is wrong is the difference between refetching
// 5GB and refetching all of it.
import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { readdir, stat } from 'node:fs/promises'
import { join, relative } from 'node:path'

const args = process.argv.slice(2)
const dir = args.find((a) => !a.startsWith('--'))
const flag = (name, fallback = null) => {
  const i = args.indexOf(`--${name}`)
  return i === -1 ? fallback : args[i + 1]
}

if (!dir) {
  console.error('usage: import-model.mjs <dir> --id <model-id> --runtime mlx --kind generate')
  process.exit(2)
}

const id = flag('id')
const runtime = flag('runtime', 'mlx')
const kind = flag('kind', 'generate')
const url = flag('url', process.env.DAI_URL ?? 'https://localhost:8452')
const session = flag('session', process.env.DAI_SESSION)

if (!id) { console.error('--id is required'); process.exit(2) }
if (!session) { console.error('--session (or DAI_SESSION) is required'); process.exit(2) }

/** Every file under dir, relative, skipping the caches that are not weights. */
async function walk(base, prefix = '') {
  const out = []
  for (const entry of await readdir(join(base, prefix), { withFileTypes: true })) {
    // .cache holds the hub's own bookkeeping and differs between machines that
    // hold identical weights, so including it would make two correct copies
    // disagree.
    if (entry.name.startsWith('.')) continue
    const rel = prefix ? join(prefix, entry.name) : entry.name
    if (entry.isDirectory()) out.push(...await walk(base, rel))
    else out.push(rel)
  }
  return out
}

const sha256 = (path) => new Promise((resolve, reject) => {
  const h = createHash('sha256')
  createReadStream(path)
    .on('data', (c) => h.update(c))
    .on('end', () => resolve(h.digest('hex')))
    .on('error', reject)
})

const paths = (await walk(dir)).sort()
if (paths.length === 0) { console.error(`no files under ${dir}`); process.exit(1) }

const files = []
let done = 0
for (const rel of paths) {
  const full = join(dir, rel)
  const { size } = await stat(full)
  files.push({ path: rel, sizeBytes: size, sha256: await sha256(full) })
  done += size
  process.stderr.write(`\r  hashed ${(done / 1e9).toFixed(1)}GB across ${files.length} files`)
}
process.stderr.write('\n')

const body = {
  id, runtime, kind, files,
  contextLength: flag('context') ? Number(flag('context')) : null,
  quantization: flag('quant'),
  family: flag('family'),
}

// The dev control plane uses its own CA, so trust has to be relaxed for this
// one call rather than for the process that serves anything.
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'
const res = await fetch(`${url}/admin/v1/models`, {
  method: 'POST',
  headers: { authorization: `Bearer ${session}`, 'content-type': 'application/json' },
  body: JSON.stringify(body),
})

if (!res.ok) {
  console.error(`${res.status}: ${await res.text()}`)
  process.exit(1)
}
const m = await res.json()
console.log(`registered ${m.id}: ${m.fileCount} files, ${(m.sizeBytes / 1e9).toFixed(1)}GB`)
