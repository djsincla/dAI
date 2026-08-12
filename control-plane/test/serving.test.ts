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
})
