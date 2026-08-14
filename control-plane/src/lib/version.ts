/**
 * What this control plane is, so a fleet can be told apart from itself.
 *
 * The agent has answered this since AgentVersion existed: the packaged version
 * reaches the binary through the plist and every node reports it. The control
 * plane wrote a VERSION file into its own payload and then nothing ever read it,
 * so the one machine an operator actually attends to was the one that could not
 * say what it was running. `package.json` said 0.1.0 through four releases,
 * because a private package's version field is not something anybody updates.
 *
 * The file beside the payload is the source of truth rather than package.json,
 * for the same reason the agent trusts its plist: it is written by the builder
 * from the version the release was named after, so it cannot drift from the
 * package it arrived in. package.json is a manifest for npm, and npm is not how
 * this is deployed.
 *
 * A working tree answers "dev", which is honest and deliberately not a version
 * number - an unversioned build must not be able to masquerade as a release.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * Two directories up from the compiled file, which is the payload root.
 *
 * dist/lib/version.js -> ../../VERSION, beside dist/, openapi/, ui/ and db/,
 * exactly like every other runtime path here. Running from source through tsx
 * resolves to control-plane/VERSION, which does not exist in a checkout - so
 * development answers "dev" through the same code path rather than a special
 * case that only development takes.
 */
const VERSION_FILE = join(import.meta.dirname, '..', '..', 'VERSION')

export const version: string = (() => {
  try {
    const v = readFileSync(VERSION_FILE, 'utf8').trim()
    return v.length > 0 ? v : 'dev'
  } catch {
    // No file is the normal case in a working tree, not a fault worth logging
    // on every start.
    return 'dev'
  }
})()

/**
 * Whether this build was named by a release.
 *
 * Worth asking separately: "dev" in a fleet view means somebody deployed from a
 * checkout, which is a different problem from being a version behind.
 */
export const isRelease: boolean = version !== 'dev'
