import { execSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The daemon's configuration has to contain what the daemon reads.
 *
 * A generated file is code nobody compiles, and this one silently lost the
 * variable that tells the agent where its models are: the daemon looked in a
 * service account's empty home while seventeen gigabytes sat staged where the
 * installer had put them, and reported no chat model for an hour. Nothing
 * failed, nothing logged, and the template was the only place the mistake
 * existed.
 *
 * These tests render the template the way install.sh does and check the result,
 * which is the only layer where template and agent can be compared at all.
 */
describe('the generated launchd plist', () => {
  const template = readFileSync(
    join(process.cwd(), '..', 'agent', 'packaging', 'com.dai.agent.plist.in'), 'utf8')

  /** The substitutions install.sh performs, kept in the same order. */
  const render = () => template
    .replace(/@BINARY@/g, '/usr/local/libexec/dai/dai-agent')
    .replace(/@URL@/g, 'https://control-plane:8452')
    .replace(/@MODEL@/g, 'mlx-community/Some-Model-4bit')
    .replace(/@ANE@/g, '/var/db/dai/models/ane_embed.mlpackage')
    .replace(/@IDENTITY_DIR@/g, '/var/db/dai/identity')
    .replace(/@STATE_DIR@/g, '/var/db/dai')
    .replace(/@LOG_DIR@/g, '/var/log/dai')
    .replace(/@USER@/g, '_dai')
    .replace(/@MODEL_DIR@/g, '/var/db/dai')
    .replace(/@PROMOTE@/g, '300')

  it('leaves no placeholder unsubstituted', () => {
    // An unreplaced @NAME@ is a literal string in a live configuration, which
    // fails as a path that does not exist rather than as a template error.
    expect(render().match(/@[A-Z_]+@/g) ?? []).toEqual([])
  })

  it('is valid enough for launchd to parse', () => {
    const dir = mkdtempSync(join(tmpdir(), 'dai-plist-'))
    const path = join(dir, 'com.dai.agent.plist')
    writeFileSync(path, render())
    // plutil is what launchd uses; a plist it rejects is a daemon that never
    // starts, reported as nothing at all.
    expect(() => execSync(`plutil -lint ${path}`, { stdio: 'pipe' })).not.toThrow()
    rmSync(dir, { recursive: true, force: true })
  })

  /**
   * Every variable the agent reads from its environment.
   *
   * Deliberately a list rather than a scan of the source: the point is that
   * someone adding a variable has to add it here too, and notice they are
   * changing what a deployed daemon needs.
   */
  const required = [
    // Where the identity lives. NSHomeDirectory reads the password database
    // rather than HOME, so a service account cannot be pointed anywhere
    // without this.
    'DAI_IDENTITY_DIR',
    // The hub base. Absent, the agent searched a service account's empty home
    // and served nothing.
    'DAI_MODEL_DIR',
  ]

  it.each(required)('sets %s, which the agent reads', (variable) => {
    expect(render()).toContain(`<key>${variable}</key>`)
  })

  it('runs as a service account rather than root', () => {
    // The work is inference; none of it needs root, and the daemon executes
    // payloads the fleet sends it.
    expect(render()).toContain('<key>UserName</key>')
    expect(render()).not.toContain('<string>root</string>')
  })

  it('does not pin the process to background scheduling', () => {
    // ProcessType applies for the life of the process, so a daemon pinned to
    // Background cannot promote itself when the user goes home - which is when
    // nearly all the capacity is. Measured at 2.4x on sustained GPU work and
    // ~26x on bursty ANE items.
    const processType = render().match(/<key>ProcessType<\/key>\s*<string>(\w+)<\/string>/)
    expect(processType?.[1]).toBe('Standard')
  })

  it('restarts if the agent dies', () => {
    // A node that stops and stays stopped is indistinguishable from a node
    // that was never installed, and it took a hand-run agent dying to notice
    // the supervisor was the only thing providing this.
    expect(render()).toContain('<key>KeepAlive</key>')
    expect(render()).toContain('<key>ThrottleInterval</key>')
  })
})
