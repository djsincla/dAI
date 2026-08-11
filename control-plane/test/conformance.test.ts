import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import YAML from 'yaml'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { agentRoutes } from '../src/routes/agent.js'
import { adminRoutes } from '../src/routes/admin.js'
import { authRoutes } from '../src/routes/auth.js'
import { monitorRoutes } from '../src/routes/monitor.js'
import { compatRoutes, servingRoutes } from '../src/routes/serving.js'
import { Broker } from '../src/lib/broker.js'
import { Ca, loadOrCreateCa } from '../src/lib/ca.js'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'

/**
 * Every route the server answers must be described by the document that
 * describes the server.
 *
 * This exists because a route was added, worked when called directly, and was
 * unreachable in production: the agent surface validates against the OpenAPI
 * document, so a path missing from it answers 404 however correct the handler
 * is. The node read that 404 as "no, do not cancel" and kept generating - a
 * failure that surfaced minutes from its cause, as a machine that would not
 * stop.
 *
 * Nothing here knows what any route does, only that both halves agree it
 * exists. That is the point: it covers a class rather than an instance, and it
 * is the cheapest guard available against a whole category of silent
 * unreachability.
 */
describe('routes and specification agree', () => {
  const spec = YAML.parse(
    readFileSync(join(process.cwd(), 'openapi', 'dai.yaml'), 'utf8')) as {
      paths: Record<string, Record<string, unknown>>
    }

  /**
   * Mount points, which must match server.ts.
   *
   * Listed rather than discovered because Express 5 keeps a matcher function
   * where Express 4 kept a readable regexp, so the prefix is no longer
   * recoverable from a mounted router. A short list that must be kept honest is
   * a better trade than an introspection trick that breaks on the next minor
   * version - and the list is itself checked below.
   */
  let mounts: [string, any][] = []

  /** The routers only need a db to close over; none of this calls it. */
  const fakeDb = () => ({ query: async () => ({ rows: [] }) }) as any

  let caDir: string

  beforeAll(async () => {
    // A real CA, because the constructor parses what it is given and an empty
    // string fails before any route is registered.
    caDir = mkdtempSync(join(tmpdir(), 'dai-conformance-'))
    const ca = new Ca(await loadOrCreateCa(join(caDir, 'ca.crt'), join(caDir, 'ca.key')))
    mounts = [
      ['/admin/v1/auth', authRoutes(fakeDb())],
      ['/monitor/v1', monitorRoutes(fakeDb())],
      ['/agent/v1', agentRoutes(fakeDb(), new Broker(), ca)],
      ['/admin/v1', adminRoutes(fakeDb(), ca, new Broker())],
      ['/v1', servingRoutes(fakeDb(), new Broker())],
      ['/api', compatRoutes(fakeDb(), new Broker())],
    ]
  })

  const normalise = (path: string) =>
    path.replace(/:([A-Za-z0-9_]+)/g, '{$1}').replace(/\/$/, '') || '/'

  function served(): Set<string> {
    const out = new Set<string>()
    for (const [prefix, router] of mounts) {
      for (const layer of (router.stack ?? [])) {
        if (!layer.route) continue
        const path = normalise(prefix + layer.route.path)
        for (const method of Object.keys(layer.route.methods ?? {})) {
          if (method === '_all') continue
          out.add(`${method.toUpperCase()} ${path}`)
        }
      }
    }
    return out
  }

  const documented = () => {
    const out = new Set<string>()
    for (const [path, methods] of Object.entries(spec.paths)) {
      for (const method of Object.keys(methods)) {
        if (!['get', 'post', 'put', 'patch', 'delete'].includes(method)) continue
        out.add(`${method.toUpperCase()} ${path}`)
      }
    }
    return out
  }

  it('describes every route the server answers', () => {
    const missing = [...served()].filter((r) => !documented().has(r)).sort()
    expect(missing, 'served but absent from the specification, so unreachable '
      + 'on any surface the validator guards').toEqual([])
  })

  it('answers every route the specification describes', () => {
    // The other direction fails differently: a documented path nothing serves
    // is a promise to a client that 404s at the worst moment.
    const orphaned = [...documented()].filter((r) => !served().has(r)).sort()
    expect(orphaned, 'described but not served').toEqual([])
  })

  afterAll(() => {
    if (caDir) rmSync(caDir, { recursive: true, force: true })
  })
})
