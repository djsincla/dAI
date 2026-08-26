import type { Server } from 'node:http'
import { afterAll, afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Db } from '../src/lib/db.js'
import { broker } from '../src/server.js'
import { selectNode, isRefusal, type Candidate } from '../src/lib/router.js'
import { type Fixtures, appFor, freshDb, seed, setPresence } from './helpers.js'

const asNode = (fp: string) => ({ 'x-node-fingerprint': fp, 'content-type': 'application/json' })
const asUser = (id: string) => ({ authorization: `Bearer ${id}`, 'content-type': 'application/json' })

function candidate(over: Partial<Candidate> = {}): Candidate {
  return {
    id: 'n1', hostname: 'a', presence_state: 'LOCKED',
    resident_models: {}, capability_profiles: {}, in_flight: 0, ...over,
  }
}

describe('routing', () => {
  it('refuses when every machine has a user present', () => {
    const out = selectNode(
      [candidate({ presence_state: 'ACTIVE' }), candidate({ id: 'n2', presence_state: 'IDLE' })],
      'generate', null)
    expect(isRefusal(out)).toBe(true)
    // The expected daytime answer, not an error. A caller is better served by
    // hearing it than by a request that hangs.
    expect((out as any).refused).toBe('all-in-use')
    expect((out as any).detail).toMatch(/locked or logged out/)
  })

  it('still serves ANE work while a user is present', () => {
    const out = selectNode([candidate({ presence_state: 'ACTIVE' })], 'embed', null)
    expect(isRefusal(out)).toBe(false)
  })

  it('fails closed when presence is unknown', () => {
    const out = selectNode([candidate({ presence_state: null })], 'generate', null)
    expect(isRefusal(out)).toBe(true)
  })

  it('prefers a node that already holds the model', () => {
    // Loading costs 1-3s (E4). Putting that on the request path is the
    // difference between a service and a curiosity, so residency outranks a
    // faster but empty node.
    const out = selectNode([
      candidate({ id: 'fast-empty', capability_profiles: { m1: 90 } }),
      candidate({ id: 'slow-resident', resident_models: { m1: 4 }, capability_profiles: { m1: 10 } }),
    ], 'generate', 'm1')
    expect((out as Candidate).id).toBe('slow-resident')
  })

  it('falls back to a node without the model rather than refusing', () => {
    const out = selectNode([candidate({ id: 'empty' })], 'generate', 'm1')
    expect((out as Candidate).id).toBe('empty')
  })

  it('breaks ties by measured throughput for the workload class', () => {
    const out = selectNode([
      candidate({ id: 'slow', resident_models: { m1: 4 }, capability_profiles: { m1: 12 } }),
      candidate({ id: 'fast', resident_models: { m1: 4 }, capability_profiles: { m1: 40 } }),
    ], 'generate', 'm1')
    expect((out as Candidate).id).toBe('fast')
  })

  it('prefers the least loaded node over the fastest', () => {
    // A faster node already handling three requests is worse than an idle one.
    const out = selectNode([
      candidate({ id: 'busy', capability_profiles: { m1: 90 }, in_flight: 3 }),
      candidate({ id: 'idle', capability_profiles: { m1: 20 }, in_flight: 0 }),
    ], 'generate', 'm1')
    expect((out as Candidate).id).toBe('idle')
  })

  it('says so when there are no nodes at all', () => {
    const out = selectNode([], 'generate', null)
    expect((out as any).refused).toBe('no-nodes')
  })
})

