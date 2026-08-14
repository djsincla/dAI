import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { isRelease, version } from '../src/lib/version.js'

/**
 * The one machine an operator attends to, and until now the one that could not
 * say what it was running.
 *
 * The agent reported its version from the day AgentVersion existed. The control
 * plane wrote a VERSION file into its own payload and nothing read it, so the
 * answer lived in a file on disk that no interface exposed - and package.json
 * said 0.1.0 through four releases, because nobody updates a private package's
 * version field.
 */
describe('what the control plane says it is', () => {
  it('answers dev from a working tree', () => {
    // Deliberately not a version number. An unversioned build must not be able
    // to pass for a release in a fleet view, and "dev" is the honest answer
    // when somebody has deployed from a checkout.
    expect(version).toBe('dev')
    expect(isRelease).toBe(false)
  })

  it('does not read package.json', () => {
    // The trap this replaces: package.json is a manifest for npm, npm is not how
    // this is deployed, and its version field has been wrong since 0.1.0.
    const manifest = JSON.parse(readFileSync(
      join(import.meta.dirname, '..', 'package.json'), 'utf8'))
    expect(manifest.version).toBe('0.1.0')
    expect(version).not.toBe(manifest.version)

    const source = readFileSync(
      join(import.meta.dirname, '..', 'src', 'lib', 'version.ts'), 'utf8')
    expect(source).not.toMatch(/from ['"].*package\.json/)
    expect(source).not.toMatch(/readFileSync\([^)]*package\.json/)
  })

  it('reads the file the builder writes, beside the payload', () => {
    // dist/lib/version.js -> ../../VERSION, which is the payload root, beside
    // dist/, openapi/, ui/ and db/ - the same relative-path convention every
    // other runtime asset here uses.
    const source = readFileSync(
      join(import.meta.dirname, '..', 'src', 'lib', 'version.ts'), 'utf8')
    expect(source).toContain("'..', '..', 'VERSION'")

    const builder = readFileSync(
      join(import.meta.dirname, '..', 'packaging', 'build-control-pkg.sh'), 'utf8')
    expect(builder).toContain('> "$PAYLOAD/VERSION"')
  })
})

/**
 * Both packages take their version from the same argument, and neither will
 * accept one that is not a version.
 */
describe('one version across both packages', () => {
  const builders = ['../packaging/build-control-pkg.sh',
                    '../../agent/packaging/build-pkg.sh']

  it.each(builders)('%s refuses a version that is a date', (rel) => {
    // 2026.08.12-5 is what got through by hand. It sorts against 0.3.1 as
    // nonsense and tells an operator nothing about what it is newer than. The
    // leading zero in 08 is what distinguishes a date from a version.
    const src = readFileSync(join(import.meta.dirname, rel), 'utf8')
    const guard = src.split('\n').find(l => l.includes('VERSION" =~'))
    expect(guard).toBeDefined()

    const pattern = new RegExp(guard!.match(/\^.*\$/)![0])
    expect(pattern.test('2026.08.12-5')).toBe(false)
    expect(pattern.test('0.3.1')).toBe(true)
    expect(pattern.test('0.3.2-rc1')).toBe(true)
    expect(pattern.test('dev')).toBe(false)
  })

  it('is chosen once, by the release script, and passed to both', () => {
    // One helper that passes the version, called once per package - rather than
    // two invocations that can be edited apart. The version an operator names is
    // the version in both packages by construction.
    const release = readFileSync(
      join(import.meta.dirname, '..', '..', 'scripts', 'release.sh'), 'utf8')
    expect(release).toContain('--version "$VERSION"')
    expect(release).toMatch(/build_package .*build-pkg\.sh/)
    expect(release).toMatch(/build_package .*build-control-pkg\.sh/)
    // and only ever from $VERSION, never a literal
    expect(release).not.toMatch(/--version ['"]?\d+\.\d+/)
  })
})
