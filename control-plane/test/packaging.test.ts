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
    // Empty on a machine nobody has named an interface for, which is the
    // common case and still has to render.
    .replace(/@PIPELINE_IF@/g, 'bridge0')
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

describe('installing over files the package already laid down', () => {
  const script = join(process.cwd(), '..', 'agent', 'packaging', 'install.sh')

  /**
   * The case a .pkg always hits and nothing tested.
   *
   * The package puts the binaries in /usr/local/libexec/dai and then the
   * postinstall runs install.sh with --build pointing at that same directory,
   * so the copy is a file onto itself. `install` calls that an error rather
   * than a no-op - "are the same file" - and under `set -e` it ended the
   * script, which failed the whole installation on a real machine.
   *
   * The tests above stop at "no build found" and never reach the copy, which is
   * why they all passed while the package did not install.
   */
  const runWithBuildEqualToDestination = () => {
    const root = mkdtempSync(join(tmpdir(), 'dai-samedir-'))
    const binDir = join(root, 'usr/local/libexec/dai')
    mkdirSync(binDir, { recursive: true })
    writeFileSync(join(binDir, 'dai-agent'), '#!/bin/bash\ntrue\n')
    chmodSync(join(binDir, 'dai-agent'), 0o755)
    writeFileSync(join(root, 'server-ca.crt'), 'CA')

    // Everything past the copy is launchd and directory surgery, so the script
    // is stopped just after it - what is under test is whether it gets there.
    const rewritten = readFileSync(script, 'utf8')
      .replace(/^\[\[ \$EUID -eq 0 \]\].*$/m, 'true')
      .replace(/^BINARY_DIR=.*$/m, `BINARY_DIR=${binDir}`)
      .replace(/^(IDENTITY_DIR|STATE_DIR|LOG_DIR|MODEL_DIR)=/gm, `$1=${root}`)
      .replace(/^install -d -m 700 "\$STATE_DIR".*$/m, 'echo REACHED_THE_END; exit 0')

    const runner = join(root, 'install.sh')
    writeFileSync(runner, rewritten)
    chmodSync(runner, 0o755)
    return spawnSync('/bin/bash', [runner, '--url', 'https://cp:8452', '--token', 'jt',
                                   '--ca', join(root, 'server-ca.crt'), '--build', binDir],
      { encoding: 'utf8' })
  }

  it('does not fail when the source and destination are the same directory', () => {
    const r = runWithBuildEqualToDestination()
    const out = `${r.stdout ?? ''}${r.stderr ?? ''}`
    expect(out).not.toContain('are the same file')
    expect(out).toContain('already in place')
    expect(out).toContain('REACHED_THE_END')
    expect(r.status).toBe(0)
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

/**
 * The control plane's own package.
 *
 * It used to run from a working tree: `npx tsx src/server.ts`, Postgres in
 * compose, TLS from a script somebody remembered. None of that can be given to
 * a machine somebody else owns.
 */
describe('the control plane launchd plist', () => {
  const template = readFileSync(
    join(process.cwd(), 'packaging', 'com.dai.control.plist.in'), 'utf8')

  const render = () => template
    .replace(/@BINARY_DIR@/g, '/usr/local/libexec/dai-control')
    .replace(/@STATE_DIR@/g, '/var/db/dai-control')
    .replace(/@LOG_DIR@/g, '/var/log/dai-control')
    .replace(/@USER@/g, '_daictl')
    .replace(/@DATABASE_URL@/g, 'postgres://dai:dai@localhost:5432/dai')
    .replace(/@PORT@/g, '8452')
    .replace(/@AGENT_CIDRS@/g, '')
    .replace(/@ADMIN_CIDRS@/g, '10.0.0.0/8')
    .replace(/@MONITOR_CIDRS@/g, '127.0.0.1/32')

  it('leaves no placeholder unsubstituted', () => {
    expect(render().match(/@[A-Z_]+@/g) ?? []).toEqual([])
  })

  it('runs the bundled runtime, not whatever node is on the machine', () => {
    // A homebrew node is a 67KB shim against dylibs under /opt/homebrew, so a
    // package that used `node` from PATH would work only where homebrew had
    // installed the same versions.
    expect(render()).toContain('<string>/usr/local/libexec/dai-control/node</string>')
    expect(render()).toContain('dist/server.js')
  })

  it('does not run as root', () => {
    // It holds the private key of the authority that signs every node's
    // identity. An unprivileged account owning exactly that is a smaller
    // target than root owning everything.
    expect(render()).toContain('<string>_daictl</string>')
    expect(render()).not.toMatch(/<key>UserName<\/key>\s*<string>root<\/string>/)
  })

  it('points TLS_CA at the server CA, not the node CA', () => {
    // The one setting a deployment gets wrong invisibly. TLS_CA is read twice:
    // the listener adds it to the certificates it accepts from clients, and the
    // enrolment route hands it to agents as the authority to pin. Only the
    // second decides whether a fleet works, and its default is the node CA -
    // which is why agents in testing needed the right file copied by hand.
    expect(render()).toContain('certs/srv-ca.crt')
    expect(render()).not.toMatch(/TLS_CA<\/key>\s*<string>[^<]*certs\/ca\.crt</)
  })

  it('keeps the node CA somewhere other than the server certificates', () => {
    // Two authorities that must not be conflated: anything trusted to talk to
    // the fleet would otherwise also be able to impersonate a node.
    expect(render()).toMatch(/CA_DIR<\/key>\s*<string>\/var\/db\/dai-control\/node-ca</)
  })

  it('restarts if it stops', () => {
    // A fleet that cannot reach its control plane stops getting work and every
    // machine in it looks broken.
    expect(render()).toMatch(/KeepAlive<\/key>\s*<true\/>/)
  })
})

describe('the control plane postinstall', () => {
  const script = join(process.cwd(), 'packaging', 'scripts', 'postinstall')

  it('succeeds and starts nothing when no database has been named', () => {
    // The control plane cannot invent a database, and one started without a
    // reachable Postgres restarts in a loop under KeepAlive - filling a log
    // with the same failure rather than saying it once.
    const root = mkdtempSync(join(tmpdir(), 'dai-ctl-postinstall-'))
    const rewritten = readFileSync(script, 'utf8')
      .replace(/^BINARY_DIR=.*$/m, `BINARY_DIR=${root}/usr/local/libexec/dai-control`)
      .replace(/^CONFIG_DIR=.*$/m, `CONFIG_DIR="${root}/Library/Application Support/dAI"`)
      .replace(/^LOG=.*$/m, `LOG=${root}/install.log`)
    const runner = join(root, 'postinstall')
    writeFileSync(runner, rewritten)
    chmodSync(runner, 0o755)

    const r = spawnSync('/bin/bash', [runner], { encoding: 'utf8' })
    expect(r.status).toBe(0)
    const out = `${r.stdout ?? ''}${r.stderr ?? ''}`
    expect(out).toContain('installed and not running')
    expect(out).toContain('--db postgres://')
  })
})

describe('the control plane uninstaller', () => {
  const source = readFileSync(join(process.cwd(), 'packaging', 'uninstall.sh'), 'utf8')

  it('never touches the database', () => {
    // It holds the fleet: every node's identity, the jobs, the audit log.
    // Dropping it because somebody uninstalled a service would be the most
    // destructive thing in this repository.
    expect(source).not.toMatch(/DROP DATABASE|dropdb|psql/)
    expect(source).toContain('The database was not touched')
  })

  it('keeps the node CA unless asked to purge', () => {
    // Losing that key means enrolling and approving every machine again, even
    // though the database still lists them.
    const purgeBlock = source.slice(source.indexOf('if [[ $PURGE -eq 1 ]]'))
    expect(purgeBlock).toContain('$STATE_DIR')
    const beforePurge = source.slice(0, source.indexOf('if [[ $PURGE -eq 1 ]]'))
    expect(beforePurge).not.toContain('rm -rf "$STATE_DIR"')
  })
})

/**
 * That the package carries everything install.sh reaches for.
 *
 * This has now gone wrong twice, both times silently and both times the same
 * way: a file was added beside install.sh and not added to the staging list in
 * build-pkg.sh. reload-daemon.sh is called unconditionally under `set -e`, so
 * its absence killed the install partway; com.dai.updater.plist.in is behind an
 * `if [[ -f ]]`, so its absence said nothing at all and produced machines that
 * looked installed and could never take an upgrade.
 *
 * Comparing the two files is the check, because the failure is a disagreement
 * between them rather than a fault in either.
 */
describe('what the package has to contain', () => {
  const packaging = join(process.cwd(), '..', 'agent', 'packaging')
  const install = readFileSync(join(packaging, 'install.sh'), 'utf8')
  const build = readFileSync(join(packaging, 'build-pkg.sh'), 'utf8')

  // Every "$HERE/<name>" install.sh uses, which is every file it expects to
  // find beside itself once the package has laid it down.
  const needed = [...install.matchAll(/\$HERE\/([A-Za-z0-9._-]+)/g)]
    .map((m) => m[1]!)
    .filter((n) => n !== '..')

  it('finds at least the files we know it needs', () => {
    // Guards the regex above: if it silently matched nothing, every assertion
    // below would pass while checking nothing.
    expect(needed).toContain('install.sh'.replace('install.sh', 'reload-daemon.sh'))
    expect(needed).toContain('com.dai.updater.plist.in')
    expect(needed.length).toBeGreaterThan(3)
  })

  it('stages every file install.sh expects beside itself', () => {
    const missing = needed.filter((n) => n !== 'VERSION' && !build.includes(n))
    expect(missing, `build-pkg.sh does not stage: ${missing.join(', ')}`).toEqual([])
  })

  it('writes the VERSION file install.sh reads', () => {
    // Not copied but generated, so it is exempt from the check above and needs
    // its own. Without it the daemon reports no version and the fleet cannot
    // say what is deployed.
    expect(build).toMatch(/> "\$STAGING\/usr\/local\/libexec\/dai\/VERSION"/)
  })
})

/**
 * Re-running the installer has to be safe, because that is what an upgrade is.
 *
 * install.sh rewrites the config to point at the copy it staged, so on any
 * machine installed once the next run is handed its own output as the source.
 * The ANE block deleted the destination and then copied the source into it,
 * which for that case is the same path: it removed the model and failed on a
 * source that no longer existed, taking the install down after the binary had
 * already been replaced. The same shape was found and fixed for the binary
 * earlier; this is the one nobody went back for.
 *
 * Asserted against the script text rather than by running it, because the paths
 * it stages into are absolute and owned by root. That makes this a weaker test
 * than the others here and still worth having: it fails if the guard is removed,
 * which is exactly how this arrived.
 */
describe('installing over an existing install', () => {
  const install = readFileSync(
    join(process.cwd(), '..', 'agent', 'packaging', 'install.sh'), 'utf8')

  it('does not delete the ANE model it is about to copy', () => {
    const block = install.slice(install.indexOf('if [[ "$ANE" != "-"'))
      .slice(0, 900)
    // The destination is only cleared on the branch where it differs from the
    // source. A bare rm before the cp is the bug.
    expect(block).toMatch(/already in place/)
    expect(block).toMatch(/rm -rf "\$DEST"/)
    expect(block).not.toMatch(/^\s*rm -rf "\$MODEL_DIR\/\$\(basename "\$ANE"\)"/m)
  })

  it('does not reinstall a binary onto itself', () => {
    // The same guard, for the case that was found first.
    expect(install).toMatch(/already in place/)
  })
})

/**
 * Running the installed copy of install.sh by hand.
 *
 * The postinstall passes --build explicitly, so the packaged path always
 * worked. A person running /usr/local/libexec/dai/install.sh themselves got the
 * source-tree default instead and was told to run xcodebuild - on a machine
 * that has no source tree. The binaries were sitting beside the script.
 */
describe('finding the binaries', () => {
  const install = readFileSync(
    join(process.cwd(), '..', 'agent', 'packaging', 'install.sh'), 'utf8')

  it('looks beside itself before falling back to the source tree', () => {
    const at = install.indexOf('BUILD_OVERRIDE:-')
    // Asserted, because indexOf returning -1 makes slice() hand back the last
    // character and every check below then passes against nothing.
    expect(at, 'the build-path block moved or was renamed').toBeGreaterThan(0)
    const block = install.slice(at, at + 400)
    expect(block).toMatch(/-x "\$HERE\/dai-agent"/)
    expect(block).toMatch(/BUILD="\$HERE"/)
    // The override still wins, because a build host installing what it just
    // compiled is the other real case.
    expect(block.indexOf('BUILD_OVERRIDE')).toBeLessThan(block.indexOf('$HERE/dai-agent'))
  })
})

/**
 * Naming the link a split runs over.
 *
 * Guessed by default, and the guess is a guess: a workstation running VMs has
 * several bridges and only one of them goes anywhere. Naming the interface
 * rather than the address is the stable form - a link that comes back on a new
 * address after a reboot still answers to the same name.
 */
describe('the pipeline interface', () => {
  const template = readFileSync(
    join(process.cwd(), '..', 'agent', 'packaging', 'com.dai.agent.plist.in'), 'utf8')
  const install = readFileSync(
    join(process.cwd(), '..', 'agent', 'packaging', 'install.sh'), 'utf8')

  it('is in the daemon environment, where the agent reads it', () => {
    expect(template).toContain('DAI_PIPELINE_INTERFACE')
  })

  it('can be set from the config file an MDM drops', () => {
    // The same path every other per-site setting takes. A flag alone would mean
    // an unattended install could never name it.
    expect(install).toContain('pipelineInterface')
    expect(install).toContain('--pipeline-interface')
  })

  it('is substituted when the plist is rendered', () => {
    expect(install).toContain('@PIPELINE_IF@')
  })
})
