/**
 * The socket a group answers on.
 *
 * Every group gets its own port, allocated when it is created and bound for as
 * long as it exists. That is how a caller says which machines it wants without
 * saying anything else: an application pointed at 8461 is asking the group that
 * owns 8461, and one pointed at 8462 is asking a different set of machines,
 * with no header, no path prefix and nothing to get wrong at the client.
 *
 * The alternative - one socket and a group named in the request - was rejected
 * for the reason that keeps coming up in this system: it makes the routing a
 * property of what somebody remembered to send rather than of where they sent
 * it. A port is a thing you can firewall, monitor, and hand to a team.
 */

export interface PortRange {
  from: number
  to: number
}

/**
 * Where group sockets are allocated from.
 *
 * Above the registered range and clear of the control plane's own listeners.
 * Forty of them, because a fleet with more than forty groups has a naming
 * problem rather than a port problem, and a range that is small enough to
 * enumerate is one an operator can actually check with lsof.
 */
export const DEFAULT_RANGE: PortRange = { from: 8460, to: 8499 }

/**
 * The range to allocate from, which a deployment may move.
 *
 * Read as `from-to`. A malformed value is refused rather than silently
 * defaulted: somebody who set it meant something by it, and quietly binding
 * forty sockets somewhere else is worse than not starting.
 */
export function rangeFrom(value: string | undefined): PortRange {
  if (!value || value.trim() === '') return DEFAULT_RANGE
  const match = /^\s*(\d+)\s*-\s*(\d+)\s*$/.exec(value)
  if (!match) {
    throw new Error(`DAI_GROUP_PORT_RANGE must look like 8460-8499, not "${value}"`)
  }
  const from = Number(match[1]), to = Number(match[2])
  if (from < 1 || to > 65535 || from > to) {
    throw new Error(`DAI_GROUP_PORT_RANGE ${from}-${to} is not a usable range`)
  }
  return { from, to }
}

/**
 * The lowest port in the range nobody holds, or null when they are all taken.
 *
 * Lowest rather than next-after-the-last, so a group that is deleted returns
 * its port to use. Null rather than an exception because running out is an
 * ordinary answer with an ordinary response - refuse to create the group and
 * say the range is full - and not a fault in the caller.
 */
export function nextFree(taken: Iterable<number>, range: PortRange = DEFAULT_RANGE):
  number | null {
  const used = new Set(taken)
  for (let port = range.from; port <= range.to; port++) {
    if (!used.has(port)) return port
  }
  return null
}

/** How many groups a range can hold, for a message that says what the limit is. */
export function capacity(range: PortRange): number {
  return range.to - range.from + 1
}
