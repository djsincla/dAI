import { BlockList, isIPv4, isIPv6 } from 'node:net'
import type { NextFunction, Request, Response } from 'express'
import type { Db } from './db.js'

/**
 * Network access control for the API surfaces.
 *
 * This is defence in depth, never authentication. It narrows who can reach the
 * endpoints; mTLS and sessions decide who is allowed to do anything. A CIDR
 * allowlist on its own would be trivially defeated by anyone on the same
 * network, so it must not be treated as a substitute for either.
 *
 * Two layers:
 *
 *   Per surface. Agents live on the fleet network; humans may not. The two get
 *   separate allowlists because they have genuinely different reach.
 *
 *   Per node. A certificate is pinned to the network it enrolled from, so a
 *   copied credential presented from somewhere else is refused even though the
 *   certificate itself is valid. This is the layer that catches a stolen
 *   laptop's key material being used elsewhere.
 */

export class Acl {
  private readonly list = new BlockList()
  readonly open: boolean

  constructor(spec: string | undefined | null) {
    const entries = (spec ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
    this.open = entries.length === 0
    for (const entry of entries) this.add(entry)
  }

  private add(entry: string): void {
    const [addr, prefix] = entry.split('/')
    if (!addr) throw new Error(`invalid CIDR or address: ${entry}`)
    const type = isIPv4(addr) ? 'ipv4' : isIPv6(addr) ? 'ipv6' : null
    if (!type) throw new Error(`invalid CIDR or address: ${entry}`)

    if (prefix === undefined) {
      this.list.addAddress(addr, type)
    } else {
      const bits = Number(prefix)
      if (!Number.isInteger(bits) || bits < 0 || bits > (type === 'ipv4' ? 32 : 128)) {
        throw new Error(`invalid prefix length in ${entry}`)
      }
      this.list.addSubnet(addr, bits, type)
    }
  }

  allows(ip: string | undefined): boolean {
    if (this.open) return true
    const addr = normalizeIp(ip)
    if (!addr) return false
    if (isIPv4(addr)) return this.list.check(addr, 'ipv4')
    if (isIPv6(addr)) return this.list.check(addr, 'ipv6')
    return false
  }
}

/**
 * Node reports IPv4 peers over a dual-stack socket as IPv4-mapped IPv6
 * (`::ffff:10.0.0.2`). Matching that against an IPv4 subnet fails unless it is
 * unwrapped first, which is a quiet way for an allowlist to reject everything.
 */
export function normalizeIp(ip: string | undefined | null): string | null {
  if (!ip) return null
  const lower = ip.toLowerCase()
  if (lower.startsWith('::ffff:')) {
    const tail = lower.slice(7)
    if (isIPv4(tail)) return tail
  }
  return ip
}

/**
 * The peer's real address.
 *
 * X-Forwarded-For is only consulted when Express has been told to trust a
 * proxy. Reading it unconditionally would let any caller declare their own
 * source address, which makes the allowlist worse than not having one.
 */
export function clientIp(req: Request): string | undefined {
  return normalizeIp(req.ip) ?? normalizeIp(req.socket.remoteAddress) ?? undefined
}

/**
 * An allowlist for a surface that carries no credential.
 *
 * `aclMiddleware` treats an unset list as "allow everything", which is the right
 * default for a surface that authenticates its callers by other means. It is the
 * wrong default here: an unauthenticated endpoint that is open when nobody
 * configured it publishes a fleet inventory to anyone who can route to it.
 *
 * So an empty list denies. Configuring nothing yields nothing rather than
 * everything.
 */
export function closedAclMiddleware(acl: Acl, surface: string) {
  return (req: Request, res: Response, next: NextFunction) => {
    if (acl.open) {
      res.status(404).type('text/plain')
        .send(`the ${surface} surface is disabled until an address range is configured\n`)
      return
    }
    if (!acl.allows(clientIp(req))) {
      res.status(403).type('text/plain').send('address not permitted\n')
      return
    }
    next()
  }
}

export function aclMiddleware(acl: Acl, surface: string) {
  return (req: Request, res: Response, next: NextFunction) => {
    if (acl.allows(clientIp(req))) {
      next()
      return
    }
    // Deliberately vague: an attacker probing from a blocked range learns only
    // that they were blocked, not which surface exists behind it.
    res.status(403).json({ error: 'forbidden', detail: `not permitted from this network` })
    void surface
  }
}

/**
 * Per-node pinning. Checked after the certificate has already identified the
 * node, so it answers "is this node calling from where it should be" rather
 * than "who is this".
 */
export async function nodeNetworkAllowed(
  db: Db,
  nodeId: string,
  ip: string | undefined,
): Promise<boolean> {
  const { rows } = await db.query(`SELECT allowed_cidrs FROM nodes WHERE id = $1`, [nodeId])
  const spec = rows[0]?.allowed_cidrs as string | null | undefined
  if (!spec) return true // unpinned nodes are allowed anywhere
  return new Acl(spec).allows(ip)
}

export function describeAcls(agent: Acl, admin: Acl): string[] {
  const notes: string[] = []
  if (agent.open) {
    notes.push('DAI_AGENT_CIDRS unset: the agent API accepts connections from any address')
  }
  if (admin.open) {
    notes.push('DAI_ADMIN_CIDRS unset: the admin API accepts connections from any address')
  }
  return notes
}
