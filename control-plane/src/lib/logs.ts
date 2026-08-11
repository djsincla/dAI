import type { Db } from './db.js'

/**
 * One log, out of two tables that answer different questions.
 *
 * `activity_log` is per machine and belongs to the person who owns it: what has
 * this Mac been doing, and can I see it without asking anyone. `audit_log` is
 * fleet-wide and belongs to whoever runs the fleet: who told it to do that.
 *
 * They are read together because nobody investigating an incident cares which
 * table a line came from. A model push and the fetches it caused are one story,
 * and it was previously only readable by opening two things and interleaving
 * them by eye.
 */
export interface LogQuery {
  q?: string
  since?: string
  until?: string
  source?: 'node' | 'fleet'
  limit?: number
}

export interface LogRow {
  at: string
  source: 'node' | 'fleet'
  node: string | null
  actor: string | null
  event: string
  detail: unknown
}

/** Hard ceiling, whatever a caller asks for. */
export const MAX_ROWS = 5000

export async function readLogs(db: Db, query: LogQuery): Promise<LogRow[]> {
  const limit = Math.min(MAX_ROWS, Math.max(1, Number(query.limit ?? 500)))

  // Both halves projected into one shape, then filtered as one. Filtering each
  // separately and merging in TypeScript would apply the limit twice and return
  // the newest 500 of each rather than the newest 500 overall, which reads as
  // missing entries exactly when a burst of one kind is what you are chasing.
  const { rows } = await db.query(
    `WITH unified AS (
       SELECT a.at, 'node'::text AS source, n.hostname AS node,
              NULL::text AS actor, a.event, a.detail
         FROM activity_log a JOIN nodes n ON n.id = a.node_id
       UNION ALL
       SELECT b.at, 'fleet'::text AS source, NULL::text AS node,
              u.email AS actor, b.action AS event,
              b.detail || jsonb_build_object('subject', b.subject)
         FROM audit_log b LEFT JOIN users u ON u.id = b.user_id
     )
     SELECT * FROM unified
      WHERE ($1::text IS NULL OR source = $1)
        AND ($2::timestamptz IS NULL OR at >= $2)
        AND ($3::timestamptz IS NULL OR at <= $3)
        AND ($4::text IS NULL OR
             -- Detail cast to text so a search matches inside the payload: a
             -- unit id or a model name lives there and nowhere else.
             (coalesce(node, '') || ' ' || coalesce(actor, '') || ' ' ||
              event || ' ' || detail::text) ILIKE '%' || $4 || '%')
      ORDER BY at DESC
      LIMIT $5`,
    [query.source ?? null, query.since ?? null, query.until ?? null,
     query.q && query.q.trim() !== '' ? query.q.trim() : null, limit],
  )

  return rows.map((r) => ({
    at: new Date(r.at).toISOString(),
    source: r.source as 'node' | 'fleet',
    node: (r.node as string | null) ?? null,
    actor: (r.actor as string | null) ?? null,
    event: r.event as string,
    detail: r.detail,
  }))
}

/** Escaping for the HTML export, which is a document somebody may keep. */
function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c] as string))
}

/**
 * Plain text, one line per entry.
 *
 * Fixed column order and no wrapping, so it survives grep, diff and being
 * pasted into a ticket - which is what a text export is for.
 */
export function asText(rows: LogRow[]): string {
  return rows.map((r) => [
    r.at,
    r.source === 'node' ? (r.node ?? 'unknown') : (r.actor ?? 'fleet'),
    r.event,
    JSON.stringify(r.detail),
  ].join('\t')).join('\n') + (rows.length > 0 ? '\n' : '')
}

/**
 * A standalone HTML document.
 *
 * Self-contained on purpose: no stylesheet link, no script, nothing fetched.
 * An export that only renders while the control plane is up is not an export,
 * and this is the artefact somebody attaches to an incident report or sends to
 * a person who has no login.
 */
export function asHtml(rows: LogRow[], meta: { query: LogQuery; generatedAt: string }): string {
  const filters = [
    meta.query.q ? `matching "${escapeHtml(meta.query.q)}"` : null,
    meta.query.source ? `from ${escapeHtml(meta.query.source)} logs` : null,
    meta.query.since ? `since ${escapeHtml(meta.query.since)}` : null,
    meta.query.until ? `until ${escapeHtml(meta.query.until)}` : null,
  ].filter(Boolean).join(', ')

  return `<!doctype html>
<meta charset="utf-8">
<title>dAI fleet log</title>
<style>
  body { font: 14px/1.5 ui-sans-serif, -apple-system, system-ui, sans-serif;
         margin: 32px; color: #17232a; background: #fff; }
  h1 { font-size: 18px; margin: 0 0 4px; }
  p.meta { color: #5b6b73; font-size: 13px; margin: 0 0 20px; }
  table { border-collapse: collapse; width: 100%; font-size: 13px; }
  th { text-align: left; color: #5b6b73; font-weight: 600; font-size: 11px;
       text-transform: uppercase; letter-spacing: .05em;
       padding: 0 10px 8px; border-bottom: 1px solid #dde5e5; }
  td { padding: 7px 10px; border-bottom: 1px solid #eef2f3; vertical-align: top; }
  td.at { white-space: nowrap; color: #5b6b73; font-variant-numeric: tabular-nums; }
  td.detail { font-family: ui-monospace, Menlo, monospace; font-size: 12px;
              color: #5b6b73; word-break: break-word; }
  .fleet { color: #0b7267; font-weight: 600; }
  @media (prefers-color-scheme: dark) {
    body { background: #0b1416; color: #e4efee; }
    th { color: #8aa3a5; border-color: #1e343a; }
    td { border-color: #16272b; }
    td.at, td.detail { color: #8aa3a5; }
    .fleet { color: #52c2b1; }
  }
</style>
<h1>dAI fleet log</h1>
<p class="meta">${rows.length} entries${filters ? `, ${filters}` : ''}.
  Exported ${escapeHtml(meta.generatedAt)}.</p>
<table>
  <thead><tr><th>Time</th><th>Where</th><th>Event</th><th>Detail</th></tr></thead>
  <tbody>
${rows.map((r) => `    <tr>
      <td class="at">${escapeHtml(r.at)}</td>
      <td${r.source === 'fleet' ? ' class="fleet"' : ''}>${
        escapeHtml(r.source === 'node' ? (r.node ?? 'unknown') : (r.actor ?? 'fleet'))}</td>
      <td>${escapeHtml(r.event)}</td>
      <td class="detail">${escapeHtml(JSON.stringify(r.detail))}</td>
    </tr>`).join('\n')}
  </tbody>
</table>
`
}
