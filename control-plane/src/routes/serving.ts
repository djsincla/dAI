import { Router, type Request } from 'express'
import type { Db } from '../lib/db.js'
import type { Broker } from '../lib/broker.js'
import { userAuth } from '../lib/auth.js'
import { POLICY, type PresenceState } from '../lib/policy.js'
import { candidatesFor, isRefusal, selectGang, selectNode,
         type Candidate, type Refusal } from '../lib/router.js'
import { shapeOf } from '../lib/shape.js'
import { membersOf } from '../lib/pools.js'

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
/**
 * `groupId` narrows the catalogue to one group's machines, because a caller
 * asking a group's socket what it can serve is asking about those machines. A
 * catalogue that answered for the fleet would advertise models the next request
 * on the same port could not be given.
 */
async function servableModels(db: Db, broker: Broker, groupId?: string | null) {
    const { rows } = await db.query(
      `SELECT id AS node_id, name,
              COALESCE((model_context ->> name)::int, 0) AS context,
              (resident_models ? name) AS resident
         FROM nodes,
              LATERAL jsonb_object_keys(resident_models || model_context) AS name
        WHERE state = 'active'
          AND NOT user_paused
          AND (paused_until IS NULL OR paused_until < now())
          AND last_heartbeat > now() - interval '2 minutes'`)

    const scope = groupId ? await membersOf(db, groupId) : null
    const models = new Map<string, { context: number; resident: boolean; live: boolean }>()
    for (const row of rows as any[]) {
      if (scope !== null && !scope.has(row.node_id as string)) continue
      // Recent heartbeat, not currently parked on the channel.
      //
      // These are different facts and conflating them broke the listing in the
      // other direction: a node reading a large prompt is not parked for
      // minutes at a time, so the model it was actively serving vanished from
      // the catalogue and the request was answered "no node is serving that,
      // available: none". Heartbeat says the node exists and holds the model;
      // being parked says it is free this instant, which is a routing
      // question rather than a catalogue one.
      const seen = models.get(row.name)
      models.set(row.name, {
        context: Math.max(seen?.context ?? 0, row.context ?? 0),
        resident: (seen?.resident ?? false) || row.resident,
        // Whether any node holding it can answer this instant. Kept alongside
        // residency rather than replacing it, so the catalogue can say a model
        // exists and is momentarily unreachable - which is the truth while a
        // node reads a long prompt.
        live: (seen?.live ?? false) || broker.isConnected(row.node_id),
      })
    }
    return models
  }


/**
 * Whether this model needs more than one machine, and whether a gang exists.
 *
 * A guard before anything else, because the failure it prevents is silent. A
 * model declared to need two machines, routed by `selectNode`, is dispatched to
 * one - which either fails to load or, worse, loads a model built from a
 * reduced layer count and answers confidently from half a network.
 *
 * Returns null when the model runs on one machine and the ordinary path
 * applies.
 */
async function gangFor(
  db: Db, modelId: string | null, connected: Candidate[],
): Promise<{ refusal: Refusal }
         | { members: { nodeId: string; hostname: string; rank: number; address: string | null }[]
             listenAt: string }
         | null> {
  if (!modelId) return null
  const { rows } = await db.query(
    `SELECT size_bytes, machines, min_memory_gb FROM models WHERE id = $1`, [modelId])
  if (rows.length === 0) return null

  const shape = shapeOf(rows[0] as never)
  if (shape.machines <= 1) return null

  const gang = selectGang(connected, 'generate', modelId, shape.machines)
  if (isRefusal(gang)) return { refusal: gang }

  // Where each machine can be reached for pipeline traffic. Declared by the
  // node, not observed from its connection: the split runs over whatever link
  // the machines share, which is deliberately not always the one they use to
  // reach here.
  const { rows: addrs } = await db.query(
    `SELECT id, pipeline_address FROM nodes WHERE id = ANY($1::uuid[])`,
    [gang.map((c) => c.id)])
  const address = new Map(addrs.map((a) => [a.id as string, a.pipeline_address as string | null]))

  // Rank 0 holds the last layers and the output head, and listens. Everything
  // else dials it. A rank with no address cannot be dialled, so it cannot be
  // rank 0 - and if no member has one, there is no gang to form.
  const ordered = [...gang].sort((a, b) =>
    Number(!!address.get(b.id)) - Number(!!address.get(a.id)))
  if (!address.get(ordered[0]!.id)) {
    return { refusal: {
      refused: 'gang-short',
      detail: 'no machine in this group has said where a peer should dial it; '
        + 'set pipelineInterface on at least the machine holding the output head',
    } }
  }

  return {
    members: ordered.map((c, rank) => ({
      nodeId: c.id, hostname: c.hostname, rank,
      address: address.get(c.id) ?? null,
    })),
    listenAt: address.get(ordered[0]!.id)!,
  }
}

