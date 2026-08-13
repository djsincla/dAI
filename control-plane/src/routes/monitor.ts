import { Router } from 'express'
import type { GroupListeners } from '../lib/groupSockets.js'
import type { Db } from '../lib/db.js'

/**
 * What a monitoring system scrapes.
 *
 * Deliberately without a credential, because the alternative is a long-lived
 * secret pasted into a Prometheus config, checked into whatever repository that
 * lives in, and never rotated. An address range is a worse authenticator than a
 * key in general and a better one here: the reader is a machine at a known
 * location, doing one thing.
 *
 * That trade only holds if the range is actually set, so this surface refuses
 * every request when `DAI_MONITOR_CIDRS` is unset. Failing closed is the whole
 * design: an unauthenticated endpoint that defaults to open is a fleet inventory
 * published to anyone who can route to it.
 *
 * Nothing here is a secret in its own right, but it is not nothing either: node
 * names, how many machines exist, when they were last seen, and which models the
 * fleet holds. That is a map of the building.
 */
/**
 * `listeners` reports which group sockets are actually bound.
 *
 * Health has to know, because the failure it exists to catch is silent: the
 * group is there, its models are assigned, its machines are holding them, and
 * nothing answers on the port an application is pointed at. A control plane
 * that called that "ok" would be the reason nobody noticed.
 */
export function monitorRoutes(db: Db,
                              listeners?: () => GroupListeners | undefined): Router {
  const r = Router()

  /**
   * Is the control plane up and can it reach its database.
   *
   * Separate from `/healthz`, which answers whether the process is running. A
   * process that is up and cannot reach Postgres is not serving anybody, and a
   * check that cannot tell those apart pages nobody when it matters.
   */
  r.get('/health', async (_req, res) => {
    try {
      await db.query('SELECT 1')
    } catch (e) {
      res.status(503).type('text/plain').send(
        `unhealthy: database unreachable: ${(e as Error).message}\n`)
      return
    }
    // Every group with a socket should have that socket bound. A group that
    // predates sockets has none to check, and is answered for on the shared
    // serving port.
    const bound = new Set(listeners?.()?.bound() ?? [])
    if (listeners?.()) {
      const { rows } = await db.query(
        `SELECT name, serving_port FROM pools
          WHERE serving_port IS NOT NULL ORDER BY serving_port`)
      const silent = (rows as { name: string; serving_port: number }[])
        .filter((p) => !bound.has(Number(p.serving_port)))
      if (silent.length > 0) {
        res.status(503).type('text/plain').send(
          'unhealthy: '
          + silent.map((p) => `${p.name} is not answering on :${p.serving_port}`).join('; ')
          + '\n')
        return
      }
    }
    res.type('text/plain').send('ok\n')
  })

  /**
   * The fleet as numbers, in the text format every scraper already reads.
   *
   * Prometheus exposition rather than JSON: this exists to be pointed at by
   * something that already exists, and inventing a shape would mean writing an
   * exporter to translate it back.
   */
  r.get('/metrics', async (_req, res) => {
    const [nodes, work, models, upgrades] = await Promise.all([
      db.query(`SELECT state, presence_state, user_paused,
                       (last_heartbeat > now() - interval '2 minutes') AS fresh
                  FROM nodes WHERE state NOT IN ('pending', 'superseded')`),
      db.query(`SELECT state, count(*)::int AS n FROM work_units GROUP BY 1`),
      db.query(`SELECT count(*)::int AS n FROM models`),
      db.query(`SELECT state, count(*)::int AS n FROM agent_upgrades
                 WHERE at > now() - interval '24 hours' GROUP BY 1`),
    ])

    const out: string[] = []
    const metric = (name: string, help: string, type: string,
                    samples: [string, number][]) => {
      out.push(`# HELP dai_${name} ${help}`)
      out.push(`# TYPE dai_${name} ${type}`)
      for (const [labels, value] of samples) {
        out.push(`dai_${name}${labels} ${value}`)
      }
    }

    const all = nodes.rows as {
      state: string; presence_state: string | null; user_paused: boolean; fresh: boolean
    }[]

    metric('nodes_total', 'Machines enrolled and not retired.', 'gauge',
      [['', all.length]])

    // Reporting recently, which is what the scheduler uses to decide whether a
    // machine can be given work. A node that is "active" in the database and
    // silent for ten minutes is not capacity.
    metric('nodes_reporting', 'Machines that have reported within the freshness window.',
      'gauge', [['', all.filter((n) => n.fresh).length]])

    metric('nodes_paused_by_owner', 'Machines their owner has paused. Not a fault.',
      'gauge', [['', all.filter((n) => n.user_paused).length]])

    const byPresence = new Map<string, number>()
    for (const n of all) {
      const key = n.presence_state ?? 'unknown'
      byPresence.set(key, (byPresence.get(key) ?? 0) + 1)
    }
    metric('nodes_by_presence', 'Machines in each presence state.', 'gauge',
      [...byPresence].map(([state, n]) => [`{presence="${state}"}`, n]))

    metric('work_units', 'Work units by state.', 'gauge',
      (work.rows as { state: string; n: number }[])
        .map((w) => [`{state="${w.state}"}`, w.n]))

    metric('models_total', 'Models in the catalogue.', 'gauge',
      [['', (models.rows[0]?.n as number) ?? 0]])

    // A rollback is the number worth alerting on: it means a machine took a
    // binary, could not report in, and put the old one back by itself.
    metric('agent_upgrades_24h', 'Agent upgrades attempted in the last day, by outcome.',
      'counter',
      (upgrades.rows as { state: string; n: number }[])
        .map((u) => [`{state="${u.state}"}`, u.n]))

    res.type('text/plain; version=0.0.4').send(out.join('\n') + '\n')
  })

  return r
}
