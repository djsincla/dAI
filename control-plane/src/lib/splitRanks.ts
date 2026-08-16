/**
 * Who holds which layers, decided once.
 *
 * Rank 0 holds the last layers, the final norm and the output head, so it is the
 * only machine that can turn a hidden state into a token - and therefore the one
 * that answers the request and the one the others dial. Ranks are numbered in
 * reverse for that reason, which is the sort of thing that has to be said rather
 * than deduced.
 *
 * A machine with no address cannot be dialled, so it cannot be rank 0. If no
 * member has one there is no gang to form at all.
 *
 * Extracted because this rule was about to exist in three places: the router
 * assigning ranks at dispatch, the readiness view telling an operator what would
 * happen, and the heartbeat telling a machine what to build before anything is
 * asked of it. Three copies of one rule is how a disabled group came to be
 * counted by two call sites and not a third, found separately and fixed
 * separately. A readiness view that disagrees with the router is worse than
 * none, because it is believed.
 */

export interface RankCandidate {
  id: string
  hostname: string
  /** Where a peer should dial it, as the machine itself declared. */
  pipelineAddress: string | null
}

export interface Ranked<T extends RankCandidate> {
  member: T
  rank: number
  role: 'output head' | 'feeds the next rank'
}

/**
 * Order machines into ranks, or say that no ordering is possible.
 *
 * Null rather than an empty list when nobody can be dialled: those are different
 * answers. An empty list reads as "no machines", where the truth is machines
 * that cannot form a pipeline - and a caller that showed rank 0 anyway would be
 * naming a role nobody is holding.
 */
export function assignRanks<T extends RankCandidate>(members: T[]): Ranked<T>[] | null {
  if (members.length === 0) return null

  // Dialable first. Sorted rather than partitioned so the order is total and the
  // same inputs always produce the same ranks - a machine that changed rank
  // between two heartbeats would rebuild its share for no reason.
  const ordered = [...members].sort((a, b) => {
    const dialable = Number(!!b.pipelineAddress) - Number(!!a.pipelineAddress)
    return dialable !== 0 ? dialable : a.id.localeCompare(b.id)
  })
  if (!ordered[0]!.pipelineAddress) return null

  return ordered.map((member, rank) => ({
    member,
    rank,
    role: rank === 0 ? 'output head' : 'feeds the next rank',
  }))
}

/** What one machine was given, or null if it is not in the ordering. */
export function rankOf<T extends RankCandidate>(
  ranked: Ranked<T>[] | null, id: string,
): number | null {
  return ranked?.find((r) => r.member.id === id)?.rank ?? null
}