describe('serving over HTTP', () => {
  let db: Db
  let fx: Fixtures
  let server: Server
  let base: string

  beforeEach(async () => {
    db = await freshDb()
    fx = await seed(db)
    await db.query(`UPDATE nodes SET last_heartbeat = now() WHERE id = $1`, [fx.nodeId])
    const app = appFor(db)
    server = await new Promise<Server>((r) => { const s = app.listen(0, () => r(s)) })
    base = `http://127.0.0.1:${(server.address() as any).port}`
  })
  /**
   * Nodes parked on the reverse channel, so they can be taken off it.
   *
   * Nothing used to stop them. A long-poll was left in flight when the server
   * closed, undici reported the reset as an unhandled error, and vitest exited
   * non-zero while every test passed - which is invisible until something reads
   * the exit code, and the thing that reads it is the release script.
   */
  const attached: { stop: () => void; loop: Promise<void> }[] = []

  afterEach(async () => {
    // Detached before the server goes, not after.
    for (const n of attached) n.stop()
    await Promise.all(attached.map((n) => n.loop))
    attached.length = 0
    broker.reset()
    await new Promise<void>((r) => server.close(() => r()))
  })
  afterAll(async () => { await db?.end() })

  /** Park a node on the reverse channel and answer whatever arrives. */
  function attachNode(reply: (body: any) => any) {
    let stop = false
    // The in-flight long poll has to be cancellable, or stopping the loop only
    // stops the next request and the current one is still there when the server
    // closes underneath it.
    const inFlight = new AbortController()
    const loop = (async () => {
      while (!stop) {
        let r: Response
        try {
          r = await fetch(`${base}/agent/v1/dispatch`,
            { headers: asNode(fx.fingerprint), signal: inFlight.signal })
        } catch {
          return  // aborted, which is how this loop is meant to end
        }
        // Every body is read or cancelled. An unread one keeps the connection
        // holding data that is reset when the server goes.
        if (r.status !== 200) { await r.body?.cancel(); continue }
        const d = await r.json()
        const posted = await fetch(`${base}/agent/v1/dispatch/${d.dispatchId}/result`, {
          method: 'POST', headers: asNode(fx.fingerprint),
          body: JSON.stringify({ result: reply(d.body) }),
        })
        await posted.body?.cancel()
      }
    })()
    const handle = { stop: () => { stop = true; inFlight.abort() }, loop }
    attached.push(handle)
    return handle
  }

  it('refuses with 503 when no node is connected', async () => {
    const r = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }] }),
    })
    expect(r.status).toBe(503)
    expect((await r.json()).error.type).toBe('no_capacity')
  })

  it('routes a completion to a connected node and returns it', async () => {
    const node = attachNode((body) => ({
      text: `echo: ${(body.messages[0] as any).content}`,
      promptTokens: 5, completionTokens: 4,
    }))
    await new Promise((r) => setTimeout(r, 150))

    const r = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ messages: [{ role: 'user', content: 'hello' }], max_tokens: 32 }),
    })
    expect(r.status).toBe(200)
    const body = await r.json()
    expect(body.choices[0].message.content).toBe('echo: hello')
    expect(body.usage.total_tokens).toBe(9)
    expect(body.dai.node).toBe('rotorua')
    node.stop()
  })

  it('says in the catalogue how many machines a model needs', async () => {
    // The one thing a model's name never says. A caller choosing from this list
    // has no other way to tell that asking for one of them engages two machines.
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines)
       VALUES ('org/wide','mlx','generate',1000,2) ON CONFLICT DO NOTHING`)
    await db.query(
      `UPDATE nodes SET resident_models = '{"org/wide": 4, "org/narrow": 2}'::jsonb,
                        last_heartbeat = now() WHERE id = $1`, [fx.nodeId])

    const listed = await (await fetch(`${base}/v1/models`,
                                      { headers: asUser(fx.operatorToken) })).json() as any
    const wide = listed.data.find((m: any) => m.id === 'org/wide')
    const narrow = listed.data.find((m: any) => m.id === 'org/narrow')

    expect(wide.dai).toEqual({ machines: 2, split: true, shape: 'runs across 2 machines' })
    // And a model nobody has declared a shape for is one machine, not unknown.
    expect(narrow.dai).toEqual({ machines: 1, split: false, shape: 'runs on one machine' })
  })

  it('refuses a split model no operator has assigned, rather than assembling one', async () => {
    // The decision to run a split belongs to the operator. It takes those
    // machines out of harvesting for as long as it stands, which is why
    // assigning one already has to be confirmed - so a caller naming a model
    // that happens to need two machines must not be able to set that up by
    // asking for it.
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines)
       VALUES ('org/wide','mlx','generate',1000,2) ON CONFLICT DO NOTHING`)
    await db.query(
      `UPDATE nodes SET tiers = ARRAY['harvest','cluster']::text[] WHERE id = $1`, [fx.nodeId])
    const node = attachNode(() => ({ text: 'x', promptTokens: 1, completionTokens: 1 }))
    await new Promise((r) => setTimeout(r, 150))

    const r = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ model: 'org/wide',
                             messages: [{ role: 'user', content: 'hello' }], max_tokens: 8 }),
    })
    const body = await r.json() as any
    node.stop()

    expect(r.status).toBe(503)
    expect(body.error.code).toBe('not-offered')
    // The reason names the decision that is missing, not a machine that is.
    expect(body.error.message).toContain('no cluster group is serving it')
    expect(body.error.message).toContain('out of harvesting')
  })

  /**
   * A group that names no model serves whichever one it was staged with.
   *
   * The operator still decides - `pool_models` is written by an admin route and
   * pushing weights is the same act of spending the fleet - but the choice among
   * what was staged is left to the caller. The refusal below is the assertion
   * that matters: without the staging condition a dynamic group would accept any
   * model in the catalogue and fail at dispatch, with the machines discovering
   * the weights were never there.
   */
  const dynamicGroupHolding = async (modelId: string | null) => {
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines)
       VALUES ('org/wide','mlx','generate',1000,2) ON CONFLICT DO NOTHING`)
    const { rows } = await db.query(
      `INSERT INTO pools (name, tier, schedule, preempt, serving_model_id, enabled)
       VALUES ('pool','cluster','gang','never', NULL, true) RETURNING id`)
    const poolId = (rows[0] as { id: string }).id
    if (modelId) {
      await db.query(
        `INSERT INTO models (id, runtime, kind, size_bytes, machines)
         VALUES ($1,'mlx','generate',1000,2) ON CONFLICT DO NOTHING`, [modelId])
      await db.query(
        `INSERT INTO pool_models (pool_id, model_id) VALUES ($1,$2)
         ON CONFLICT DO NOTHING`, [poolId, modelId])
    }
    await db.query(
      `UPDATE nodes SET tiers = ARRAY['harvest','cluster']::text[] WHERE id = $1`,
      [fx.nodeId])
    return poolId
  }

  const askFor = async (model: string) => {
    const node = attachNode(() => ({ text: 'x', promptTokens: 1, completionTokens: 1 }))
    await new Promise((r) => setTimeout(r, 150))
    const r = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ model,
                             messages: [{ role: 'user', content: 'hello' }], max_tokens: 8 }),
    })
    const body = await r.json() as any
    node.stop()
    return body
  }

  it('refuses a model an unpinned group was never staged', async () => {
    // Staged, not merely cluster-tier. A dynamic group offers what an operator
    // pushed to its machines and nothing else, or the caller is back to setting
    // up a split by asking for one.
    await dynamicGroupHolding(null)
    const body = await askFor('org/wide')
    expect(body.error.code).toBe('not-offered')
    expect(body.error.message).toContain('has been staged')
  })

  it('accepts a model an unpinned group was staged, and stops refusing it', async () => {
    // The group matched, so whatever happens next is about machines rather than
    // about the model not being offered anywhere. Before this, a group with no
    // serving model matched nothing and every request for a staged split was
    // turned away with "no cluster group is serving it".
    await dynamicGroupHolding('org/wide')
    const body = await askFor('org/wide')
    expect(body.error?.message ?? '').not.toContain('no cluster group is serving it')
  })

  it('says which machine answered on the Anthropic surface too', async () => {
    // The provenance block was on /v1/chat/completions and not here, so a
    // caller using the Anthropic shape could not tell which machine had served
    // them. That matters most where the control plane and the node are the same
    // box: an answer routed to the local node and an answer that never left the
    // process look the same from outside, and only the router can fill this in.
    // The model has to be resident before it can be asked for: unlike
    // /v1/chat/completions, this surface requires a model and looks it up in
    // the catalogue, which is built from what nodes report holding.
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', residentModels: { 'qwen-7b': 4.0 } }),
    })
    const node = attachNode(() => ({
      text: 'ready', promptTokens: 3, completionTokens: 1,
    }))
    await new Promise((r) => setTimeout(r, 150))

    const r = await fetch(`${base}/v1/messages`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({
        model: 'qwen-7b', messages: [{ role: 'user', content: 'hi' }], max_tokens: 32,
      }),
    })
    const body = await r.json()
    expect(r.status).toBe(200)
    expect(body.dai.node).toBe('rotorua')
    expect(body.dai).toHaveProperty('presenceState')
    expect(body.dai).toHaveProperty('cappedByPolicy')
    node.stop()
  })

  it('will not serve a split model from a single machine', async () => {
    // The silent failure this guard exists for. Without it selectNode picks one
    // node for a model declared to need two, and the node loads a model built
    // from a reduced layer count - which answers rather than failing, from half
    // a network, confidently.
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines)
       VALUES ('org/split','mlx','generate',$1,2)
       ON CONFLICT (id) DO UPDATE SET machines = 2`, [Math.round(40 * 1073741824)])
    const node = attachNode(() => ({ text: 'x', promptTokens: 1, completionTokens: 1 }))
    await new Promise((r) => setTimeout(r, 150))

    const r = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({
        model: 'org/split', messages: [{ role: 'user', content: 'hi' }], max_tokens: 8,
      }),
    })
    expect(r.status).toBe(503)
    const body = await r.json()
    // One connected machine cannot be a gang of two, and the reason says so
    // rather than reporting a busy fleet.
    expect(body.error.message).toMatch(/2 machines|never preempted/)
    node.stop()
  })

  it('still serves an ordinary model from one machine', async () => {
    // The guard has to be invisible to everything that fits, which is nearly
    // everything.
    await db.query(
      `INSERT INTO models (id, runtime, kind, size_bytes, machines)
       VALUES ('org/whole','mlx','generate',$1,1)
       ON CONFLICT (id) DO UPDATE SET machines = 1`, [Math.round(4 * 1073741824)])
    const node = attachNode(() => ({ text: 'ok', promptTokens: 1, completionTokens: 1 }))
    await new Promise((r) => setTimeout(r, 150))

    const r = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({
        model: 'org/whole', messages: [{ role: 'user', content: 'hi' }], max_tokens: 8,
      }),
    })
    expect(r.status).toBe(200)
    node.stop()
  })

  it('is silent about a model the catalogue has never heard of', async () => {
    // Shape is only knowable for a model in the catalogue. An unknown name
    // falls through to ordinary routing rather than being refused by a check
    // that had nothing to check.
    const node = attachNode(() => ({ text: 'ok', promptTokens: 1, completionTokens: 1 }))
    await new Promise((r) => setTimeout(r, 150))
    const r = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }], max_tokens: 8 }),
    })
    expect(r.status).toBe(200)
    node.stop()
  })

  it('refuses while the machine is in use, even with the node connected', async () => {
    await setPresence(db, fx.nodeId, 'ACTIVE')
    const node = attachNode(() => ({ text: 'x', promptTokens: 1, completionTokens: 1 }))
    await new Promise((r) => setTimeout(r, 150))

    const r = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }] }),
    })
    // The whole point: a listening, healthy, capable node is still not
    // available because someone is sitting at it.
    expect(r.status).toBe(503)
    expect((await r.json()).error.code).toBe('all-in-use')
    node.stop()
  })

  it('caps max_tokens to the answering state policy and says it did', async () => {
    const node = attachNode((body) => ({
      text: 'ok', promptTokens: 1, completionTokens: body.max_tokens,
    }))
    await new Promise((r) => setTimeout(r, 150))

    const r = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }], max_tokens: 99999 }),
    })
    const body = await r.json()
    // LOCKED allows 2048. Bounding the completion bounds how long a returning
    // user waits, since one request has no seam to yield at.
    expect(body.dai.maxTokensApplied).toBe(2048)
    expect(body.dai.cappedByPolicy).toBe(true)
    node.stop()
  })

  it('rejects streaming rather than pretending to support it', async () => {
    const r = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST', headers: asUser(fx.operatorToken),
      body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }], stream: true }),
    })
    expect(r.status).toBe(400)
    await r.body?.cancel()
  })

  it('records where a peer should dial this machine', async () => {
    // Declared by the node, not observed. A split runs over whatever link the
    // machines share, and E7's ran over a Thunderbolt bridge while both nodes
    // reached the control plane over the ordinary LAN. Using the source address
    // of a heartbeat would send a dialer down the slow path.
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', pipelineAddress: '192.168.99.1' }),
    })
    const seen = await db.query(`SELECT pipeline_address FROM nodes WHERE id=$1`, [fx.nodeId])
    expect(seen.rows[0].pipeline_address).toBe('192.168.99.1')
  })

  it('keeps the address when a beat does not mention it', async () => {
    // An agent that predates the field must not appear to have lost its address
    // by staying alive.
    await db.query(
      `UPDATE nodes SET pipeline_address = '192.168.99.2' WHERE id=$1`, [fx.nodeId])
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED' }),
    })
    const kept = await db.query(`SELECT pipeline_address FROM nodes WHERE id=$1`, [fx.nodeId])
    expect(kept.rows[0].pipeline_address).toBe('192.168.99.2')
  })

  it('forgets the address when the node says the link has gone', async () => {
    // The distinction that matters is between an agent that never mentions the
    // field and one that says it has no address. Keeping the last one heard
    // leaves the fleet forming a gang over a cable that is not there: the
    // Thunderbolt bridge here went inactive, both machines went on being
    // recorded at the addresses it used to have, and a split dialled silence
    // and waited two minutes to say so.
    await db.query(
      `UPDATE nodes SET pipeline_address = '192.168.99.2' WHERE id=$1`, [fx.nodeId])
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', pipelineAddress: null }),
    })
    const gone = await db.query(`SELECT pipeline_address FROM nodes WHERE id=$1`, [fx.nodeId])
    expect(gone.rows[0].pipeline_address).toBe(null)
  })

  it('records why a node is not holding what it was assigned', async () => {
    // A transfer that fails is written to the node's own log and nowhere else,
    // so a machine that has silently stopped fetching looks exactly like one
    // that is up to date. On this fleet a node spent twelve hours failing on
    // "could not ask what to hold" with nothing visible anywhere but ssh.
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({
        presenceState: 'LOCKED',
        syncFaults: { 'org/model': 'HTTP 404 downloading org/model/config.json' },
      }),
    })
    const seen = await db.query(
      `SELECT model_sync_faults, last_model_sync FROM nodes WHERE id=$1`, [fx.nodeId])
    expect(seen.rows[0].model_sync_faults).toEqual({
      'org/model': 'HTTP 404 downloading org/model/config.json',
    })
    expect(seen.rows[0].last_model_sync).not.toBeNull()
  })

  it('leaves recorded faults alone when a beat does not mention them', async () => {
    // Absent means "no pass has finished", not "all well". An agent that
    // predates the field, or simply has not run a pass since, must not appear
    // to have cleared a fault just by staying alive.
    await db.query(
      `UPDATE nodes SET model_sync_faults = '{"org/model":"disk full"}'::jsonb WHERE id=$1`,
      [fx.nodeId])
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED' }),
    })
    const kept = await db.query(`SELECT model_sync_faults FROM nodes WHERE id=$1`, [fx.nodeId])
    expect(kept.rows[0].model_sync_faults).toEqual({ 'org/model': 'disk full' })

    // An empty object is a positive report and does clear them.
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', syncFaults: {} }),
    })
    const cleared = await db.query(`SELECT model_sync_faults FROM nodes WHERE id=$1`, [fx.nodeId])
    expect(cleared.rows[0].model_sync_faults).toEqual({})
  })

  it('records resident models from the heartbeat, replacing rather than merging', async () => {
    const send = (models: Record<string, number>) =>
      fetch(`${base}/agent/v1/heartbeat`, {
        method: 'POST', headers: asNode(fx.fingerprint),
        body: JSON.stringify({ presenceState: 'LOCKED', residentModels: models }),
      })
    await send({ 'qwen-7b': 4.0, 'qwen-0.5b': 0.3 })
    await send({ 'qwen-7b': 4.0 })
    const { rows } = await db.query(`SELECT resident_models FROM nodes WHERE id=$1`, [fx.nodeId])
    // A released model must disappear, or routing sends work to a node that has
    // to reload it, which is exactly what residency exists to avoid.
    expect(rows[0].resident_models).toEqual({ 'qwen-7b': 4.0 })
  })

  it('discards a late answer whose dispatch already timed out', async () => {
    const r = await fetch(`${base}/agent/v1/dispatch/${crypto.randomUUID()}/result`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ result: { text: 'stale', promptTokens: 1, completionTokens: 1 } }),
    })
    expect(r.status).toBe(409)
    expect((await r.json()).accepted).toBe(false)
  })

  it('does not list a model whose node has stopped reporting', async () => {
    // Previously this listed anything any node had ever mentioned, so a model
    // showed as available long after its node was gone. A capability check is
    // exactly where that misleads: a client asks what it can use, is told, and
    // every request then fails.
    //
    // Keyed on the heartbeat rather than on whether the node is parked on the
    // channel, because those are different facts: a node reading a large prompt
    // is unavailable for minutes while being entirely healthy, and dropping its
    // model from the catalogue makes an active request look impossible.
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', residentModels: { 'qwen-7b': 4 } }),
    })
    await db.query(
      `UPDATE nodes SET last_heartbeat = now() - interval '10 minutes' WHERE id = $1`,
      [fx.nodeId])

    const r = await fetch(`${base}/v1/models`, { headers: asUser(fx.operatorToken) })
    expect((await r.json()).data.map((m: any) => m.id)).not.toContain('qwen-7b')
  })

  it('keeps listing a model while its node is mid-request', async () => {
    // The node is not parked on the channel while it answers, and a long prompt
    // occupies it for minutes. The model is still there.
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', residentModels: { 'qwen-7b': 4 } }),
    })
    const r = await fetch(`${base}/v1/models`, { headers: asUser(fx.operatorToken) })
    expect((await r.json()).data.map((m: any) => m.id)).toContain('qwen-7b')
  })

  it('lists a model with its measured window once the node reports one', async () => {
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({
        presenceState: 'LOCKED',
        residentModels: { 'qwen-7b': 4 },
        models: [{ name: 'qwen-7b', contextLength: 32768 }],
      }),
    })

    // Park on the reverse channel, which is what makes a node routable.
    let stop = false
    const held = (async () => {
      while (!stop) {
        const r = await fetch(`${base}/agent/v1/dispatch`, { headers: asNode(fx.fingerprint) })
        if (r.status === 200) await r.json()
      }
    })()
    await new Promise((r) => setTimeout(r, 250))

    const r = await fetch(`${base}/v1/models`, { headers: asUser(fx.operatorToken) })
    const models = (await r.json()).data as any[]
    expect(models.map((m) => m.id)).toContain('qwen-7b')
    // The window is advertised so a client does not have to assume one.
    expect(models.find((m) => m.id === 'qwen-7b').context_length).toBe(32768)

    stop = true
    await Promise.race([held, new Promise((r) => setTimeout(r, 1500))])
  })

  /**
   * A model nothing can reach should not be advertised as though it could be.
   *
   * `POST /v1/embeddings` returns 404, for the reasons in docs/EMBEDDINGS.md,
   * while an embedding model is staged and resident like any other and so
   * appeared in both catalogues. A caller cannot tell an advertised model from
   * a servable one and picks by name, so the listing invited exactly the
   * request that cannot be answered.
   *
   * Delete these when /v1/embeddings lands; they assert an absence that is only
   * correct while the endpoint does not exist.
   */
  const residentBoth = () =>
    fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({
        presenceState: 'LOCKED',
        residentModels: { 'org/chat': 4, 'org/embed': 1 },
      }),
    })

  const stageKinds = () => db.query(
    `INSERT INTO models (id, runtime, kind, size_bytes)
     VALUES ('org/chat','mlx','generate',1), ('org/embed','coreml','embed',1)
     ON CONFLICT DO NOTHING`)

  it('does not advertise an embedding model while nothing serves one', async () => {
    await stageKinds()
    await residentBoth()

    const r = await fetch(`${base}/v1/models`, { headers: asUser(fx.operatorToken) })
    const ids = (await r.json()).data.map((m: any) => m.id)
    expect(ids).toContain('org/chat')
    expect(ids).not.toContain('org/embed')
  })

  it('hides it from the LM Studio surface too, and types the rest honestly', async () => {
    await stageKinds()
    await residentBoth()

    const r = await fetch(`${base}/api/v0/models`, { headers: asUser(fx.operatorToken) })
    const models = (await r.json()).data as any[]
    expect(models.map((m) => m.id)).not.toContain('org/embed')

    // No node has reported a context window here. This field read
    // `context > 0 ? 'llm' : 'embeddings'`, so a usable chat model was
    // announced as something a client cannot send a conversation to whenever
    // the window had not arrived yet.
    const chat = models.find((m) => m.id === 'org/chat')
    expect(chat).toBeDefined()
    expect(chat.type).toBe('llm')
  })

  it('still lists a model the repository has never heard of', async () => {
    // The filter is keyed on models.kind, and a node can hold weights that were
    // never imported. Those are unknown, not unreachable, and dropping them
    // would empty the catalogue on any fleet that stages outside the
    // repository.
    await fetch(`${base}/agent/v1/heartbeat`, {
      method: 'POST', headers: asNode(fx.fingerprint),
      body: JSON.stringify({ presenceState: 'LOCKED', residentModels: { 'org/unknown': 4 } }),
    })
    const r = await fetch(`${base}/v1/models`, { headers: asUser(fx.operatorToken) })
    expect((await r.json()).data.map((m: any) => m.id)).toContain('org/unknown')
  })
})
