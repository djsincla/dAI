import { randomUUID } from 'node:crypto'

/**
 * Reverse-channel dispatch for interactive requests.
 *
 * E3 chose pull dispatch because harvested machines come and go, and a
 * scheduler that must reach *into* them needs credentials and reachability it
 * will not reliably have. That reasoning is still right, and a naive push model
 * would break it.
 *
 * So the node dials out and holds a connection open, and the control plane
 * pushes down it. Outbound from the node, so no inbound firewall rules, no
 * per-node addressing and no NAT traversal. Push from the scheduler, so routing
 * takes milliseconds rather than a poll interval.
 *
 * Batch dispatch stays pull. It is self-balancing and has no latency
 * requirement, and two mechanisms for two jobs is simpler than one mechanism
 * bent to serve both.
 *
 * State is in-process. A second control plane instance would need this in
 * Postgres with LISTEN/NOTIFY, or a shared queue. Worth knowing before scaling
 * out rather than after.
 */

export interface Dispatch {
  id: string
  kind: string
  modelHash: string | null
  body: unknown
  createdAt: number
}

interface Waiter {
  resolve: (d: Dispatch | null) => void
  timer: NodeJS.Timeout
}

interface Pending {
  dispatch: Dispatch
  nodeId: string
  resolve: (result: { ok: true; body: unknown } | { ok: false; error: string }) => void
  timer: NodeJS.Timeout
}

export class Broker {
  /** Nodes currently holding a long-poll open, by node id. */
  private waiters = new Map<string, Waiter>()
  /** Dispatches handed to a node and awaiting a result, by dispatch id. */
  private pending = new Map<string, Pending>()
  /** Requests in flight per node, which the router uses to break ties. */
  private inFlight = new Map<string, number>()

  constructor(
    private readonly pollTimeoutMs = 25_000,
    // Long enough for a large model to read a large prompt. A 32B reads at
    // roughly 64 tokens a second here, so a 32k window is minutes of prompt
    // processing before a single token is generated. Configurable because that
    // figure is a property of the hardware, not of this code.
    private readonly requestTimeoutMs =
      Number(process.env.DAI_REQUEST_TIMEOUT_MS ?? 600_000),
  ) {}

  get inFlightCounts(): Map<string, number> {
    return this.inFlight
  }

  /** Is this node currently listening? Only such nodes can be routed to. */
  isConnected(nodeId: string): boolean {
    return this.waiters.has(nodeId)
  }

  connectedNodes(): string[] {
    return [...this.waiters.keys()]
  }

