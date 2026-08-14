import express, { type Express, type NextFunction, type Request, type Response } from 'express'
import { BoundListeners, type GroupListeners } from './lib/groupSockets.js'
import * as OpenApiValidator from 'express-openapi-validator'
import { parse as parseYaml } from 'yaml'
import { version } from './lib/version.js'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createPool, ensureBootstrapAdmin, type Db } from './lib/db.js'
import { agentRoutes } from './routes/agent.js'
import { adminRoutes } from './routes/admin.js'
import { authRoutes } from './routes/auth.js'
import { monitorRoutes } from './routes/monitor.js'
import { startReaper } from './lib/work.js'
import { Acl, aclMiddleware, closedAclMiddleware, describeAcls } from './lib/netacl.js'
import { Broker } from './lib/broker.js'
import { Ca } from './lib/ca.js'
import { compatRoutes, servingRoutes } from './routes/serving.js'

const here = dirname(fileURLToPath(import.meta.url))
export const OPENAPI_PATH = join(here, '..', 'openapi', 'dai.yaml')

/** Browsable contract, rendered from the served document rather than a copy. */
const DOCS_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>dAI control plane API</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{margin:0}</style></head>
<body><rapi-doc spec-url="/openapi.yaml" render-style="read" theme="dark"
  bg-color="#12151a" text-color="#e6e6e6" primary-color="#7cc4ff"
  show-header="false" allow-try="false"></rapi-doc>
