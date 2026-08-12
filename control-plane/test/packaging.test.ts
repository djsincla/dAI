import { execSync, spawnSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
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
    .replace(/@VERSION@/g, '1.2.3')

  it('leaves no placeholder unsubstituted', () => {
    // An unreplaced @NAME@ is a literal string in a live configuration, which
    // fails as a path that does not exist rather than as a template error.
    expect(render().match(/@[A-Z_]+@/g) ?? []).toEqual([])
  })

  it('renders a node that carries no GPU model', () => {
    // An ANE-only node is an ordinary node: a 16GB Mac holds an embedding
    // model and nothing larger. The installer refused to run without a GPU
    // model, so the smallest machines in a fleet - the ones most likely to be
    // idle - could not be enrolled at all.
    const bare = template
      .replace(/@MODEL@/g, '-')
      .replace(/@[A-Z_]+@/g, 'x')
    const dir = mkdtempSync(join(tmpdir(), 'dai-plist-'))
    const path = join(dir, 'com.dai.agent.plist')
    writeFileSync(path, bare)
    expect(() => execSync(`plutil -lint ${path}`, { stdio: 'pipe' })).not.toThrow()
    // The placeholder has to survive as an argument. An empty <string> would
    // shift every argument after it by one position.
    const args = execSync(`plutil -extract ProgramArguments json -o - ${path}`)
    expect(JSON.parse(args.toString())).toContain('-')
    rmSync(dir, { recursive: true, force: true })
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

describe('the updater launchd job', () => {
  const template = readFileSync(
    join(process.cwd(), '..', 'agent', 'packaging', 'com.dai.updater.plist.in'), 'utf8')

  const render = () => template
    .replace(/@BINARY@/g, '/usr/local/libexec/dai/dai-agent')
    .replace(/@URL@/g, 'https://control-plane:8452')
    .replace(/@WAIT@/g, '300')
    .replace(/@LOG_DIR@/g, '/var/log/dai')
    .replace(/@IDENTITY_DIR@/g, '/var/db/dai/identity')

  it('leaves no placeholder unsubstituted', () => {
    expect(render().match(/@[A-Z_]+@/g) ?? []).toEqual([])
  })

  it('is valid enough for launchd to parse', () => {
    const dir = mkdtempSync(join(tmpdir(), 'dai-updater-'))
    const path = join(dir, 'com.dai.updater.plist')
    writeFileSync(path, render())
    expect(() => execSync(`plutil -lint ${path}`, { stdio: 'pipe' })).not.toThrow()
    rmSync(dir, { recursive: true, force: true })
  })

  it('runs as root, which is the whole reason it is a separate job', () => {
    // The agent runs as a service account that cannot write to the directory
    // its own binary lives in. Giving it that ability would let a process which
    // executes fleet-supplied payloads rewrite itself.
    expect(render()).not.toContain('<key>UserName</key>')
  })

  it('runs often enough to rescue a machine it broke', () => {
    // An upgrade leaves a marker and the next run decides whether to roll back.
    // An interval longer than the verification window would leave a dead node
    // dead until somebody noticed.
    const interval = Number(render().match(
      /<key>StartInterval<\/key>\s*<integer>(\d+)<\/integer>/)?.[1])
    expect(interval).toBeGreaterThan(0)
    expect(interval).toBeLessThan(300)
  })

  it('starts when the machine boots', () => {
    // A machine that was rolled back mid-reboot has to finish the job on the
    // way up, or it comes back running a binary nobody committed to.
    expect(render()).toContain('<key>RunAtLoad</key>')
  })
})

/**
 * Uninstalling has to actually finish.
 *
 * These run the script rather than reading it, because every bug it had was
 * control flow rather than wording. It removed the agent and left the root
 * updater loaded, so a machine that had been given back kept a privileged job
 * polling the fleet. It left the pending-upgrade marker behind, which the next
 * install reads before anything else and answers by restoring the rollback
 * binary over the version just installed. And a `set -e` on a bootout that
 * fails whenever the menu bar is not loaded - a headless Mac, or any machine
 * where the installer skipped the app - stopped the whole script after the
 * agent was gone and before the identity was, so `--purge` reported nothing
 * and kept the one thing it exists to delete.
 *
 * A real root is faked and a real script is run against it. Asserting on the
 * text would have missed all three.
 */
describe('uninstall.sh', () => {
  const script = join(process.cwd(), '..', 'agent', 'packaging', 'uninstall.sh')

  /** Runs the uninstaller against a temporary root with launchd stubbed out. */
  const uninstall = (opts: {
    purge?: boolean
    /** Polls before the updater admits it has unloaded. */
    updaterLingers?: number
    /** A machine with no menu bar job is the common case, not the odd one. */
    menubarLoaded?: boolean
  } = {}) => {
    const root = mkdtempSync(join(tmpdir(), 'dai-uninstall-'))
    const { updaterLingers = 0, menubarLoaded = false, purge = false } = opts

    for (const d of ['usr/local/libexec/dai', 'var/db/dai/identity', 'var/log/dai',
                     'Library/LaunchDaemons', 'Library/LaunchAgents', 'Applications/dAI.app',
                     'bin']) {
      mkdirSync(join(root, d), { recursive: true })
    }
    const files = [
      'Library/LaunchDaemons/com.dai.agent.plist',
      'Library/LaunchDaemons/com.dai.updater.plist',
      'Library/LaunchAgents/com.dai.menubar.plist',
      'var/db/dai/pending-upgrade.json',
      'var/db/dai/dai-agent.rollback',
      'var/db/dai/identity/node.crt',
      'usr/local/libexec/dai/dai-agent',
    ]
    for (const f of files) writeFileSync(join(root, f), 'x')

    // launchctl: counts how many times it is asked whether the updater is still
    // there, so the wait loop is exercised rather than assumed.
    writeFileSync(join(root, 'bin', 'launchctl'), `#!/bin/bash
echo "$1 $2" >> "${root}/calls"
if [[ "$1" == print && "$2" == system/com.dai.updater ]]; then
  n=$(cat "${root}/polls" 2>/dev/null || echo 0); echo $((n+1)) > "${root}/polls"
  [[ $n -lt ${updaterLingers} ]] && exit 0 || exit 1
fi
[[ "$1" == print ]] && exit 1
[[ "$1" == bootout && "$2" == gui/* ]] && exit ${menubarLoaded ? 0 : 1}
exit 0
`)
    writeFileSync(join(root, 'bin', 'stat'), '#!/bin/bash\necho 501\n')
    writeFileSync(join(root, 'bin', 'id'), '#!/bin/bash\nexit 0\n')
    for (const c of ['sysadminctl', 'dscl', 'pkill']) {
      writeFileSync(join(root, 'bin', c), `#!/bin/bash\necho "${c} $*" >> "${root}/calls"\nexit 0\n`)
    }
    for (const c of ['launchctl', 'stat', 'id', 'sysadminctl', 'dscl', 'pkill']) {
      chmodSync(join(root, 'bin', c), 0o755)
    }

    const rewritten = readFileSync(script, 'utf8')
      .replace(/^(BINARY_DIR|IDENTITY_DIR|STATE_DIR|LOG_DIR|PLIST|UPDATER_PLIST|PENDING|ROLLBACK)=/gm,
               `$1=${root}`)
      .replace(/^CONFIG_DIR=.*$/m, `CONFIG_DIR="${root}/Library/Application Support/dAI"`)
      .replace(/\/Library\/LaunchAgents/g, `${root}/Library/LaunchAgents`)
      .replace(/\/Applications\/dAI\.app/g, `${root}/Applications/dAI.app`)
      .replace(/^\[\[ \$EUID -eq 0 \]\].*$/m, 'true')
      .replace(/\bsleep 1\b/g, 'true')

    // A path this missed would be a path on the machine running the tests.
    const escaped = root.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const stray = rewritten.split('\n').filter(l =>
      new RegExp(`(^|["= ])/(Library|Applications|usr/local|var/db|var/log)`).test(l) &&
      !new RegExp(escaped).test(l))
    expect(stray, 'a real system path survived rewriting').toEqual([])

    const path = join(root, 'uninstall.sh')
    writeFileSync(path, rewritten)
    const run = spawnSync('bash', [path, ...(purge ? ['--purge'] : [])], {
      env: { ...process.env, PATH: `${join(root, 'bin')}:${process.env.PATH}` },
      encoding: 'utf8',
    })
    const survives = (f: string) => existsSync(join(root, f))
    const calls = existsSync(join(root, 'calls'))
      ? readFileSync(join(root, 'calls'), 'utf8') : ''
    const cleanup = () => rmSync(root, { recursive: true, force: true })
    return { run, survives, calls, cleanup }
  }

  it('unloads the root updater, not just the agent', () => {
    // Left loaded, it is a privileged job on a machine whose owner was told
    // the agent was gone.
    const u = uninstall()
    expect(u.run.status).toBe(0)
    expect(u.calls).toContain('bootout system/com.dai.updater')
    expect(u.survives('Library/LaunchDaemons/com.dai.updater.plist')).toBe(false)
    u.cleanup()
  })

  it('waits for the updater to be gone before deleting the binary', () => {
    // bootout returns when the job has been asked to stop. An updater still
    // running is one that can reinstall the binary being removed.
    const u = uninstall({ updaterLingers: 3 })
    expect(u.run.status).toBe(0)
    expect((u.calls.match(/print system\/com\.dai\.updater/g) ?? []).length)
      .toBeGreaterThan(1)
    expect(u.survives('usr/local/libexec/dai/dai-agent')).toBe(false)
    u.cleanup()
  })

  it('refuses to remove the binary if the updater will not unload', () => {
    // Better to stop and say so than to delete the binary out from under a
    // root process that is mid-upgrade.
    const u = uninstall({ updaterLingers: 10_000 })
    expect(u.run.status).not.toBe(0)
    expect(u.run.stderr).toContain('did not unload')
    expect(u.survives('usr/local/libexec/dai/dai-agent')).toBe(true)
    u.cleanup()
  })

  it('clears an in-flight upgrade even without --purge', () => {
    // The marker outlives the binary it describes. The next install reads it
    // first, finds a deadline long past and nothing reporting in, and restores
    // the rollback over the version just installed.
    const u = uninstall()
    expect(u.survives('var/db/dai/pending-upgrade.json')).toBe(false)
    expect(u.survives('var/db/dai/dai-agent.rollback')).toBe(false)
    u.cleanup()
  })

  it('keeps the identity when not purging', () => {
    // The Enclave key cannot be recreated, so removing it means enrolling and
    // being approved again.
    const u = uninstall()
    expect(u.survives('var/db/dai/identity/node.crt')).toBe(true)
    u.cleanup()
  })

  it('finishes a --purge on a machine with no menu bar loaded', () => {
    // The regression: a failing bootout ended the script after the agent was
    // removed and before the identity was, and said nothing.
    const u = uninstall({ purge: true, menubarLoaded: false })
    expect(u.run.status).toBe(0)
    expect(u.run.stdout).toContain('Removed.')
    expect(u.survives('var/db/dai/identity/node.crt')).toBe(false)
    expect(u.calls).toContain('sysadminctl -deleteUser _dai')
    u.cleanup()
  })

  it('removes the menu bar app whether or not its job was loaded', () => {
    for (const menubarLoaded of [true, false]) {
      const u = uninstall({ menubarLoaded })
      expect(u.run.status, `menubarLoaded=${menubarLoaded}`).toBe(0)
      expect(u.survives('Library/LaunchAgents/com.dai.menubar.plist')).toBe(false)
      expect(u.survives('Applications/dAI.app')).toBe(false)
      u.cleanup()
    }
  })
})

/**
 * Installing without anybody standing at the machine.
 *
 * The .pkg used to lay files down and stop - no service account, no rendered
 * plists, nothing running - because pkgbuild was called without --scripts. Its
 * own header called it the fleet-distribution path.
 *
 * The fix is that the package's postinstall calls install.sh, which now takes
 * its site settings from a file MDM delivers rather than from arguments nobody
 * is there to type. These check the reading of that file, black-box: run the
 * real script and see how far it gets, since the message it stops on names what
 * it managed to read.
 */
describe('install.sh --config', () => {
  const script = join(process.cwd(), '..', 'agent', 'packaging', 'install.sh')

  /** Runs the installer far enough to prove what it read, and no further. */
  const run = (config: Record<string, unknown>, opts: { withCa?: boolean } = {}) => {
    const root = mkdtempSync(join(tmpdir(), 'dai-config-'))
    const path = join(root, 'config.json')
    writeFileSync(path, JSON.stringify(config, null, 2))
    if (opts.withCa !== false) writeFileSync(join(root, 'server-ca.crt'), 'CA')

    // Root is the only thing stubbed. Everything else is the real script, so
    // what is under test is the script rather than a copy of it.
    const rewritten = readFileSync(script, 'utf8')
      .replace(/^\[\[ \$EUID -eq 0 \]\].*$/m, 'true')
    const runner = join(root, 'install.sh')
    writeFileSync(runner, rewritten)
    chmodSync(runner, 0o755)

    // spawnSync rather than a throwing variant. A catch around the runner
    // swallowed a ReferenceError in this very helper and reported it as "the
    // script printed nothing", which sent me looking at the script. Returning
    // status and output plainly leaves nothing to hide behind.
    const r = spawnSync('/bin/bash', [runner, '--config', path], { encoding: 'utf8' })
    return { status: r.status, output: `${r.stdout ?? ''}${r.stderr ?? ''}` }
  }

  it('reads the url, token and certificate from the file', () => {
    // Getting as far as the build check means all three passed validation,
    // which is the whole of what the file has to supply.
    const r = run({ url: 'https://cp.example:8452', joinToken: 'jt-abc' })
    expect(r.output).toContain('no build found')
    expect(r.output).not.toContain('missing --url')
    expect(r.output).not.toContain('missing --token')
  })

  it('finds the certificate beside the config when none is named', () => {
    // How MDM will deliver the pair: two files into one directory. Requiring
    // an absolute path in the file would make the payload machine-specific.
    const r = run({ url: 'https://cp.example:8452', joinToken: 'jt-abc' })
    expect(r.output).toContain('no build found')
  })

  it('says which setting is missing rather than failing vaguely', () => {
    expect(run({ url: 'https://cp.example:8452' }).output).toContain('missing --token')
    expect(run({ joinToken: 'jt-abc' }).output).toContain('missing --url')
  })

  it('refuses a certificate that is not there', () => {
    // Rather than enrolling against a control plane it cannot verify.
    const r = run({ url: 'https://cp.example:8452', joinToken: 'jt' }, { withCa: false })
    expect(r.output).toContain('server CA not found')
  })

  it('refuses a configuration file that does not exist', () => {
    const root = mkdtempSync(join(tmpdir(), 'dai-config-'))
    const rewritten = readFileSync(script, 'utf8')
      .replace(/^\[\[ \$EUID -eq 0 \]\].*$/m, 'true')
    const runner = join(root, 'install.sh')
    writeFileSync(runner, rewritten)
    chmodSync(runner, 0o755)
    const r = spawnSync('/bin/bash', [runner, '--config', join(root, 'absent.json')],
      { encoding: 'utf8' })
    expect(r.status).not.toBe(0)
    expect(`${r.stdout ?? ''}${r.stderr ?? ''}`).toContain('no configuration at')
  })
})

describe('the package postinstall', () => {
  const script = join(process.cwd(), '..', 'agent', 'packaging', 'scripts', 'postinstall')

  it('succeeds and starts nothing when no fleet has been named', () => {
    // A daemon started with no control plane sits in a reconnect loop that
    // reads as a network fault on every machine at once. Failing the package
    // would be worse: the files are fine, and MDM may deliver the config as a
    // separate payload seconds later.
    const root = mkdtempSync(join(tmpdir(), 'dai-postinstall-'))
    const rewritten = readFileSync(script, 'utf8')
      .replace(/^BINARY_DIR=.*$/m, `BINARY_DIR=${root}/usr/local/libexec/dai`)
      .replace(/^CONFIG_DIR=.*$/m, `CONFIG_DIR="${root}/Library/Application Support/dAI"`)
      .replace(/^LOG=.*$/m, `LOG=${root}/install.log`)
    const runner = join(root, 'postinstall')
    writeFileSync(runner, rewritten)
    chmodSync(runner, 0o755)

    const r = spawnSync('/bin/bash', [runner], { encoding: 'utf8' })
    expect(r.status).toBe(0)
    const out = `${r.stdout ?? ''}${r.stderr ?? ''}`
    expect(out).toContain('installed and not running')
    // And it says exactly what to do about it, with the command to run.
    expect(out).toContain('install.sh --config')
  })
})
