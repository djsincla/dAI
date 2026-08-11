import { describe, expect, it } from 'vitest'
import { nodeMatchesPool } from '../src/lib/pools.js'
import { matchesGroup } from '../ui/view.js'

/**
 * The membership rule exists twice, once per runtime, and the two must agree.
 *
 * They did not. The page checked only hand-picked lists, so it reported both
 * machines as belonging to nothing while the scheduler was dispatching to them
 * through a rule-based pool. A fleet view that disagrees with the scheduler is
 * worse than none, because it gets believed.
 *
 * The browser has no build step and cannot import the server's TypeScript, so
 * duplication is the honest answer and this is what keeps it honest.
 */
const cases: { name: string; node: Record<string, unknown>; pool: Record<string, unknown> }[] = []

const nodes = [
  { id: 'n1', hostname: 'rotorua', tier: 'cluster', chip: 'Apple M2 Max', memoryGb: 64 },
  { id: 'n2', hostname: 'orca', tier: 'harvest', chip: 'Apple M4 Pro', memoryGb: 48 },
  { id: 'n3', hostname: 'air', tier: 'harvest', chip: 'Apple M2', memoryGb: 16 },
  { id: 'n4', hostname: 'unprobed', tier: 'harvest', chip: null, memoryGb: null },
]
const pools = [
  { id: 'p1', tier: 'harvest', membership: {} },
  { id: 'p2', tier: 'cluster', membership: {} },
  { id: 'p3', tier: 'harvest', membership: { minMemoryGb: 32 } },
  { id: 'p4', tier: 'harvest', membership: { chips: ['Apple M4 Pro'] } },
  { id: 'p5', tier: 'harvest', membership: { hostnames: ['orca'] } },
  { id: 'p6', tier: 'harvest', membership: { nodeIds: ['n2'] } },
  { id: 'p7', tier: 'harvest', membership: { nodeIds: ['n3'], minMemoryGb: 512 } },
  { id: 'p8', tier: 'cluster', membership: { nodeIds: ['n2'] } },
  { id: 'p9', tier: 'harvest', membership: null },
]
for (const node of nodes) {
  for (const pool of pools) cases.push({ name: `${node.hostname} in ${pool.id}`, node, pool })
}

describe('the browser and the scheduler agree about group membership', () => {
  it.each(cases)('$name', ({ node, pool }) => {
    // The server reads snake_case straight from Postgres; the browser reads the
    // camelCase the API emits. Same machine, two spellings, one answer.
    const serverNode = {
      id: node.id, hostname: node.hostname, tier: node.tier,
      chip: node.chip, memory_gb: node.memoryGb,
    }
    expect(matchesGroup(node, pool)).toBe(nodeMatchesPool(serverNode as never, pool as never))
  })

  it('agrees that a rule pool with no constraints holds everything', () => {
    // The case that was wrong: an empty membership is a rule that matches every
    // machine, not a list that matches none.
    for (const node of nodes) {
      expect(matchesGroup(node, pools[0]!), node.hostname as string).toBe(true)
    }
  })
})
