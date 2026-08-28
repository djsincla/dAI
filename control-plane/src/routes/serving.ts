import { Router, type Request } from 'express'
import type { Db } from '../lib/db.js'
import type { Broker } from '../lib/broker.js'
import { userAuth } from '../lib/auth.js'
import { POLICY, type PresenceState, type WorkKind } from '../lib/policy.js'
import { candidatesFor, isRefusal, selectGang, selectNode,
         type Candidate, type Refusal } from '../lib/router.js'
import { shapeOf } from '../lib/shape.js'
import { membersOf } from '../lib/pools.js'
import { splitReport } from '../lib/splitReport.js'
import { assignRanks } from '../lib/splitRanks.js'

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
/// How many inputs one embeddings request may carry.
///
/// The request is dispatched to one machine as a single unit, so a preemption
/// discards all of it and the caller retries all of it. A large batch turns a
/// yield, which is meant to cost seconds, into re-embedding a corpus. 256 is
/// comfortably more than a page of text and comfortably less than that.
const EMBED_BATCH_MAX = 256

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

    // How wide each model is, so the catalogue can say so. A model that runs
    // across machines is a different proposition from one that does not - it
    // needs a group set up for it and it takes those machines out of harvesting
    // - and a name alone does not tell anybody that.
    const { rows: shapes } = await db.query(`SELECT id, machines, kind FROM models`)
    const machines = new Map((shapes as { id: string; machines: number }[])
      .map((m) => [m.id, Math.max(1, Number(m.machines ?? 1))]))

    // What each model is, so both catalogue surfaces can say so.
    //
    // This was a filter that hid embedding models entirely, because
    // `POST /v1/embeddings` returned 404 and listing a model no endpoint could
    // reach invited exactly the request that would fail. The endpoint exists
    // now and answers with vectors that agree with the reference client, so the
    // models are listed and typed instead of hidden.
    //
    // Keyed on models.kind rather than on a zero context window. Context is
    // COALESCEd from what nodes report, so zero means "no context reported",
    // which an embedding model and a generation model whose node has not
    // reported one both satisfy.
    const kinds = new Map((shapes as { id: string; kind: string }[])
      .map((m) => [m.id, m.kind]))

    const scope = groupId ? await membersOf(db, groupId) : null

    // A split model belongs to the group an operator assigned it to, and to no
    // other socket.
    //
    // The weights stay on the machines after a split group is stood down, so a
    // harvest group sharing those machines went on advertising a model it can
    // never run: the catalogue said the 32B was available on :8463, and every
    // request for it was refused with "no cluster group is serving it". The
    // socket was offering something it would always turn down, which is a
    // worse failure than not offering it - a caller has no way to tell an
    // advertised model from a servable one, and picks by name.
    //
    // Asked of this group rather than of the fleet: the group that declared the
    // split still lists it, because there it is true.
    //
    // A group that names no model declares its staged models instead, and this
    // has to say so or the filter fails in the other direction: the set would
    // be empty and every split model would vanish from the socket of the group
    // that exists to run them. The two branches mirror `gangFor` deliberately -
    // a socket that advertises what the router will refuse is the fault this
    // whole filter was written for, and it is the same fault whichever way the
    // disagreement runs.
    const declared = groupId
      ? await splitsOfferedBy(db, groupId)
      : null
    const splitHere = declared && new Set([...declared.pinned, ...declared.staged])

    const models = new Map<string, {
      context: number; resident: boolean; live: boolean; machines: number
      // What the repository says this is. Absent for a model a node holds that
      // was never imported, which is treated as a chat model: that is what it
      // was before kinds existed, and hiding it would empty the catalogue on a
      // fleet that stages outside the repository.
      kind: string
    }>()
    // Which in-scope machines hold each model, kept beside the listing rather
    // than in it. A staged split is only worth offering when enough of the
    // group's machines actually have the weights; see below.
    const holders = new Map<string, Set<string>>()
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
      // Declared wider than one machine, and not the model this group was told
      // to serve: not this socket's to offer.
      const width = machines.get(row.name as string) ?? 1
      if (splitHere !== null && width > 1 && !splitHere.has(row.name as string)) continue

      const held = holders.get(row.name as string) ?? new Set<string>()
      held.add(row.node_id as string)
      holders.set(row.name as string, held)

      const seen = models.get(row.name)
      models.set(row.name, {
        context: Math.max(seen?.context ?? 0, row.context ?? 0),
        resident: (seen?.resident ?? false) || row.resident,
        // Whether any node holding it can answer this instant. Kept alongside
        // residency rather than replacing it, so the catalogue can say a model
        // exists and is momentarily unreachable - which is the truth while a
        // node reads a long prompt.
        live: (seen?.live ?? false) || broker.isConnected(row.node_id),
        machines: width,
        kind: kinds.get(row.name as string) ?? 'generate',
      })
    }

    // A staged split nobody finished staging is not offered.
    //
    // Only for the models a dynamic group chose from what it holds. Pushing
    // weights is the operator's own act and nothing checks it finished, so a
    // 2-machine model that reached one machine would be advertised and then
    // refused at dispatch for want of a second rank - the caller picking by
    // name, exactly as before.
    //
    // A group pinned to a model is left alone: it is asserting that this is
    // what it serves, its readiness view says the weights are still arriving,
    // and removing it from the catalogue mid-fetch would report an operator's
    // decision as an absence.
    if (declared) {
      for (const [name, m] of models) {
        if (m.machines > 1 && declared.staged.has(name) && !declared.pinned.has(name)
            && (holders.get(name)?.size ?? 0) < m.machines) {
          models.delete(name)
        }
      }
    }
    return models
  }

