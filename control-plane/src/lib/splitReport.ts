/**
 * Evidence that a completion was served by more than one machine.
 *
 * The control plane knew this all along and threw it away. It assembles a gang,
 * assigns ranks, picks rank 0 to answer, and then reported the same `dai` block
 * a single-machine completion returns: one hostname, one presence state, one
 * duration. A split answer and an ordinary one were indistinguishable to the
 * caller, which meant the only way to confirm a split had run was to ssh to each
 * machine and read the agent log - the same "compare it over ssh and guess"
 * problem that AgentVersion exists to solve, one layer up.
 *
 * The distinction this draws matters more than the fields.
 *
 * **The catalogue is a claim.** `dai.split` on /v1/models says what an operator
 * declared, and a declaration can be wrong: this fleet ran for a day with a
 * group declaring it served a 14B while its machines held a 32B and a 30B.
 *
 * **This is evidence.** It names the machines the request was actually
 * dispatched to, and - when the head reports them - the layer range each one
 * held. A machine cannot be in this list without having been sent the work.
 */

/** A member of the gang, as the router assembled it. */
export interface GangMember {
  nodeId: string
  hostname: string
  rank: number
  address: string | null
}

export interface RankReport {
  hostname: string
  rank: number
  /**
   * What this rank is for, spelled out rather than left to be inferred from the
   * number. Rank 0 holds the last layers and the output head and is the only one
   * that can answer; the rest compute earlier layers and hand a hidden state on.
   * Ranks are numbered in reverse, which is the sort of thing that has to be
   * said rather than deduced.
   */
  role: 'output head' | 'feeds the next rank'
  /** `[start, end)` of the layers this machine held, when the head said. */
  layers?: [number, number]
}

export interface SplitReport {
  machines: number
  ranks: RankReport[]
  /**
   * Whether the layer ranges are present.
   *
   * Stated rather than left to be inferred from a missing field, because the
   * two reasons differ and only one is a problem: an agent older than the
   * release that started reporting them cannot say, which is worth knowing when
   * the question being asked is "is this really split".
   */
  layersReported: boolean
}

/**
 * The layer plan as the head reports it: one `[start, end)` pair per rank.
 *
 * Only the head sends it, and it sends the whole plan rather than its own share.
 * Every rank knows its own range, but they report independently and the response
 * is assembled the moment the head answers - so collecting ranges from the
 * others would be a race against a reply that has already been sent. The head
 * knows the total layer count and the gang size, so it can derive all of them
 * with the same accumulator every rank used, and one report carries the lot.
 */
export function parseLayerPlan(raw: unknown, size: number): [number, number][] | null {
  if (!Array.isArray(raw) || raw.length !== size) return null
  const out: [number, number][] = []
  for (const entry of raw) {
    if (!Array.isArray(entry) || entry.length !== 2) return null
    const [start, end] = entry
    if (typeof start !== 'number' || typeof end !== 'number') return null
    if (!Number.isInteger(start) || !Number.isInteger(end)) return null
    // A rank that owns nothing is not a rank, and a reversed range is a bug
    // somewhere upstream worth refusing rather than displaying.
    if (start < 0 || end <= start) return null
    out.push([start, end])
  }
  return out
}

/**
 * Build the block, or nothing at all for a single-machine completion.
 *
 * Absent rather than `split: false` on the ordinary path. Every completion this
 * fleet serves that is not split would otherwise carry a field saying so, and a
 * caller checking `if (dai.split)` reads both the same way.
 */
export function splitReport(
  members: GangMember[] | null | undefined,
  reportedPlan: unknown,
): SplitReport | undefined {
  if (!members || members.length <= 1) return undefined

  const ordered = [...members].sort((a, b) => a.rank - b.rank)
  const layers = parseLayerPlan(reportedPlan, ordered.length)

  return {
    machines: ordered.length,
    layersReported: layers !== null,
    ranks: ordered.map((m) => ({
      hostname: m.hostname,
      rank: m.rank,
      role: m.rank === 0 ? 'output head' : 'feeds the next rank',
      ...(layers ? { layers: layers[m.rank]! } : {}),
    })),
  }
}

/**
 * One line an operator can read, for a log or a terminal.
 *
 * The layer ranges are the part that proves division actually happened: two
 * hostnames prove only that two machines were sent the work, where
 * `0..<24` beside `24..<48` proves neither of them held the whole model.
 */
export function describeSplit(report: SplitReport): string {
  const parts = report.ranks.map((r) => {
    const where = r.layers ? ` layers ${r.layers[0]}..<${r.layers[1]}` : ''
    return `${r.hostname} (rank ${r.rank}${where}${r.rank === 0 ? ', head' : ''})`
  })
  const caveat = report.layersReported
    ? ''
    : ' - layer ranges not reported by this agent version'
  return `${report.machines} machines: ${parts.join(', ')}${caveat}`
}