/** The port ranks dial each other on. Fixed: one split runs per machine. */
export const PIPELINE_PORT = 7710

/** What each rank is told, which differs only by rank and where to dial. */
export function splitBody(
  rank: number, size: number, listenAt: string, model: string | null, base: unknown,
): unknown {
  return {
    ...(base as Record<string, unknown>),
    split: {
      rank,
      size,
      model,
      // Rank 0 listens; everything else dials it. Given to both so neither has
      // to infer its job from its rank number, which is the kind of implicit
      // agreement that survives until somebody renumbers.
      role: rank === 0 ? 'listen' : 'dial',
      port: PIPELINE_PORT,
      peer: rank === 0 ? null : listenAt,
    },
  }
}

/**
 * Which group a request is addressed to, which is the socket it arrived on.
 *
 * A group's port is the whole of its addressing: nothing in the request names
 * it, so nothing in the request can name the wrong one. Undefined on the shared
 * serving port, where the fleet is in scope.
 *
 * Set by the middleware that fronts a group's listener; read here rather than
 * threaded through every handler, because the alternative is a parameter on
 * three routes that must never disagree.
 */
export function groupOf(req: Request): string | null {
  return (req as Request & { groupId?: string | null }).groupId ?? null
}

export function servingRoutes(db: Db, broker: Broker): Router {
  const r = Router()

  // A disabled group answers nothing on its own socket.
  //
  // Refused rather than left to fail as "no capacity": the group is standing
  // down deliberately and for a reason somebody chose, and a caller told the
  // fleet is busy would wait for capacity that is not coming back on its own.
  // The listener stays bound, because a connection refused at the socket is
  // indistinguishable from a control plane that has fallen over.
  r.use(async (req, res, next) => {
    const group = groupOf(req)
    if (!group) { next(); return }
    const { rows } = await db.query(`SELECT name, enabled FROM pools WHERE id = $1`, [group])
    const pool = rows[0] as { name: string; enabled: boolean } | undefined
    if (pool && pool.enabled === false) {
      res.status(503).json({ error: {
        message: `the ${pool.name} group is disabled and is serving nothing; `
          + 'its machines have been handed back to whatever else they belong to',
        type: 'no_capacity', code: 'group-disabled' } })
      return
    }
    next()
  })
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
  /**
   * Models this fleet can serve, and how much context each accepts.
   *
   * Only from nodes that could answer right now. The listing reported a model
   * as loaded with nothing connected, because it read the last heartbeat a node
   * ever sent, and a capability check is exactly where that misleads: a client
   * asks what is available, is told, and every request then fails. Stale is
   * worse than empty here, because empty is actionable.
   *
   * The window is advertised so a client does not have to guess: guess high and
   * the conversation runs past what the model takes, guess low and most of it
   * goes unused. Taken from what nodes report rather than configured here, so it
   * cannot drift from the weights on disk.
   */
  r.get('/models', async (req, res) => {
    const models = await servableModels(db, broker, groupOf(req))
    res.json({
      object: 'list',
      data: [...models].map(([id, m]) => ({
        id,
        object: 'model',
        owned_by: 'dai',
        // Three spellings: context_length is what clients look for, the others
        // are the OpenAI and LM Studio shapes. A client finding any of them
        // does not have to fall back to a default.
        context_length: m.context || null,
        max_context_length: m.context || null,
        context_window: m.context || null,
      })),
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
    const candidates = await candidatesFor(db, broker.inFlightCounts, groupOf(req))
    // Only nodes holding the reverse channel open can be routed to. A node that
    // is eligible on paper but not listening cannot answer in time.
    const connected = candidates.filter((c) => broker.isConnected(c.id))

    // A split model is not a big model. Routing it as though it were dispatches
    // one machine to run something built from a reduced layer count, which
    // answers rather than failing.
    const gang = await gangFor(db, modelHash, connected)
    if (gang && 'refusal' in gang) {
      res.status(503).json({ error: {
        message: gang.refusal.detail,
        type: 'no_capacity',
        code: gang.refusal.refused,
      } })
      return
    }

    // A gang has already chosen its machines and rank 0 is the one that
    // answers, so it stands in for the single node everywhere below. Running
    // selectNode as well would pick a different machine and cap the completion
    // by the presence of one that is not going to serve it.
    const head = gang && 'members' in gang
      ? connected.find((c) => c.id === gang.members[0]!.nodeId)!
      : null
    const choice = head ?? selectNode(connected, 'generate', modelHash)
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
    const request = { messages: body.messages, max_tokens: maxTokens, model: modelHash }
    const out = gang && 'members' in gang
      ? await broker.dispatchGang(
          gang.members, 'generate', modelHash,
          (rank) => splitBody(rank, gang.members.length, gang.listenAt, modelHash, request))
      : await broker.dispatch(choice.id, 'generate', modelHash, request)

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

  r.post('/messages/count_tokens', async (req, res) => {
    const body = req.body as {
      model?: string
      messages: { role: string; content: unknown }[]
      system?: unknown
      tools?: unknown[]
    }

    const servable = await servableModels(db, broker, groupOf(req))
    if (!body.model || !servable.has(body.model)) {
      res.status(404).json({
        type: 'error',
        error: {
          type: 'not_found_error',
          message: body.model
            ? `no node is serving "${body.model}". Available: `
              + ([...servable.keys()].join(', ') || 'none')
            : 'model is required',
        },
      })
      return
    }

    const candidates = await candidatesFor(db, broker.inFlightCounts, groupOf(req))
    const connected = candidates.filter((c) => broker.isConnected(c.id))
    // No gang for counting. Every rank loads the same tokenizer and chat
    // template from the same directory, so one machine can answer this for a
    // split model - and asking two to do it would occupy the pipeline for a
    // question that is meant to be cheap enough to ask before every turn.
    const choice = selectNode(connected, 'generate', body.model)
    if (isRefusal(choice)) {
      res.status(503).json({
        type: 'error',
        error: { type: 'overloaded_error', message: choice.detail },
      })
      return
    }

    const messages = body.system
      ? [{ role: 'system', content: body.system }, ...body.messages]
      : body.messages

    const cancel = new AbortController()
    res.on('close', () => { if (!res.writableEnded) cancel.abort() })

    const out = await broker.dispatch(choice.id, 'generate', body.model, {
      operation: 'count_tokens',
      messages,
      tools: body.tools,
    }, cancel.signal)

    if (cancel.signal.aborted) return
    if (!out.ok) {
      res.status(503).json({
        type: 'error',
        error: { type: 'api_error', message: out.error },
      })
      return
    }

    const result = out.body as { promptTokens?: number }
    res.json({ input_tokens: result.promptTokens ?? 0 })
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
      tools?: unknown[]
      tool_choice?: { type: string; name?: string }
    }

    // The requested model has to exist. It was ignored entirely, so a typo or
    // a model nobody has loaded returned a confident answer from whatever
    // happened to be resident - the worst possible response to asking for
    // something specific.
    const servable = await servableModels(db, broker, groupOf(req))
    if (!body.model || !servable.has(body.model)) {
      res.status(404).json({
        type: 'error',
        error: {
          type: 'not_found_error',
          message: body.model
            ? `no node is serving "${body.model}". Available: `
              + ([...servable.keys()].join(', ') || 'none')
            : 'model is required',
        },
      })
      return
    }

    const modelHash = body.model
    const candidates = await candidatesFor(db, broker.inFlightCounts, groupOf(req))
    const connected = candidates.filter((c) => broker.isConnected(c.id))

    // A split model is not a big model. Routed as one it goes to a single
    // machine, which loads something built from a reduced layer count and
    // answers from half a network rather than failing.
    const gang = await gangFor(db, modelHash, connected)
    if (gang && 'refusal' in gang) {
      res.status(503).json({
        type: 'error',
        error: { type: 'overloaded_error', message: gang.refusal.detail },
      })
      return
    }
    // Rank 0 holds the output head and is the machine that answers, so it
    // stands in for the single node below: presence policy, the completion cap,
    // and which machine the caller is told served them.
    const head = gang && 'members' in gang
      ? connected.find((c) => c.id === gang.members[0]!.nodeId)!
      : null
    const choice = head ?? selectNode(connected, 'generate', modelHash)

    if (isRefusal(choice)) {
      // Busy is not the same as gone, and saying the wrong one sends people
      // looking for a crash. A node reading a large prompt is not parked on the
      // channel for minutes at a time - 19,243 tokens measured at 377 seconds -
      // so it is heartbeating, healthy, and unavailable, which read as
      // "no active nodes are connected" and looked exactly like a dead fleet.
      const busy = connected.length === 0 && candidates.length > 0
      res.status(503).json({
        type: 'error',
        error: {
          type: 'overloaded_error',
          message: busy
            ? `every node is busy: ${candidates.length} healthy, `
              + 'all mid-request. A large prompt occupies a node for the whole '
              + 'time it takes to read it.'
            : choice.detail,
        },
      })
      return
    }

    // Cluster nodes are not capped by presence, for the same reason they are
    // not gated by it: the cap exists to bound how long a returning user waits
    // for their own machine, and nobody is sitting at a dedicated box. Capping
    // there silently truncated every answer at 256 tokens, which reads as a
    // model that stops mid-sentence.
    const policy = POLICY[(choice.presence_state ?? 'ACTIVE') as PresenceState]
    const requested = body.max_tokens ?? 512
    const maxTokens = choice.tier === 'cluster'
      ? requested
      : Math.min(requested, policy.maxCompletionTokens)

    // The system prompt rides as a leading message. The runtime takes one
    // string, and dropping it silently would change the model's behaviour in a
    // way nobody could see from here.
    const messages = body.system
      ? [{ role: 'system', content: body.system }, ...body.messages]
      : body.messages

    // A caller who has gone should not keep a node busy. Ctrl-C in an
    // interactive client is the common case, not an edge one, and a node is
    // serial: whatever it is doing, nothing else can be.
    const cancel = new AbortController()
    // res, not req. The request stream closes once its body has been read,
    // which for a POST is long before the caller goes anywhere, so listening
    // there detected nothing at all. The response closing is what means the
    // connection is gone.
    res.on('close', () => { if (!res.writableEnded) cancel.abort() })

    const id = `msg_${Date.now()}`

    /**
     * Open the stream before the work starts, and keep it alive while it runs.
     *
     * Nothing was written until the node had finished, so a request that took
     * minutes - which a large prompt does - sent no bytes at all for those
     * minutes. A client waiting on a stream that says nothing eventually gives
     * up, and it gives up with an error of its own that names nothing on this
     * side: the server logged a success and the caller reported a failure.
     *
     * The API this imitates opens with message_start immediately and sends
     * pings while it thinks, which is what makes a long answer distinguishable
     * from a dead connection.
     */
    let ping: ReturnType<typeof setInterval> | undefined
    const send = (event: string, data: unknown) => {
      if (res.writableEnded) return
      res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)
    }
    if (body.stream) {
      res.writeHead(200, {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        connection: 'keep-alive',
      })
      send('message_start', { type: 'message_start', message: {
        id, type: 'message', role: 'assistant', model: modelHash ?? 'default',
        content: [], stop_reason: null, stop_sequence: null,
        // Not yet known: the node has not read the prompt. The final
        // message_delta carries the real figures, as it does upstream.
        usage: { input_tokens: 0, output_tokens: 0 },
      } })
      ping = setInterval(() => send('ping', { type: 'ping' }), 10_000)
      res.on('close', () => clearInterval(ping))
    }

    const started = Date.now()
    const request = {
      messages,
      max_tokens: maxTokens,
      model: modelHash,
      // Passed down rather than dropped. Discarding these was the difference
      // between an agent and a chat box: the model never learned the tools
      // existed, so it invented plausible-looking syntax instead of calling
      // anything, and tool_choice made no difference because nothing was
      // reaching the model either way.
      tools: body.tools,
      tool_choice: body.tool_choice,
    }
    const out = gang && 'members' in gang
      ? await broker.dispatchGang(
          gang.members, 'generate', modelHash,
          (rank) => splitBody(rank, gang.members.length, gang.listenAt, modelHash, request),
          cancel.signal)
      : await broker.dispatch(choice.id, 'generate', modelHash, request, cancel.signal)

    // Nobody is listening; saying so into a closed socket only produces a
    // second error in the log.
    if (cancel.signal.aborted) return

    clearInterval(ping)
    if (!out.ok) {
      // A prompt the node cannot read is the caller's request being too large,
      // and it will never succeed however often it is sent. 503 says the
      // opposite - transient, retry me - so a well-behaved client retries
      // forever. The API this imitates answers 400 with "prompt is too long".
      const tooLong = (out.error ?? '').includes('prompt is too long')
      if (body.stream) {
        // The status is already sent, so the failure has to arrive as an event.
        // Ending the stream silently would look like an empty answer.
        send('error', { type: 'error', error: {
          type: tooLong ? 'invalid_request_error' : 'api_error',
          message: out.error,
        } })
        res.end()
        return
      }
      res.status(tooLong ? 400 : 503).json({
        type: 'error',
        error: {
          type: tooLong ? 'invalid_request_error' : 'api_error',
          message: out.error,
        },
      })
      return
    }

    const result = out.body as {
      text: string; promptTokens?: number; completionTokens?: number
      cachedTokens?: number
      toolCalls?: { name: string; arguments: unknown }[]
    }


    // Split the way the API this imitates splits it: every prompt token lands
    // in exactly one bucket, so a client summing them gets the prompt it sent.
    //
    // Reported at all because caching was invisible without it - the saving is
    // real and large, and a client showing a context gauge had no way to know
    // any of it had happened.
    //
    // Every prompt token this node reads is also kept, so what was processed is
    // what was written to the cache.
    //
    // Reporting creation as zero was defensible and unhelpful: it left a client
    // unable to tell a cold call that populated the cache from one that could
    // not be cached at all - the difference between "the next turn will be
    // fast" and "this will be slow forever". input_tokens is what was read and
    // not retained, which on this node is nothing.
    // input_tokens is what was read this turn, and cache_read what was not.
    //
    // The two cannot both be reported: every token this node reads is also
    // retained, so counting the same tokens as creation and as input would
    // double the prompt for anyone summing them. Given that choice, input
    // wins - the API this imitates never reports zero for a non-empty prompt,
    // and a client tracking context from that field alone would see a
    // conversation that never grows.
    //
    // cache_creation therefore stays zero, which is also what upstream reports
    // for a request that did not ask for a cache write. Ours is implicit, and
    // the saving is visible in cache_read either way.
    const cached = result.cachedTokens ?? 0
    const usage = {
      input_tokens: Math.max(0, (result.promptTokens ?? 0) - cached),
      cache_read_input_tokens: cached,
      cache_creation_input_tokens: 0,
      output_tokens: result.completionTokens ?? 0,
    }

    // Content blocks, in the order a client expects: any prose first, then the
    // calls. A tool_use block carries an id the client quotes back on the
    // matching tool_result, which is how a conversation with several calls in
    // flight stays coherent.
    // Only calls to tools that were actually offered.
    //
    // A small model will name a tool nobody declared - inventing one that
    // sounds plausible for the task - and passing that through makes the client
    // look up something that does not exist, or worse, run something it
    // recognises by accident. The model's prose is kept, so the reply is not
    // silently emptied.
    const declared = new Set((body.tools ?? []).map((t: any) => t?.name).filter(Boolean))
    const proposed = result.toolCalls ?? []
    const calls = declared.size > 0
      ? proposed.filter((c) => declared.has(c.name))
      : proposed
    const rejected = proposed.filter((c) => !calls.includes(c))
    if (rejected.length > 0) {
      console.log(`[serving] dropped ${rejected.length} call(s) to undeclared tool(s): `
        + rejected.map((c) => c.name).join(', '))
    }

    // tool_choice is a requirement, not a hint. The spec says a forced choice
    // must produce a tool_use block, so a model that answered in prose has not
    // satisfied the request and saying otherwise would have the client treat
    // its commentary as an answer.
    const forced = body.tool_choice?.type === 'tool' ? body.tool_choice.name
      : body.tool_choice?.type === 'any' ? true : null
    if (forced && calls.length === 0) {
      // 400, not 422: the API this imitates returns invalid_request_error with
      // a 400, and a client keying on the status will not recognise anything
      // else as its own fault.
      res.status(400).json({
        type: 'error',
        error: {
          type: 'invalid_request_error',
          message: typeof forced === 'string'
            ? `tool_choice required ${forced}, but the model did not call it. `
              + 'Smaller models often will not: the call was either absent or '
              + 'malformed.'
            : 'tool_choice required a tool call and the model did not make one.',
        },
      })
      return
    }

    const content: unknown[] = []
    if (result.text.trim().length > 0) content.push({ type: 'text', text: result.text })
    calls.forEach((call, i) => {
      content.push({
        type: 'tool_use',
        id: `toolu_${started}_${i}`,
        name: call.name,
        input: call.arguments ?? {},
      })
    })
    if (content.length === 0) {
      // Something has to be said. The model produced only calls to tools nobody
      // declared, so dropping them correctly left nothing at all, and a reply
      // with an empty text block renders as a blank turn: the user sees the
      // agent do nothing and cannot tell why.
      content.push({
        type: 'text',
        text: rejected.length > 0
          ? 'The model tried to call '
            + rejected.map((c) => `"${c.name}"`).join(', ')
            + ', which was not among the tools provided, so the call was not made.'
          : result.text,
      })
    }

    // tool_use takes precedence over max_tokens: a client that sees anything
    // else will treat the calls as commentary and never execute them.
    const stopReason = calls.length > 0 ? 'tool_use'
      : (result.completionTokens ?? 0) >= maxTokens ? 'max_tokens' : 'end_turn'

    if (body.stream) {
      // Replayed as a stream rather than streamed as it is produced.
      //
      // A completion is dispatched to a node as one unit so that a preemption
      // has a bounded worst case, and that decision is upstream of this. What
      // this does is let clients that require SSE work at all - the whole
      // answer arrives in one text delta. Honest about it here rather than in
      // a comment nobody reads: the caller waits the same time and then gets
      // everything, so there is no incremental display.
      // The stream was opened and message_start sent before the work began, so
      // that a caller waiting minutes for a large prompt sees an open
      // connection rather than silence. Only the content follows here.
      // Each block start, delta and stop, in order. A tool_use block streams
      // its input as input_json_delta rather than as a field on the start
      // event, which is what clients parse: sending the whole thing up front
      // leaves them waiting for deltas that never arrive.
      content.forEach((block: any, index: number) => {
        if (block.type === 'text') {
          send('content_block_start', {
            type: 'content_block_start', index,
            content_block: { type: 'text', text: '' },
          })
          send('content_block_delta', {
            type: 'content_block_delta', index,
            delta: { type: 'text_delta', text: block.text },
          })
        } else {
          send('content_block_start', {
            type: 'content_block_start', index,
            content_block: { type: 'tool_use', id: block.id, name: block.name, input: {} },
          })
          send('content_block_delta', {
            type: 'content_block_delta', index,
            delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input ?? {}) },
          })
        }
        send('content_block_stop', { type: 'content_block_stop', index })
      })
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
      content,
      stop_reason: stopReason,
      stop_sequence: null,
      usage,
      // The same block `/v1/chat/completions` returns, and it was missing here
      // for no better reason than that the two response shapes were written at
      // different times. A caller on the Anthropic surface could not see which
      // machine had answered, which on this fleet is not a detail: it is the
      // difference between an answer that came off a named machine somebody
      // owns and one that could have come from anywhere.
      //
      // It matters most on the machine that is both control plane and node.
      // There, an answer served locally and an answer that never left the
      // process look identical from outside, and this block is what tells them
      // apart - it can only be filled in by the router that picked the node.
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

/**
 * LM Studio's model shape, on its own router.
 *
 * Mounted at /api, and only this. Mounting the whole serving router there
 * exposed every endpoint twice under an undocumented prefix - /api/messages,
 * /api/chat/completions and the rest - which nothing validated and nobody
 * meant to publish. A conformance test found it on its first run.
 */
export function compatRoutes(db: Db, broker: Broker): Router {
  const r = Router()
  r.get('/v0/models', async (req, res) => {
    const models = await servableModels(db, broker, groupOf(req))
    res.json({
      object: 'list',
      data: [...models].map(([id, m]) => ({
        id,
        object: 'model',
        // A model with no context window is not a chat model. Typing everything
        // as llm made an embedding model look like something a client could
        // send a conversation to, and anything routing off that field would
        // pick it.
        type: m.context > 0 ? 'llm' : 'embeddings',
        publisher: 'dai',
        max_context_length: m.context || null,
        loaded_context_length: m.context || null,
        // Reconciled with what a request would actually do. Reporting "loaded"
        // while /v1/messages answers "no nodes connected" is two views of one
        // fleet disagreeing, and it is exactly what makes a listing-based
        // health check untrustworthy.
        state: !m.live ? 'busy' : m.resident ? 'loaded' : 'not-loaded',
      })),
    })
  })

  /**
   * How many tokens a request would cost, before sending it.
   *
   * Counted by the node's own tokeniser and chat template rather than
   * estimated here. An approximate count feeding a client's decision about what
   * to send is a slower version of advertising a context window nothing can
   * reach: it is wrong in the direction that produces either refused requests
   * or truncated conversations, and the client has no way to know which.
   *
   * Tools are included, since their schemas are rendered into the prompt and
   * are often the larger half of it.
   */
  return r
}