/**
 * The split models a group may run: the one it was pinned to, or the ones it
 * was staged with when it was pinned to none.
 *
 * Split so the caller can tell them apart - a pinned model is offered while its
 * weights are still arriving, because the group is asserting it serves that and
 * the readiness view says why it cannot yet. A staged one carries no such
 * assertion and is only worth advertising once the machines can actually run it.
 */
async function splitsOfferedBy(
  db: Db, groupId: string,
): Promise<{ pinned: Set<string>; staged: Set<string> }> {
  const { rows } = await db.query(
    `SELECT p.serving_model_id AS pinned, pm.model_id AS staged
       FROM pools p
       LEFT JOIN pool_models pm
         ON pm.pool_id = p.id AND p.serving_model_id IS NULL
      WHERE p.id = $1 AND p.enabled AND p.tier = 'cluster'`,
    [groupId])
  const pinned = new Set<string>()
  const staged = new Set<string>()
  for (const r of rows as { pinned: string | null; staged: string | null }[]) {
    if (r.pinned) pinned.add(r.pinned)
    if (r.staged) staged.add(r.staged)
  }
  return { pinned, staged }
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

  // A split runs where an operator said it should, and nowhere else.
  //
  // Without this the request decides: name a model that happens to need two
  // machines and any cluster group would be assembled into a pipeline for it.
  // That is the wrong way round. Running a split is a decision about the fleet -
  // it takes those machines out of harvesting for as long as it stands, which is
  // why assigning one already has to be confirmed - and a caller should be able
  // to use what an operator has set up, not to set it up by asking.
  //
  // The declaration is the group's serving model. There is no separate switch
  // to keep in step with it, and no way to declare a split for a model that is
  // not one.
  //
  // A group that names no model declares something different and just as
  // deliberate: it serves whichever model an operator staged to it. That is
  // still the operator deciding and not the request - `pool_models` is written
  // by an admin route and pushing weights to a machine is the same act of
  // spending the fleet - but the choice among what was staged is left to the
  // caller. Staged, not merely cluster-tier: without the join a dynamic group
  // would accept any model in the catalogue and fail at dispatch, with the
  // machines discovering the weights were never there.
  const { rows: serving } = await db.query(
    `SELECT id, name FROM pools p
      WHERE p.tier = 'cluster' AND p.enabled
        AND (p.serving_model_id = $1
             OR (p.serving_model_id IS NULL
                 AND EXISTS (SELECT 1 FROM pool_models pm
                              WHERE pm.pool_id = p.id AND pm.model_id = $1)))`,
    [modelId])
  if (serving.length === 0) {
    return { refusal: {
      refused: 'not-offered',
      detail: `${modelId} runs across ${shape.machines} machines, and no cluster group `
        + 'is serving it or has been staged it. A split runs where an operator has '
        + 'assigned it, because it takes those machines out of harvesting for as long '
        + 'as it stands.',
    } }
  }
  const offered = new Set(serving.map((p) => p.id as string))
  const eligible = connected.filter((c) => c.group_id != null && offered.has(c.group_id))

  const gang = selectGang(eligible, 'generate', modelId, shape.machines)
  if (isRefusal(gang)) return { refusal: gang }

  // Where each machine can be reached for pipeline traffic. Declared by the
  // node, not observed from its connection: the split runs over whatever link
  // the machines share, which is deliberately not always the one they use to
  // reach here.
  const { rows: addrs } = await db.query(
    `SELECT id, pipeline_address, agent_fingerprint
       FROM nodes WHERE id = ANY($1::uuid[])`,
    [gang.map((c) => c.id)])

  // Every rank has to be running the same build.
  //
  // What the ranks say to each other is an internal protocol with no version
  // field and no negotiation: hidden states, sampled tokens, and now a proposal
  // about how much of the prompt has already been read. A rank that does not
  // know about the last of those receives nine words where it expects a hidden
  // state, and either throws on the shape or waits out the 120 s transport
  // deadline.
  //
  // This is not hypothetical. Rolling 0.6.0 across this fleet left one machine
  // on 0.5.1 and the other on 0.6.0 for eight minutes; a split request in that
  // window would have hung. Refusing is the honest answer - the gang genuinely
  // cannot run - and it resolves itself as the upgrade finishes.
  const builds = new Set((addrs as { agent_fingerprint: string | null }[])
    .map((a) => a.agent_fingerprint ?? 'unknown'))
  if (builds.size > 1) {
    return { refusal: {
      refused: 'gang-short',
      detail: 'the machines in this group are running different agent builds, and '
        + 'the ranks of a split speak a protocol with no version negotiation. '
        + 'This resolves itself when the rollout finishes.',
    } }
  }
  const address = new Map(addrs.map((a) => [a.id as string, a.pipeline_address as string | null]))

  // Rank 0 holds the last layers and the output head, and listens. Everything
  // else dials it. A rank with no address cannot be dialled, so it cannot be
  // rank 0 - and if no member has one, there is no gang to form.
  //
  // From the same implementation the readiness view and the heartbeat use, so a
  // group reported ready is a group admitted here, and a machine that warmed a
  // share warmed the one it is about to be asked for.
  const ordered = assignRanks(gang.map((c) => ({
    id: c.id, hostname: c.hostname, pipelineAddress: address.get(c.id) ?? null,
  })))
  if (ordered === null) {
    return { refusal: {
      refused: 'gang-short',
      detail: 'no machine in this group has said where a peer should dial it; '
        + 'set pipelineInterface on at least the machine holding the output head',
    } }
  }

  return {
    members: ordered.map((r) => ({
      nodeId: r.member.id, hostname: r.member.hostname, rank: r.rank,
      address: r.member.pipelineAddress,
    })),
    listenAt: ordered[0]!.member.pipelineAddress!,
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
        // What this model is, in the shape this surface reserves for things
        // OpenAI never had. A client that ignores it is unaffected; one that
        // reads it learns that asking for this model engages more than one
        // machine, which is not something the name says.
        dai: shapeNote(m.machines),
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

    const result = out.body as {
      text: string; promptTokens: number; completionTokens: number; layerPlan?: unknown
    }
    // The gang was known at dispatch and thrown away here until now. Reporting
    // it is what turns "the catalogue says this model is split" into "these
    // machines served this request".
    const split = splitReport(
      gang && 'members' in gang ? gang.members : null, result.layerPlan)
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
        // Absent entirely on a single-machine completion, so `if (dai.split)`
        // reads correctly rather than needing a `split: false` on every answer
        // this fleet has ever served.
        ...(split ? { split } : {}),
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
        error: { type: 'overloaded_error', message: choice.detail,
                 dai: { code: choice.refused } },
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
        // The refusal's own name, alongside the sentence. Anthropic's error
        // shape has no code, so a caller wanting to tell "nobody assigned this"
        // from "the machines cannot reach each other" would otherwise have to
        // match on prose that is written to be read and rewritten to be
        // clearer. An unknown field is ignored by any client that does not want
        // it, which is the same bargain the model catalogue's `dai` block makes.
        error: { type: 'overloaded_error', message: gang.refusal.detail,
                 dai: { code: gang.refusal.refused } },
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
          dai: { code: busy ? 'all-in-use' : choice.refused },
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
      layerPlan?: unknown
    }
    const split = splitReport(
      gang && 'members' in gang ? gang.members : null, result.layerPlan)


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
        ...(split ? { split } : {}),
      },
    })
  })

  /**
   * Embeddings, OpenAI shaped.
   *
   * Every refusal below exists because the alternative is a vector that looks
   * correct and is not. A caller cannot tell a good embedding from a bad one by
   * inspecting it: both are the right length, in the right range, and compare
   * cleanly by cosine. The failure surfaces weeks later as poor retrieval,
   * blamed on the model. So this endpoint refuses loudly rather than answering
   * approximately, which is the same argument docs/EMBEDDINGS.md makes for
   * having returned 404 until the vectors were real.
   *
   * `input_type` is an extension to the OpenAI shape and is not decoration.
   * Nomic and E5 models are trained with a prefix declaring whether text is a
   * query or a passage, and the same words embedded as the wrong one land
   * measurably elsewhere. OpenAI's schema has nowhere to put it, so a plain
   * OpenAI client will not send it and gets `document`, which is right for the
   * common case of embedding a corpus.
   */
  r.post('/embeddings', async (req, res) => {
    const body = req.body as {
      model?: string
      input?: unknown
      input_type?: string
      encoding_format?: string
    }

    const fail = (status: number, type: string, message: string, extra = {}) =>
      res.status(status).json({ error: { type, message, ...extra } })

    if (!body.model) return void fail(400, 'invalid_request_error', 'model is required')

    // The kind is checked before anything else. Sending a conversation to an
    // embedding model, or a passage to a chat model, produces something in both
    // directions, and neither is what was asked for.
    const { rows: known } = await db.query(
      `SELECT id, kind, runtime FROM models WHERE id = $1`, [body.model])
    const model = known[0] as { id: string; kind: string; runtime: string } | undefined
    if (!model) {
      return void fail(404, 'not_found_error',
        `no model called "${body.model}" is in the catalogue`)
    }
    if (model.kind !== 'embed') {
      return void fail(400, 'invalid_request_error',
        `"${body.model}" is a ${model.kind} model. Embedding one would return a `
        + 'vector of the right shape that means nothing. Use /v1/chat/completions '
        + 'for generation, or name an embedding model.')
    }

    const input = Array.isArray(body.input) ? body.input : [body.input]
    if (input.length === 0 || input.some((i) => typeof i !== 'string')) {
      return void fail(400, 'invalid_request_error',
        'input must be a string or a non-empty array of strings')
    }
    if (input.some((i) => (i as string).trim() === '')) {
      // An empty string embeds to whatever the model does with nothing, which
      // is a real vector at a fixed point in the space. It would then be
      // "similar" to every other empty input and to nothing else, which is a
      // silent corruption of an index rather than an error.
      return void fail(400, 'invalid_request_error',
        'input contains an empty string, which embeds to a fixed point that is '
        + 'not about anything. Drop it rather than indexing it.')
    }
    // The next three are also expressed in openapi/dai.yaml, and the validator
    // runs before this handler, so in normal operation it answers first. They
    // are kept because the schema and the handler can drift, and of the two the
    // handler is the one that knows what the number means.
    if (input.length > EMBED_BATCH_MAX) {
      return void fail(400, 'invalid_request_error',
        `${input.length} inputs exceeds the limit of ${EMBED_BATCH_MAX}. Send `
        + 'them in batches: the request is dispatched to one machine as a unit '
        + 'and a preemption discards the whole of it.')
    }
    if (body.encoding_format && body.encoding_format !== 'float') {
      return void fail(400, 'invalid_request_error',
        `encoding_format "${body.encoding_format}" is not supported; only float`)
    }
    const inputType = body.input_type ?? 'document'
    if (inputType !== 'document' && inputType !== 'query') {
      return void fail(400, 'invalid_request_error',
        'input_type must be "query" or "document"')
    }

    // **Which device this runs on decides which machines may take it.**
    //
    // `permittedKinds` allows 'embed' in every presence state, including
    // ACTIVE, because embed meant Core ML on the Neural Engine and the ANE is
    // not what somebody's desktop contends for. An MLX embedding model runs on
    // the GPU and contends exactly as generation does, so it is gated exactly
    // as generation is. Sending it as 'embed' would put GPU work on a machine
    // whose owner is using it, which is the one failure this project cannot
    // afford socially.
    //
    // When the Core ML path lands, a model with runtime 'coreml' passes 'embed'
    // here and regains presence independence, which is the whole point of that
    // work. See docs/EMBEDDINGS_PLAN.md.
    const presenceKind: WorkKind = model.runtime === 'coreml' ? 'embed' : 'generate'

    const candidates = await candidatesFor(db, broker.inFlightCounts, groupOf(req))
    const connected = candidates.filter((c) => broker.isConnected(c.id))
    const choice = selectNode(connected, presenceKind, body.model)
    if (isRefusal(choice)) {
      return void fail(503, 'overloaded_error', choice.detail,
                       { dai: { code: choice.refused } })
    }

    const cancel = new AbortController()
    res.on('close', () => { if (!res.writableEnded) cancel.abort() })

    const out = await broker.dispatch(choice.id, 'embed', body.model, {
      operation: 'embed',
      input,
      inputType,
    }, cancel.signal)

    if (cancel.signal.aborted) return
    if (!out.ok) return void fail(503, 'api_error', out.error)

    const vectors = (out.body as { embeddings?: number[][] })?.embeddings
    if (!Array.isArray(vectors) || vectors.length !== input.length) {
      // Counted rather than trusted. A node returning fewer vectors than inputs
      // would otherwise pair them off by position and attach every vector after
      // the gap to the wrong text, with nothing to see in the response.
      return void fail(502, 'api_error',
        `the node returned ${Array.isArray(vectors) ? vectors.length : 0} vectors `
        + `for ${input.length} inputs`)
    }

    res.json({
      object: 'list',
      model: body.model,
      data: vectors.map((embedding, index) => ({
        object: 'embedding', index, embedding,
      })),
      usage: { prompt_tokens: 0, total_tokens: 0 },
      dai: {
        node: choice.hostname,
        presenceState: choice.presence_state,
        // Stated rather than left to be inferred, because a caller mixing
        // vectors made with different prefixes gets a quietly worse index and
        // no way to find out afterwards which is which.
        inputType,
        normalized: true,
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
        // From the catalogue's own kind, not from a context window.
        //
        // This read `m.context > 0 ? 'llm' : 'embeddings'`, which typed off a
        // value COALESCEd to zero when a node has not reported one. That is
        // true of an embedding model and also of a chat model on a node that
        // was slow to report, so the field announced the wrong kind in the
        // direction that matters: a usable model described as something a
        // client cannot send a conversation to. A model the repository has
        // never seen is a chat model, which is what it was before kinds
        // existed.
        type: m.kind === 'embed' ? 'embeddings' : 'llm',
        publisher: 'dai',
        max_context_length: m.context || null,
        loaded_context_length: m.context || null,
        // Reconciled with what a request would actually do. Reporting "loaded"
        // while /v1/messages answers "no nodes connected" is two views of one
        // fleet disagreeing, and it is exactly what makes a listing-based
        // health check untrustworthy.
        state: !m.live ? 'busy' : m.resident ? 'loaded' : 'not-loaded',
        // Same note as the OpenAI surface. A tool written against LM Studio
        // will ignore it; a person reading the JSON will not, and this is the
        // one thing about a split model that its name never says.
        dai: shapeNote(m.machines),
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

/**
 * How wide a model is, said in the catalogue rather than left to the name.
 *
 * `mlx-community/Qwen2.5-14B-Instruct-4bit` looks like every other model and is
 * not: serving it engages two machines at once, needs a cluster group set up for
 * it, and takes those machines out of harvesting while it stands. None of that
 * is visible in a repository path, and a caller choosing between models on a
 * list has no way to tell them apart.
 *
 * Both a number and a sentence. The number is for anything deciding; the
 * sentence is for the console and for a person reading a response by hand.
 */
export function shapeNote(machines: number): {
  machines: number; split: boolean; shape: string
} {
  const n = Math.max(1, Math.trunc(machines || 1))
  return {
    machines: n,
    split: n > 1,
    shape: n > 1 ? `runs across ${n} machines` : 'runs on one machine',
  }
}
