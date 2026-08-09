import express, { type Express, type NextFunction, type Request, type Response } from 'express'
import * as OpenApiValidator from 'express-openapi-validator'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createPool, type Db } from './lib/db.js'
import { agentRoutes } from './routes/agent.js'
import { adminRoutes } from './routes/admin.js'
import { startReaper } from './lib/work.js'
import { Acl, aclMiddleware, describeAcls } from './lib/netacl.js'
import { Broker } from './lib/broker.js'
import { Ca } from './lib/ca.js'
import { servingRoutes } from './routes/serving.js'

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

export function createApp(db: Db, surface: Surface = 'both'): Express {
  const app = express()

  // Off unless a proxy is actually in front. With this unset, req.ip is the
  // socket peer and X-Forwarded-For is ignored, so a caller cannot declare
  // their own source address and walk through the network ACL.
  if (process.env.TRUST_PROXY) app.set('trust proxy', process.env.TRUST_PROXY)

  app.use(express.json({ limit: '32mb' }))

  app.get('/healthz', (_req, res) => { res.json({ ok: true, surface }) })

  // The control node serves the contract. Agents and generated clients fetch it
  // from the authority rather than carrying a copy that can drift, and the
  // version they fetched is the version the server validates against.
  app.get('/openapi.yaml', (_req, res) => {
    res.type('application/yaml').send(readFileSync(OPENAPI_PATH, 'utf8'))
  })
  app.get('/docs', (_req, res) => {
    res.type('html').send(DOCS_HTML)
  })

  // Registered ahead of the validator: the UI is not part of the API contract,
  // and the validator rejects paths the spec does not declare.
  if (surface !== 'agent') {
    app.get('/', (_req, res) => { res.redirect('/ui/') })
    app.use('/ui', express.static(join(here, '..', 'ui')))
  }

  app.use(
    OpenApiValidator.middleware({
      apiSpec: OPENAPI_PATH,
      validateRequests: true,
      // Responses are validated in test and dev only: a schema drift should
      // fail a build, not a production request that is otherwise fine.
      validateResponses: process.env.NODE_ENV !== 'production',
      validateSecurity: false, // handled per-surface; the two differ
      ignorePaths: (p: string) => p === '/healthz' || p === '/openapi.yaml' || p === '/docs'
        || p.startsWith('/ui'),
    }),
  )

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
  if (surface !== 'agent') {
    app.use('/admin/v1', aclMiddleware(adminAcl, 'admin'), adminRoutes(db, ca))
    // OpenAI-compatible surface. Separate from /admin because its callers are
    // applications rather than people, and it will want its own rate limits and
    // availability treatment.
    //
    // Access is by network ACL, and that is the whole of it: there are no API
    // keys. Said plainly because this comment used to claim keys that do not
    // exist, which reads as a decision already taken rather than one still
    // open. Anyone who can reach the subnet can use the fleet.
    app.use('/v1', aclMiddleware(adminAcl, 'serving'), servingRoutes(db, broker))
    // The same router under /api, so /api/v0/models resolves. Tools written
    // against LM Studio probe that path for the context window, and the point
    // of serving their shape is that they work without being patched.
    app.use('/api', aclMiddleware(adminAcl, 'serving'), servingRoutes(db, broker))
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
  startReaper(db)

  for (const note of describeAcls(new Acl(process.env.DAI_AGENT_CIDRS),
                                  new Acl(process.env.DAI_ADMIN_CIDRS))) {
    console.warn(note)
  }

  const { existsSync } = await import('node:fs')
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
    const https = await import('node:https')
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
  const port = Number(process.env.PORT ?? 8443)
  const agentPort = process.env.AGENT_PORT ? Number(process.env.AGENT_PORT) : null
  if (agentPort) {
    await listen('admin', port)
    await listen('agent', agentPort)
  } else {
    await listen('both', port)
  }
}
