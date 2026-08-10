import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import YAML from 'yaml'
import { describe, expect, it } from 'vitest'
import { appFor, freshDb } from './helpers.js'

/**
 * Every route the server answers must be described by the document that
 * describes the server.
 *
 * This exists because a route was added, worked when called directly, and
 * 404'd in production: the agent surface validates against the OpenAPI
 * document, so a path missing from it is unreachable however correct the
 * handler is. The agent read that 404 as "no, do not cancel" and kept
 * generating - the failure surfaced minutes away from its cause, as a node that
 * would not stop.
 *
 * A conformance test is the cheapest possible guard against that, and it covers
 * a whole class rather than one instance: nothing here knows what any route
 * does, only that both halves agree it exists.
 */
describe('routes and specification agree', () => {
  const spec = YAML.parse(
    readFileSync(join(process.cwd(), 'openapi', 'dai.yaml'), 'utf8')) as {
      paths: Record<string, Record<string, unknown>>
    }

  /** Express writes `:id`; OpenAPI writes `{id}`. */
  const normalise = (path: string) =>
    path.replace(/:([A-Za-z0-9_]+)/g, '{$1}').replace(/\/$/, '') || '/'

  /**
   * Walk the router tree. Mounted routers carry their prefix in the layer's
   * regexp rather than as a string, so the prefix is recovered from it: the
   * alternative is maintaining a second list of mount points, which would rot
   * in exactly the way this test exists to prevent.
   */
  function routesOf(app: any): { method: string; path: string }[] {
    const found: { method: string; path: string }[] = []

    const walk = (stack: any[], prefix: string) => {
      for (const layer of stack ?? []) {
        if (layer.route) {
          const path = normalise(prefix + layer.route.path)
          for (const method of Object.keys(layer.route.methods ?? {})) {
            if (method === '_all') continue
            found.push({ method: method.toUpperCase(), path })
          }
        } else if (layer.name === 'router' && layer.handle?.stack) {
          const source: string = layer.regexp?.source ?? ''
          const mount = source
            .replace(/^\^\\\//, '/')
            .replace(/\\\/\?\(\?=\\\/\|\$\)$/, '')
            .replace(/\\\//g, '/')
            .replace(/\(\?:\\\/\)\?\$/, '')
            .replace(/\$$/, '')
          walk(layer.handle.stack, prefix + (mount === '/' ? '' : mount))
        }
      }
    }

    walk(app.router?.stack ?? app._router?.stack, '')
    return found
  }

  /**
   * Paths that are deliberately outside the document: the fleet UI, the
   * document itself, and the liveness check that has to answer even when the
   * validator cannot load.
   */
  const undocumented = (path: string) =>
    path === '/' || path === '/fleet' || path === '/healthz'
    || path === '/openapi.yaml' || path === '/docs' || path.startsWith('/ui')

  it('describes every route the server answers', async () => {
    const db = await freshDb()
    const app = appFor(db)
    const missing = routesOf(app)
      .filter((r) => !undocumented(r.path))
      .filter((r) => {
        const entry = spec.paths[r.path]
        return !entry || !(r.method.toLowerCase() in entry)
      })
    await db.end()

    expect(missing, 'routes the server answers but the specification omits')
      .toEqual([])
  })

  it('answers every route the specification describes', async () => {
    const db = await freshDb()
    const app = appFor(db)
    const served = new Set(routesOf(app).map((r) => `${r.method} ${r.path}`))
    await db.end()

    // The other direction, which fails differently: a documented path nothing
    // serves is a promise to a client that will 404 at the worst moment.
    const orphaned: string[] = []
    for (const [path, methods] of Object.entries(spec.paths)) {
      for (const method of Object.keys(methods)) {
        if (!['get', 'post', 'put', 'patch', 'delete'].includes(method)) continue
        const key = `${method.toUpperCase()} ${path}`
        if (!served.has(key)) orphaned.push(key)
      }
    }
    expect(orphaned, 'described in the specification but not served').toEqual([])
  })
})
