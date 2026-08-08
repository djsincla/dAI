import { Router } from 'express'
import type { Db } from '../lib/db.js'
import type { Broker } from '../lib/broker.js'
import { userAuth } from '../lib/auth.js'
import { POLICY, type PresenceState } from '../lib/policy.js'
import { candidatesFor, isRefusal, selectNode } from '../lib/router.js'

/**
 * OpenAI-compatible serving surface.
 *
 * A single request assumes a model is already loaded, which is why routing
 * prefers a node that already holds it: E4 puts load at 1-3s, and paying that
 * per request is the difference between a service and a curiosity.
 *
 * The load-bearing behaviour here is refusing well. During working hours every
 * harvest node has a user present and GPU work is forbidden, so "no capacity"
 * is the expected answer rather than an error condition. A client is far better
 * served by hearing that immediately, with a reason, than by a request that
 * hangs until it times out.
 */
export function servingRoutes(db: Db, broker: Broker): Router {
  const r = Router()
  r.use(userAuth(db))

  r.get('/models', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT DISTINCT jsonb_object_keys(resident_models) AS hash
         FROM nodes WHERE state = 'active'`)
    res.json({
      object: 'list',
      data: (rows as any[]).map((m) => ({
        id: m.hash, object: 'model', owned_by: 'dai',
      })),
    })
  })

  r.post('/chat/completions', async (req, res) => {
    const body = req.body as {
      model?: string
      messages: unknown[]
      max_tokens?: number
      stream?: boolean
    }
    if (body.stream) {
      res.status(400).json({ error: {
        message: 'streaming is not supported: a completion is dispatched to a ' +
                 'node as one unit so that a yield has a bounded worst case',
        type: 'invalid_request_error' } })
      return
    }

    const modelHash = body.model ?? null
    const candidates = await candidatesFor(db, broker.inFlightCounts)
    // Only nodes holding the reverse channel open can be routed to. A node that
    // is eligible on paper but not listening cannot answer in time.
    const connected = candidates.filter((c) => broker.isConnected(c.id))

    const choice = selectNode(connected, 'generate', modelHash)
    if (isRefusal(choice)) {
      // 503 rather than 500: this is capacity, not failure, and it is the
      // normal daytime answer for a fleet of machines people are using.
      res.status(503).json({ error: {
        message: choice.detail,
        type: 'no_capacity',
        code: choice.refused,
      } })
      return
    }

    // Cap the completion to what the node's presence state allows. A single
    // request has no seam to yield at, so bounding its length bounds how long a
    // returning user waits for their machine back.
    const policy = POLICY[(choice.presence_state ?? 'ACTIVE') as PresenceState]
    const requested = body.max_tokens ?? 256
    const maxTokens = Math.min(requested, policy.maxCompletionTokens)

    const started = Date.now()
    const out = await broker.dispatch(choice.id, 'generate', modelHash, {
      messages: body.messages,
      max_tokens: maxTokens,
      model: modelHash,
    })

    if (!out.ok) {
      res.status(503).json({ error: {
        message: out.error, type: 'no_capacity', code: 'node-unreachable',
      } })
      return
    }

    const result = out.body as { text: string; promptTokens: number; completionTokens: number }
    res.json({
      id: `chatcmpl-${started}`,
      object: 'chat.completion',
      created: Math.floor(started / 1000),
      model: modelHash ?? 'default',
      choices: [{
        index: 0,
        message: { role: 'assistant', content: result.text },
        finish_reason: result.completionTokens >= maxTokens ? 'length' : 'stop',
      }],
      usage: {
        prompt_tokens: result.promptTokens,
        completion_tokens: result.completionTokens,
        total_tokens: result.promptTokens + result.completionTokens,
      },
      // Outside the OpenAI schema, but a caller on a harvested fleet should be
      // able to see which machine answered and whether their request was
      // shortened by that machine's policy.
      dai: {
        node: choice.hostname,
        presenceState: choice.presence_state,
        seconds: Math.round((Date.now() - started) / 10) / 100,
        maxTokensApplied: maxTokens,
        cappedByPolicy: maxTokens < requested,
      },
    })
  })

  return r
}