<script type="module" src="/ui/vendor/rapidoc-min.js"></script></body></html>`

/**
 * API first: the OpenAPI document is the source of truth and every request is
 * validated against it before a handler runs. The agent is Swift and this is
 * TypeScript, so the schema is the only artifact they share and the only place
 * a mismatch can be caught before deployment.
 */
export type Surface = 'agent' | 'admin' | 'both'
  // A group's own socket. The OpenAI-compatible routes and nothing else: admin
  // belongs in one place however the fleet is divided, and an agent talks to
  // the control plane rather than to a group. Mounting admin on forty sockets
  // would be forty more doors to the same room.
  | 'serving'

/**
 * Shared between the agent and serving surfaces: one holds the reverse channel
 * open, the other pushes down it. In-process, so a second instance would need
 * this in Postgres with LISTEN/NOTIFY before scaling out.
 */
export const broker = new Broker()

/**
 * Node identity issuer. Its private key is read from disk rather than the
 * database, so a database compromise cannot mint fleet members.
 */
export const ca = await Ca.fromEnv()

/**
 * The shared serving port, where the whole fleet is in scope.
 *
 * Named so the group middleware can tell "this is the ordinary listener" from
 * "this is somebody's group socket" without a lookup on every request to the
 * main surface.
 */
export function sharedPort(): number { return Number(process.env.PORT ?? 8443) }

/**
 * The group sockets, once the process has bound them.
 *
 * Held here because the admin routes need to open one the moment a group is
 * created, and they are built before there is anything to open. A getter is
 * passed to them rather than this variable, so they see whatever it becomes.
 */
let groupListeners: GroupListeners | undefined

export function createApp(db: Db, surface: Surface = 'both',
                          listeners?: () => GroupListeners | undefined): Express {
  const app = express()

  // Which group this request is addressed to, read from the socket it arrived
  // on rather than from anything it says.
  //
  // A group's port is the whole of its addressing, which is the point: an
  // application pointed at one port is asking one set of machines, and there is
  // no header to forget and no field to get wrong. Looked up per request rather
  // than captured when the listener was bound, so that a group whose port is
  // reassigned - or whose row is gone - stops answering as that group without
  // anything having to reach into a running server.
  app.use(async (req, _res, next) => {
    const port = req.socket.localPort
    if (port == null || port === sharedPort()) { next(); return }
    try {
      const { rows } = await db.query(
        `SELECT id FROM pools WHERE serving_port = $1`, [port])
      ;(req as Request & { groupId?: string | null }).groupId = rows[0]?.id ?? null
    } catch { /* the shared surface's behaviour is the safe default */ }
    next()
  })

  // Off unless a proxy is actually in front. With this unset, req.ip is the
  // socket peer and X-Forwarded-For is ignored, so a caller cannot declare
  // their own source address and walk through the network ACL.
  if (process.env.TRUST_PROXY) app.set('trust proxy', process.env.TRUST_PROXY)

  app.use(express.json({ limit: '32mb' }))
  // Rendered frames arrive as bytes, not JSON. Capped well above a 4K PNG and
  // well below anything that would let one node exhaust the control plane's
  // memory by claiming to have rendered a very large frame.
  app.use(express.raw({ type: 'application/octet-stream', limit: '256mb' }))

  // version, because this is the endpoint somebody curls when they want to know
  // what is running, and until it was here the answer needed ssh and a guess at
  // which directory the daemon was started from.
  app.get('/healthz', (_req, res) => { res.json({ ok: true, surface, version }) })

  // The control node serves the contract. Agents and generated clients fetch it
  // from the authority rather than carrying a copy that can drift, and the
  // version they fetched is the version the server validates against.
  app.get('/openapi.yaml', (_req, res) => {
    res.type('application/yaml').send(readFileSync(OPENAPI_PATH, 'utf8'))
  })

  /**
   * The same contract as JSON.
   *
   * Parsed here rather than in every client. The console's API explorer needs
   * the document as data, and shipping a YAML parser to a browser to read a file
   * this process has already parsed is a dependency bought for nothing.
   *
   * Read from disk each time rather than cached, so editing the spec during
   * development shows up on refresh - the same reason /openapi.yaml does.
   */
  app.get('/openapi.json', (_req, res) => {
    res.json(parseYaml(readFileSync(OPENAPI_PATH, 'utf8')))
  })
  app.get('/docs', (_req, res) => {
    res.type('html').send(DOCS_HTML)
  })

  // Registered ahead of the validator: the UI is not part of the API contract,
  // and the validator rejects paths the spec does not declare.
  if (surface !== 'agent') {
    // The capabilities page, served from the repository copy so it cannot
    // drift from the code it describes.
    // Two levels up: `here` is src/, and the page lives at the repository root
    // so it is a project document rather than an asset of this service.
    app.get('/', (_req, res) => { res.sendFile(join(here, '..', '..', 'docs', 'index.html')) })
    app.get('/fleet', (_req, res) => { res.redirect('/ui/') })
    app.use('/ui', express.static(join(here, '..', 'ui')))
  }

  // Two validators, because the surfaces have opposite requirements.
  //
  // The agent and admin APIs are ours: we define both ends, and strictness
  // there has already caught a real bug that would otherwise have been silent.
  //
  // The serving surface exists to be compatible with clients nobody here
  // controls, and those clients append query parameters as they please. Claude
  // Code sends ?beta=true, which the strict validator rejected with a 400, so
  // every real request failed while curl worked. The API this imitates
  // tolerates unknown parameters, so imitating it means tolerating them too.
  const isServing = (p: string) => p.startsWith('/v1/') || p.startsWith('/api/')
  const alwaysSkip = (p: string) => p === '/' || p === '/fleet'
    || p === '/healthz' || p === '/openapi.yaml'
    || p === '/docs' || p.startsWith('/ui')

  // Drop query parameters on the serving surface, and say what was dropped.
  //
  // None of these endpoints take any, and clients we do not control append
  // their own: Claude Code sends ?beta=true, which the validator rejected with
  // a 400, so every real request failed while curl worked. Silently ignoring
  // them is what the API this imitates does. Logging them means a parameter
  // that turns out to matter shows up in the log rather than being discovered
  // by its absence.
  app.use((req: Request, _res: Response, next: NextFunction) => {
    if (!isServing(req.path)) return next()
    const keys = Object.keys(req.query ?? {})
    if (keys.length > 0) {
      console.log(`[serving] ignoring query parameter${keys.length > 1 ? 's' : ''} `
        + `on ${req.path}: ${keys.join(', ')}`)
      // Redefined rather than assigned: req.query is a getter in Express 5.
      Object.defineProperty(req, 'query', { value: {}, writable: true, configurable: true })
    }
    next()
  })

  const validator = (opts: { serving: boolean }) => OpenApiValidator.middleware({
    apiSpec: OPENAPI_PATH,
    validateRequests: true,
    // Responses are validated in test and dev only: a schema drift should
    // fail a build, not a production request that is otherwise fine.
    validateResponses: process.env.NODE_ENV !== 'production',
    validateSecurity: false, // handled per-surface; the two differ
    ignorePaths: (p: string) => alwaysSkip(p) || (opts.serving ? !isServing(p) : isServing(p)),
  })

  // Everything the serving surface returns as an error wears the shape its
  // clients parse.
  //
  // Auth failures, 404s and validator rejections were leaking {error, detail},
  // which is this project's internal shape and means nothing to an Anthropic
  // client: it sees a body it cannot read and reports the failure as something
  // other than what happened. Applied as a wrapper rather than at each call
  // site so the ones nobody remembers - a middleware three layers down
  // rejecting a request - are covered too.
  app.use((req: Request, res: Response, next: NextFunction) => {
    if (!isServing(req.path)) return next()
    const json = res.json.bind(res)
    res.json = (body: any) => {
      // Only this project's internal shape, which is {error: "slug", detail}.
      // A body whose `error` is already an object is a structured error someone
      // wrote on purpose - the OpenAI surface has its own, and rewrapping it
      // replaced a correct shape with a different correct shape, which is how
      // this broke two tests that were right all along.
      const internal = body && typeof body === 'object'
        && typeof (body as any).error === 'string'
      if (res.statusCode >= 400 && internal) {
        return json({
          type: 'error',
          error: {
            // Mapped from the status, since the internal shape carries a slug
            // where the client expects one of a fixed set.
            type: res.statusCode === 401 || res.statusCode === 403
              ? 'authentication_error'
              : res.statusCode === 404 ? 'not_found_error'
              : res.statusCode === 429 ? 'rate_limit_error'
              : res.statusCode >= 500 ? 'api_error'
              : 'invalid_request_error',
            message: body.detail ?? body.message ?? String(body.error ?? 'request failed'),
          },
        })
      }
      return json(body)
    }
    next()
  })

  app.use(validator({ serving: true }))
  app.use(validator({ serving: false }))

  // Network ACLs run before auth: a request from a disallowed range is
  // rejected without touching the database. Defence in depth, never a
  // substitute for mTLS or sessions.
  const agentAcl = new Acl(process.env.DAI_AGENT_CIDRS)
  const adminAcl = new Acl(process.env.DAI_ADMIN_CIDRS)

  // The two surfaces are separable at the listener, not only by path. Workers
  // poll continuously and their dispatch must not stop because the human-facing
  // side is restarting, misbehaving or being scaled independently. Running them
  // as one process is the convenient default, not a requirement.
  if (surface !== 'admin') {
    app.use('/agent/v1', aclMiddleware(agentAcl, 'agent'), agentRoutes(db, broker, ca))
  }
  if (surface !== 'agent' && surface !== 'serving') {
    // Before the admin routes, because signing in cannot itself require being
    // signed in. Still behind the admin network ACL: obtaining a credential is
    // not something to expose more widely than using one.
    // Monitoring, reachable only from configured addresses and disabled
    // entirely when none are. No credential, deliberately: the alternative is a
    // long-lived secret in a scraper's config file that nobody ever rotates.
    const monitorAcl = new Acl(process.env.DAI_MONITOR_CIDRS)
    app.use('/monitor/v1', closedAclMiddleware(monitorAcl, 'monitoring'), monitorRoutes(db, listeners ?? (() => groupListeners)))

    app.use('/admin/v1/auth', aclMiddleware(adminAcl, 'admin'), authRoutes(db))
    app.use('/admin/v1', aclMiddleware(adminAcl, 'admin'), adminRoutes(db, ca, broker, listeners ?? (() => groupListeners)))
    // OpenAI-compatible surface. Separate from /admin because its callers are
    // applications rather than people, and it will want its own rate limits and
    // availability treatment.
    //
    // Access needs a credential now as well as a reachable network: either a
    // signed-in session or a named API key. It used to be network ACL alone,
    // which meant anyone who could reach the subnet could use the fleet.
  }
  if (surface !== 'agent') {
    // OpenAI-compatible surface. Separate from /admin because its callers are
    // applications rather than people, and it will want its own rate limits and
    // availability treatment.
    //
    // Access needs a credential now as well as a reachable network: either a
    // signed-in session or a named API key. It used to be network ACL alone,
    // which meant anyone who could reach the subnet could use the fleet.
    //
    // Mounted on a group's socket too, where it answers for that group's
    // machines only. Same routes, same credentials; the port decides the scope.
    app.use('/v1', aclMiddleware(adminAcl, 'serving'), servingRoutes(db, broker))
    // The same router under /api, so /api/v0/models resolves. Tools written
    // against LM Studio probe that path for the context window, and the point
    // of serving their shape is that they work without being patched.
    app.use('/api', aclMiddleware(adminAcl, 'serving'), compatRoutes(db, broker))
  }

  app.use((err: any, _req: Request, res: Response, _next: NextFunction) => {
    const status = err.status ?? 500
    if (status >= 500) console.error(err)
    res.status(status).json({
      error: status === 400 ? 'bad_request' : status >= 500 ? 'internal' : 'error',
      detail: err.message ?? String(err),
    })
  })

  return app
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const db = createPool()

  // The account a fresh deployment starts with, made here rather than only by
  // `migrate()`. Nothing on the running path called migrate, so a real
  // deployment never got a bootstrap account at all: the schema was applied by
  // hand, the seeding step was not, and the console had no credential that
  // would sign in. Only the test databases, which do call migrate, ever had
  // one - which is the worst place for this to work and nowhere else.
  //
  // Safe to run every start: it returns immediately once any account has a
  // password, so it cannot resurrect itself on an established fleet or
  // undo somebody's password change.
  await ensureBootstrapAdmin(db)

  startReaper(db)

  for (const note of describeAcls(new Acl(process.env.DAI_AGENT_CIDRS),
                                  new Acl(process.env.DAI_ADMIN_CIDRS))) {
    console.warn(note)
  }

  const { existsSync } = await import('node:fs')
  const https = await import('node:https')
  const http = await import('node:http')
  const certPath = process.env.TLS_CERT ?? join(here, '..', 'certs', 'server.crt')
  const keyPath = process.env.TLS_KEY ?? join(here, '..', 'certs', 'server.key')
  const caPath = process.env.TLS_CA ?? join(here, '..', 'certs', 'ca.crt')
  const tls = existsSync(certPath) && existsSync(keyPath)

  async function listen(surface: Surface, port: number) {
    const app = createApp(db, surface)
    if (!tls) {
      // Local development only. A deployment that starts on plaintext grows an
      // unauthenticated dispatch endpoint that is hard to close later.
      app.listen(port, () =>
        console.warn(`[${surface}] HTTP on :${port} (no TLS material at ${certPath})`))
      return
    }
    https
      .createServer(
        {
          cert: readFileSync(certPath),
          key: readFileSync(keyPath),
          // Client certificates are verified against the *node* CA, which is
          // not necessarily the CA that issued this server's own certificate.
          // Conflating them would mean anything trusted to talk to the fleet
          // could also impersonate a node.
          ca: [ca.certPem, ...(existsSync(caPath) ? [readFileSync(caPath, 'utf8')] : [])],
          // Nodes present certificates; humans do not. A missing client cert is
          // therefore rejected by the agent surface rather than by TLS itself.
          requestCert: surface !== 'admin',
          rejectUnauthorized: false,
        },
        app,
      )
      .listen(port, () => console.log(`[${surface}] mTLS on https://localhost:${port}`))
  }

  // One process by default. Set AGENT_PORT to run the worker API on its own
  // listener so it can be firewalled separately and kept up while the
  // human-facing side restarts.
  const port = sharedPort()
  const agentPort = process.env.AGENT_PORT ? Number(process.env.AGENT_PORT) : null
  if (agentPort) {
    await listen('admin', port)
    await listen('agent', agentPort)
  } else {
    await listen('both', port)
  }

  // Then one socket per group.
  //
  // The serving surface only, because a group's port is for the applications
  // that use it: admin lives in one place whatever the fleet is divided into,
  // and an agent reaches the control plane rather than a group. Each of these
  // serves the same routes, scoped by the port the request arrived on.
  const groups = new BoundListeners(
    (groupPort) => {
      const app = createApp(db, 'serving')
      if (!tls) return http.createServer(app)
      return https.createServer(
        {
          cert: readFileSync(certPath),
          key: readFileSync(keyPath),
          ca: [ca.certPem, ...(existsSync(caPath) ? [readFileSync(caPath, 'utf8')] : [])],
          // No client certificate wanted here: these callers are applications
          // with an API key or a session, the same as the shared serving port.
          requestCert: false,
          rejectUnauthorized: false,
        },
        app,
      )
    },
    (message) => console.log(message),
  )
  groupListeners = groups

  const { rows: withPorts } = await db.query(
    `SELECT name, serving_port FROM pools WHERE serving_port IS NOT NULL ORDER BY serving_port`)
  for (const row of withPorts as { name: string; serving_port: number }[]) {
    try {
      await groups.open(Number(row.serving_port))
    } catch (err) {
      // One group failing to bind must not stop the others or the control
      // plane. Something else on the machine holding that port is an operator's
      // problem, and they can only act on it if it is said out loud.
      console.warn(`[group] ${row.name} could not take :${row.serving_port}: `
        + `${(err as Error).message}`)
    }
  }
}
