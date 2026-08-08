# dAI control plane

API-first service for node enrollment, work dispatch and fleet policy.
Spec: [`../docs/CONTROL_PLANE.md`](../docs/CONTROL_PLANE.md).

`openapi/dai.yaml` is the source of truth. Every request is validated against it
before a handler runs, and responses are validated outside production. The agent
is Swift and this is TypeScript, so the schema is the only artifact they share
and the only place a mismatch can be caught before deployment.

## Running

```bash
npm install
npm run db:up                 # postgres on 5433
./scripts/make-certs.sh       # development CA, server and node certificates
DATABASE_URL=postgres://dai:dai@localhost:5433/dai npm start
```

Without TLS material the server logs a warning and falls back to HTTP. That is
for local development only: a deployment that starts on plaintext grows an
unauthenticated dispatch endpoint that is hard to close later.

## Tests

```bash
npm run db:up
DATABASE_URL=postgres://dai:dai@localhost:5433/dai npm test
```

34 tests against a real Postgres rather than a mock, because most of what is
under test is concurrency and expiry semantics, which a fake would model
incorrectly in exactly the places that matter.

`DAI_TRUST_FINGERPRINT_HEADER=1` lets tests present a node identity as a header
instead of a client certificate. It is off by default: a deployment that
silently accepts a header as node identity has no authentication at all.

## What the skeleton implements

**Lease expiry**, which is the gap that made the spike coordinator lose work. It
held in-flight units in memory with no timeout, so a node dropping off the
network stranded them permanently. That happened live when a laptop went flat
mid-run. Leases now expire, a reaper requeues them, and a late result from a
reaped lease is rejected with 409 rather than double-counted.

**Typed work with capability negotiation.** A node advertises the kinds it may
run *right now* under its presence policy, not what it is capable of. The
scheduler applies the same policy again server-side, so a buggy or compromised
agent cannot talk it into dispatching GPU work to a machine someone is using.
Presence unknown fails closed to ANE-only.

**Partial results.** An agent yields between items rather than between units and
hands back what it did not reach; the remainder is requeued at the head so a
partially served unit is not stranded behind the whole backlog.

**Capability profiles per workload class**, not a scalar. The same two machines
differed 7.5% on a 1.5B model and 26.3% on a 7B, so one number would misallocate
by 20-40% depending on the workload.

**Pool-scoped RBAC**, with the owner's pause right sitting outside it. A machine's
owner can always pause it and no role overrides that. An operator who could force
work onto someone's Mac makes the agent malware in that person's mental model.

**Enrollment that never auto-trusts a token bearer.** A joining node lands in
`pending` with its fingerprint and receives nothing until an admin approves it.

## Layout

```
openapi/dai.yaml    source of truth for both clients
db/schema.sql       tables, indexes, constraints
src/lib/db.ts       pool, migrations, transaction helper
src/lib/policy.ts   presence policy; mirrors spike/presence/presence.py
src/lib/work.ts     dispatch, leases, requeue, reaper
src/lib/auth.ts     mTLS node identity, session RBAC, owner rights
src/routes/         agent and admin surfaces
test/               34 tests against real Postgres
```

## Not yet built

- Certificate issuance. Enrollment records a CSR fingerprint; approval does not
  yet sign and return a certificate.
- Gang scheduling for the cluster tier, and the admission gate
  (`spike/cluster/admit.py`) is not wired in.
- Model catalogue and hash verification. Units carry `modelHash` but nothing
  checks it yet.
- Asset distribution, which rendering makes urgent: a scene is tens of GB and
  differs per job, unlike a model that is cached once and shared.
- The UI.
