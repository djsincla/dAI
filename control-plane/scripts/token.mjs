import { createPool } from '../src/lib/db.js'
const db = createPool(process.env.DATABASE_URL)
await db.query(`INSERT INTO join_tokens (token) VALUES ('jt-dev') ON CONFLICT DO NOTHING`)
const u = await db.query(`SELECT id FROM users LIMIT 1`)
console.log('ADMIN=' + u.rows[0].id)
await db.end()
