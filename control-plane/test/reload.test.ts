import { execFileSync } from 'node:child_process'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

/**
 * Replacing a running daemon, against a launchctl that behaves like the real one.
 *
 * `launchctl bootout` is asynchronous - it returns when the job has been asked
 * to stop, not when it has stopped - and this daemon holds a long-poll
 * connection, so it lingers. Bootstrapping into a label that still exists fails
 * with `5: Input/output error`, and because bootout had already succeeded, the
 * machine was left with no daemon at all while every earlier step of the
 * install reported success.
 *
 * The installer had never been run twice on the same machine, so nothing had
 * met this. A fleet that cannot be upgraded in place is not a fleet, which
 * makes this worth a test with a fake launchctl rather than a real one.
 */
describe('reloading a launchd job', () => {
  const script = join(process.cwd(), '..', 'agent', 'packaging', 'reload-daemon.sh')
  let dir: string

  /**
   * A launchctl that unloads lazily, like the real one.
   *
   * `print` keeps succeeding until `unload-after` calls have gone by, which is
   * the window the real race lives in. Every invocation is appended to a log so
   * the test can assert ordering, which is the whole property at issue.
   */
  const fakeLaunchctl = (unloadAfter: number, bootstrapFails = false) => `#!/bin/bash
echo "$@" >> "${dir}/calls"
case "$1" in
  bootout) echo 0 > "${dir}/booted-out"; echo 0 > "${dir}/prints"; exit 0 ;;
  print)
    [ -f "${dir}/booted-out" ] || exit 0
    n=$(cat "${dir}/prints" 2>/dev/null || echo 0)
    echo $((n + 1)) > "${dir}/prints"
    [ -f "${dir}/bootstrapped" ] && exit 0
    [ "$n" -ge ${unloadAfter} ] && exit 1
    exit 0 ;;
  bootstrap)
    ${bootstrapFails ? 'exit 5' : ''}
    if [ -f "${dir}/prints" ] && [ "$(cat "${dir}/prints")" -lt ${unloadAfter} ]; then
      echo "Bootstrap failed: 5: Input/output error" >&2; exit 5
    fi
    touch "${dir}/bootstrapped"; exit 0 ;;
esac
exit 0
`

  const run = (unloadAfter: number, bootstrapFails = false, timeout = '5') => {
    writeFileSync(join(dir, 'launchctl'), fakeLaunchctl(unloadAfter, bootstrapFails))
    chmodSync(join(dir, 'launchctl'), 0o755)
    return execFileSync('bash', [script, 'system', 'com.dai.agent', '/tmp/x.plist', timeout], {
      env: { ...process.env, PATH: `${dir}:${process.env.PATH}` },
      encoding: 'utf8', stdio: 'pipe',
    })
  }

  const calls = () => readFileSync(join(dir, 'calls'), 'utf8').trim().split('\n')

  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), 'dai-reload-')) })
  afterEach(() => { rmSync(dir, { recursive: true, force: true }) })

  it('waits for the old job to go before starting the new one', () => {
    // The defect exactly: bootstrap issued while the label still existed.
    run(3)
    const order = calls()
    const bootstrapAt = order.findIndex(c => c.startsWith('bootstrap'))
    const printsBefore = order.slice(0, bootstrapAt).filter(c => c.startsWith('print'))
    expect(bootstrapAt).toBeGreaterThan(0)
    expect(printsBefore.length).toBeGreaterThanOrEqual(3)
  })

  it('replaces a job that unloads instantly', () => {
    // The first install on a clean machine, which is the only path that had
    // ever been exercised.
    run(0)
    expect(calls().filter(c => c.startsWith('bootstrap'))).toHaveLength(1)
  })

  it('refuses to give up silently when the old job will not go', () => {
    // Better to leave the machine as it is and say so than to report success
    // over a daemon that never came back.
    expect(() => run(999, false, '2')).toThrow(/did not unload/)
  })

  it('fails loudly when launchd accepts the plist but starts nothing', () => {
    // bootstrap exiting 0 is not evidence the daemon is running, and an
    // installer that treats it as such is how a machine reports healthy while
    // serving nothing.
    expect(() => run(0, true)).toThrow()
  })
})
