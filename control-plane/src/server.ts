import express, { type Express, type NextFunction, type Request, type Response } from 'express'
import * as OpenApiValidator from 'express-openapi-validator'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createPool, type Db } from './lib/db.js'
import { agentRoutes } from './routes/agent.js'
import { adminRoutes } from './routes/admin.js'
import { startReaper } from './lib/work.js'
import { Acl, aclMiddleware, describeAcls } from './lib/netacl.js'

const here = dirname(fileURLToPath(import.meta.url))
export const OPENAPI_PATH = join(here, '..', 'openapi', 'dai.yaml')

/**
 * API first: the OpenAPI document is the source of truth and every request is
 * validated against it before a handler runs. The agent is Swift and this is
 * TypeScript, so the schema is the only artifact they share and the only place
 * a mismatch can be caught before deployment.
 */
export function createApp(db: Db): Express {
  const app = express()

  // Off unless a proxy is actually in front. With this unset, req.ip is the
  // socket peer and X-Forwarded-For is ignored, so a caller cannot declare
  // their own source address and walk through the network ACL.
  if (process.env.TRUST_PROXY) app.set('trust proxy', process.env.TRUST_PROXY)

  app.use(express.json({ limit: '32mb' }))

  app.get('/healthz', (_req, res) => { res.json({ ok: true }) })

  app.use(
    OpenApiValidator.middleware({
      apiSpec: OPENAPI_PATH,
      validateRequests: true,
      // Responses are validated in test and dev only: a schema drift should
      // fail a build, not a production request that is otherwise fine.
      validateResponses: process.env.NODE_ENV !== 'production',
      validateSecurity: false, // handled per-surface; the two differ
      ignorePaths: (p: string) => p === '/healthz',
    }),
  )

  // Network ACLs run before auth: a request from a disallowed range is
  // rejected without touching the database. Defence in depth, never a
  // substitute for mTLS or sessions.
  const agentAcl = new Acl(process.env.DAI_AGENT_CIDRS)
  const adminAcl = new Acl(process.env.DAI_ADMIN_CIDRS)

  app.use('/agent/v1', aclMiddleware(agentAcl, 'agent'), agentRoutes(db))
  app.use('/admin/v1', aclMiddleware(adminAcl, 'admin'), adminRoutes(db))

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
  const app = createApp(db)
  startReaper(db)

  for (const note of describeAcls(new Acl(process.env.DAI_AGENT_CIDRS),
                                  new Acl(process.env.DAI_ADMIN_CIDRS))) {
    console.warn(note)
  }

  const port = Number(process.env.PORT ?? 8443)
  // TLS from the first deployment, including locally. A local plaintext start
  // grows an unauthenticated dispatch endpoint that is hard to close later.
  const { readFileSync, existsSync } = await import('node:fs')
  const certPath = process.env.TLS_CERT ?? join(here, '..', 'certs', 'server.crt')
  const keyPath = process.env.TLS_KEY ?? join(here, '..', 'certs', 'server.key')
  const caPath = process.env.TLS_CA ?? join(here, '..', 'certs', 'ca.crt')

  if (existsSync(certPath) && existsSync(keyPath)) {
    const https = await import('node:https')
    https
      .createServer(
        {
          cert: readFileSync(certPath),
          key: readFileSync(keyPath),
          ca: existsSync(caPath) ? readFileSync(caPath) : undefined,
          // Nodes present certificates; humans do not, so a missing client cert
          // is rejected by the agent surface rather than by TLS.
          requestCert: true,
          rejectUnauthorized: false,
        },
        app,
      )
      .listen(port, () => console.log(`dai control plane (mTLS) on https://localhost:${port}`))
  } else {
    console.warn(
      `no TLS material at ${certPath}; starting HTTP. Run scripts/make-certs.sh before ` +
        `anything but local development.`,
    )
    app.listen(port, () => console.log(`dai control plane (HTTP) on http://localhost:${port}`))
  }
}