  /**
   * A node parks here until work arrives or the poll times out.
   *
   * Returning null on timeout rather than holding forever keeps the connection
   * observably alive: a node that has heard nothing for 25s reconnects, and a
   * control plane restart does not leave nodes waiting on a socket nobody is
   * listening to.
   */
  waitForWork(nodeId: string): Promise<Dispatch | null> {
    this.release(nodeId)
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.waiters.delete(nodeId)
        resolve(null)
      }, this.pollTimeoutMs)
      this.waiters.set(nodeId, { resolve, timer })
    })
  }

  private release(nodeId: string): void {
    const existing = this.waiters.get(nodeId)
    if (existing) {
      clearTimeout(existing.timer)
      this.waiters.delete(nodeId)
      // A node that reconnects while an older poll is open gets that poll
      // closed rather than left dangling.
      existing.resolve(null)
    }
  }

  /**
   * Hand a request to a node and wait for its answer.
   *
   * Rejects rather than hangs if the node never answers: a node that vanishes
   * mid-request is the expected case on a harvested fleet, not an exception.
   */
  /**
   * Dispatches still running that nobody is waiting for any more.
   *
   * A node is a serial resource: one request occupies it entirely, and a
   * cancelled one measured at 330 seconds of work for an answer nobody would
   * read. With a single node that is the whole cluster blocked, and people
   * cancel constantly.
   */
  private readonly cancelled = new Set<string>()

  isCancelled(dispatchId: string): boolean {
    return this.cancelled.has(dispatchId)
  }

  dispatch(
    nodeId: string,
    kind: string,
    modelHash: string | null,
    body: unknown,
    signal?: AbortSignal,
  ): Promise<{ ok: true; body: unknown } | { ok: false; error: string }> {
    const waiter = this.waiters.get(nodeId)
    if (!waiter) return Promise.resolve({ ok: false as const, error: 'node not connected' })

    const dispatch: Dispatch = { id: randomUUID(), kind, modelHash, body, createdAt: Date.now() }
    clearTimeout(waiter.timer)
    this.waiters.delete(nodeId)
    this.inFlight.set(nodeId, (this.inFlight.get(nodeId) ?? 0) + 1)

    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.finish(dispatch.id)
        resolve({ ok: false, error: 'node did not answer in time' })
      }, this.requestTimeoutMs)
      this.pending.set(dispatch.id, { dispatch, nodeId, resolve, timer })

      // The caller going away is recorded rather than acted on directly: the
      // node is mid-generation and there is no open channel to push anything
      // down, so it asks. Marked before resolving, or a node polling in the
      // same tick is told to continue work already abandoned.
      signal?.addEventListener('abort', () => {
        console.log(`[serving] caller gave up on ${dispatch.id}; asking the node to stop`)
        this.cancelled.add(dispatch.id)
        this.finish(dispatch.id)
        resolve({ ok: false, error: 'cancelled by the caller' })
      }, { once: true })

      waiter.resolve(dispatch)
    })
  }

  /**
   * Dispatch to every rank of a gang, and hold them together.
   *
   * A split model runs across N machines in lockstep, so the ranks are started
   * at once and the request is finished by whichever of them holds the output
   * head. The others do their share and return nothing anybody reads.
   *
   * When any rank fails, the whole request fails. That is the decision taken
   * deliberately over holding the survivors or resuming elsewhere: resuming
   * needs the lost rank's KV cache, which is not transferable, and holding
   * costs memory on machines doing nothing while betting a peer returns. On a
   * tier defined as never-preempted this should not happen, and machinery for
   * recovering from it would be admitting the tier does not work.
   *
   * So it fails loudly. The reason names the rank that went, every member is
   * released rather than only the one that failed, and the failure is logged
   * against all of them - a gang that broke is not one slow request, and a
   * fleet that reports it as one will go on breaking quietly.
   */
  async dispatchGang(
    members: { nodeId: string; hostname: string; rank: number }[],
    kind: string,
    modelHash: string | null,
    body: (rank: number) => unknown,
    signal?: AbortSignal,
  ): Promise<{ ok: true; body: unknown } | { ok: false; error: string }> {
    // Every rank starts before any is awaited. Awaiting one at a time would
    // deadlock: rank 0 listens and does not finish until rank 1 has dialled it,
    // and rank 1 is not dispatched until rank 0 returns.
    const started = members.map((m) => ({
      member: m,
      result: this.dispatch(m.nodeId, kind, modelHash, body(m.rank), signal),
    }))

    const settled = await Promise.all(started.map(async (s) => ({
      member: s.member,
      outcome: await s.result,
    })))

    const failed = settled.filter((s) => !s.outcome.ok)
    if (failed.length > 0) {
      const why = failed
        .map((f) => `rank ${f.member.rank} (${f.member.hostname}): `
          + `${(f.outcome as { error: string }).error}`)
        .join('; ')
      console.log(`[serving] gang of ${members.length} broke and was released - ${why}`)
      return { ok: false, error: `the gang did not complete - ${why}` }
    }

    // Rank 0 holds the last layers and the output head, so it is the one with
    // an answer. The others report having done their share.
    const head = settled.find((s) => s.member.rank === 0) ?? settled[0]!
    return { ok: true, body: (head.outcome as { body: unknown }).body }
  }

  /** A node returns a completion, or reports that it could not produce one. */
  complete(dispatchId: string, nodeId: string, result: { body?: unknown; error?: string }): boolean {
    const entry = this.pending.get(dispatchId)
    // Checking the node id matters: a late answer from a node whose dispatch
    // already timed out must not resolve a request that has moved on.
    if (!entry || entry.nodeId !== nodeId) return false
    this.finish(dispatchId)
    entry.resolve(result.error ? { ok: false, error: result.error } : { ok: true, body: result.body })
    return true
  }

  /** Forget a cancellation once the node has acknowledged it. */
  clearCancelled(dispatchId: string): void {
    this.cancelled.delete(dispatchId)
  }

  private finish(dispatchId: string): void {
    const entry = this.pending.get(dispatchId)
    if (!entry) return
    clearTimeout(entry.timer)
    this.pending.delete(dispatchId)
    const n = (this.inFlight.get(entry.nodeId) ?? 1) - 1
    if (n <= 0) this.inFlight.delete(entry.nodeId)
    else this.inFlight.set(entry.nodeId, n)
  }

  /** Drop everything. Used between tests and on shutdown. */
  reset(): void {
    for (const [, w] of this.waiters) { clearTimeout(w.timer); w.resolve(null) }
    for (const [, p] of this.pending) {
      clearTimeout(p.timer)
      p.resolve({ ok: false, error: 'control plane shutting down' })
    }
    this.waiters.clear()
    this.pending.clear()
    this.inFlight.clear()
  }
}
