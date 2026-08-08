// Demo fleet for local development: two nodes with 24 hours of presence
// history, one locked and one in use, so the capacity graph has the overnight
// shape it will have in production.
//
//   DATABASE_URL=postgres://dai:dai@localhost:5433/dai npx tsx scripts/seed-demo.mjs
//
// Resets the database. Do not point it at anything you care about.
import { createPool, reset } from '../src/lib/db.js'
const db = createPool(process.env.DATABASE_URL)
await reset(db)
const pool = await db.query(`INSERT INTO pools (name,tier,schedule,preempt)
  VALUES ('overnight-harvest','harvest','independent-units','on-user-activity') RETURNING id`)
const u = await db.query(`INSERT INTO users (email) VALUES ('dwayne@example.com') RETURNING id`)
const g = await db.query(`INSERT INTO groups (name) VALUES ('wranglers') RETURNING id`)
await db.query(`INSERT INTO group_members VALUES ($1,$2)`, [g.rows[0].id, u.rows[0].id])
await db.query(`INSERT INTO role_bindings VALUES ($1,$2,'admin')`, [g.rows[0].id, pool.rows[0].id])
const mk = async (host, chip, mem, ws, state, owner) =>
  (await db.query(`INSERT INTO nodes (hostname,chip,memory_gb,metal_working_set_gb,state,
    cert_fingerprint,owner_user_id,presence_state,on_ac_power,thermal_ok)
    VALUES ($1,$2,$3,$4,'active',$5,$6,$7,true,true) RETURNING id`,
    [host, chip, mem, ws, 'fp-'+host, owner, state])).rows[0].id
const a = await mk('rotorua','Apple M2 Max',64,51.8,'LOCKED',u.rows[0].id)
const b = await mk('orca','Apple M4 Pro',48,37.4,'ACTIVE',u.rows[0].id)
// 24h of presence history: machines lock overnight, active during the day.
for (let h = 23; h >= 0; h--) {
  for (const [id, night, day] of [[a,'LOCKED','ACTIVE'],[b,'ABSENT','IDLE']]) {
    const hour = (new Date().getHours() - h + 24) % 24
    const st = (hour >= 19 || hour < 8) ? night : day
    await db.query(`INSERT INTO presence_samples (node_id, at, presence_state, on_ac_power)
      VALUES ($1, now() - ($2||' hours')::interval, $3, true) ON CONFLICT DO NOTHING`, [id, h, st])
  }
}
const job = await db.query(`INSERT INTO jobs (pool_id,kind) VALUES ($1,'embed') RETURNING id`,[pool.rows[0].id])
for (let i=0;i<6;i++) await db.query(
  `INSERT INTO work_units (job_id,kind,payload,position) VALUES ($1,'embed',$2,$3)`,
  [job.rows[0].id, JSON.stringify([{id:i}]), i*1000])
await db.query(`INSERT INTO activity_log (node_id,event,detail) VALUES ($1,'work.result',$2)`,
  [a, JSON.stringify({requeued: 3})])
console.log('SESSION=' + u.rows[0].id)
await db.end()
