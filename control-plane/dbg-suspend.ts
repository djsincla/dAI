import { freshDb, seed } from './test/helpers.js'
import { poolsFor } from './src/lib/pools.js'

const db = await freshDb()
const fx = await seed(db)
await db.query(`UPDATE nodes SET tiers = ARRAY['harvest','cluster']::text[] WHERE id = $1`,
               [fx.nodeId])
const n = await db.query('SELECT id, hostname, tier, tiers, chip, memory_gb FROM nodes')
console.log('node:', JSON.stringify(n.rows[0]))
const p = await db.query('SELECT id, name, tier, membership FROM pools')
console.log('pools:', JSON.stringify(p.rows))
console.log('matches:', poolsFor(n.rows[0] as any, p.rows as any).map((x: any) => x.name))
await db.end()
