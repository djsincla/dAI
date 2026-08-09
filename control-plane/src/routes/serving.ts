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

  /**
   * Models this fleet can serve, and how much context each accepts.
   *
   * The window is advertised because a client that has to guess gets it wrong
   * in one of two expensive ways: guess high and the conversation runs past
   * what the model takes, guess low and most of the window goes unused. Taken
   * from what nodes report rather than configured here, so it cannot drift
   * from the weights actually on disk.
   */
  r.get('/models', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT name, max(context)::int AS context
         FROM nodes,
              LATERAL jsonb_each(
                CASE WHEN resident_models = '{}'::jsonb THEN model_context
                     ELSE resident_models || model_context END) AS m(name, value),
              LATERAL (SELECT COALESCE((model_context ->> m.name)::int, 0)) AS c(context)
        WHERE state = 'active'
        GROUP BY name`)
    res.json({
      object: 'list',
      data: (rows as any[]).map((m) => ({
        id: m.name,
        object: 'model',
        owned_by: 'dai',
        // Both spellings. context_length is what clients look for; the other
        // two are what the OpenAI and LM Studio shapes use, and a client that
        // finds any of them does not have to fall back to a default.
        context_length: m.context || null,
        max_context_length: m.context || null,
        context_window: m.context || null,
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

  /**
   * LM Studio's model shape, served so tools written against it work unchanged.
   *
   * Not an endorsement of the shape. Scripts in the wild probe this path for
   * `loaded_context_length` to size a client's context window, and asking
   * people to patch their tooling to try a fleet is a good way to have nobody
   * try it.
   */
  r.get('/v0/models', async (_req, res) => {
    const { rows } = await db.query(
      `SELECT name, max(context)::int AS context, bool_or(resident) AS resident
         FROM nodes,
              LATERAL jsonb_each(
                CASE WHEN resident_models = '{}'::jsonb THEN model_context
                     ELSE resident_models || model_context END) AS m(name, value),
              LATERAL (SELECT COALESCE((model_context ->> m.name)::int, 0)) AS c(context),
              LATERAL (SELECT resident_models ? m.name) AS r(resident)
        WHERE state = 'active'
        GROUP BY name`)
    res.json({
      object: 'list',
      data: (rows as any[]).map((m) => ({
        id: m.name,
        object: 'model',
        type: 'llm',
        publisher: 'dai',
        // The window the model accepts. Named as LM Studio names it, because
        // that is what the tools reading this path look for.
        max_context_length: m.context || null,
        loaded_context_length: m.context || null,
        state: m.resident ? 'loaded' : 'not-loaded',
      })),
    })
  })

  /**
   * Anthropic-native messages endpoint.
   *
   * Exists because the clients people actually use speak this shape, and a
   * fleet nobody can point a tool at is a fleet nobody uses. Same routing,
   * same policy caps, same reverse channel as the OpenAI surface: only the
   * request and response shapes differ.
   */
  r.post('/messages', async (req, res) => {
    const body = req.body as {
      model?: string
      messages: { role: string; content: unknown }[]
      system?: unknown
      max_tokens?: number
      stream?: boolean
    }

    const modelHash = body.model ?? null
    const candidates = await candidatesFor(db, broker.inFlightCounts)
    const connected = candidates.filter((c) => broker.isConnected(c.id))
    const choice = selectNode(connected, 'generate', modelHash)

    if (isRefusal(choice)) {
      // 503 with the Anthropic error shape. This is the normal daytime answer
      // for a fleet of machines people are using, not a fault.
      res.status(503).json({
        type: 'error',
        error: { type: 'overloaded_error', message: choice.detail },
      })
      return
    }

    const policy = POLICY[(choice.presence_state ?? 'ACTIVE') as PresenceState]
    const requested = body.max_tokens ?? 512
    const maxTokens = Math.min(requested, policy.maxCompletionTokens)

    // The system prompt rides as a leading message. The runtime takes one
    // string, and dropping it silently would change the model's behaviour in a
    // way nobody could see from here.
    const messages = body.system
      ? [{ role: 'system', content: body.system }, ...body.messages]
      : body.messages

    const started = Date.now()
    const out = await broker.dispatch(choice.id, 'generate', modelHash, {
      messages, max_tokens: maxTokens, model: modelHash,
    })

    if (!out.ok) {
      res.status(503).json({
        type: 'error',
        error: { type: 'api_error', message: out.error },
      })
      return
    }

    const result = out.body as { text: string; promptTokens?: number; completionTokens?: number }
    const id = `msg_${started}`
    const usage = {
      input_tokens: result.promptTokens ?? 0,
      output_tokens: result.completionTokens ?? 0,
    }
    const stopReason = (result.completionTokens ?? 0) >= maxTokens ? 'max_tokens' : 'end_turn'

    if (body.stream) {
      // Replayed as a stream rather than streamed as it is produced.
      //
      // A completion is dispatched to a node as one unit so that a preemption
      // has a bounded worst case, and that decision is upstream of this. What
      // this does is let clients that require SSE work at all - the whole
      // answer arrives in one text delta. Honest about it here rather than in
      // a comment nobody reads: the caller waits the same time and then gets
      // everything, so there is no incremental display.
      res.writeHead(200, {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        connection: 'keep-alive',
      })
      const send = (event: string, data: unknown) => {
        res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)
      }
      send('message_start', { type: 'message_start', message: {
        id, type: 'message', role: 'assistant', model: modelHash ?? 'default',
        content: [], stop_reason: null, stop_sequence: null,
        usage: { input_tokens: usage.input_tokens, output_tokens: 0 },
      } })
      send('content_block_start', {
        type: 'content_block_start', index: 0,
        content_block: { type: 'text', text: '' },
      })
      send('content_block_delta', {
        type: 'content_block_delta', index: 0,
        delta: { type: 'text_delta', text: result.text },
      })
      send('content_block_stop', { type: 'content_block_stop', index: 0 })
      send('message_delta', {
        type: 'message_delta',
        delta: { stop_reason: stopReason, stop_sequence: null },
        usage: { output_tokens: usage.output_tokens },
      })
      send('message_stop', { type: 'message_stop' })
      res.end()
      return
    }

    res.json({
      id,
      type: 'message',
      role: 'assistant',
      model: modelHash ?? 'default',
      content: [{ type: 'text', text: result.text }],
      stop_reason: stopReason,
      stop_sequence: null,
      usage,
    })
  })

  return r
}
