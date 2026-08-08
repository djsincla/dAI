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

## UI

`/` redirects to the fleet view; `/docs` renders the API from the served
contract; `/openapi.yaml` is that contract.

No build step and no framework, so the UI runs anywhere the control plane runs
and can be read without tooling. The API is the contract and this is one client
of it, deliberately not the only possible one.

The columns come from the spike rather than convention: **working set** rather
than installed RAM, because Metal caps itself near 81% of unified memory;
**headroom** rather than free memory, because what matters is what policy
permits right now; **yields per week**, because that is the early warning a
policy is too aggressive for a particular machine.

The headline graph stacks ANE capacity under GPU capacity over 24 hours. The
upper band appears only as machines lock, so its shape across a day is the
argument for harvesting; the flat band beneath it is the daytime capacity the
ANE path provides.

```bash
DATABASE_URL=postgres://dai:dai@localhost:5433/dai npx tsx scripts/seed-demo.mjs
```

Seeds two nodes with 24 hours of presence history so the graph has its real
shape. It resets the database, so do not point it at anything that matters.

## Surfaces

The agent and admin APIs are separable at the listener, not only by path.
Workers poll continuously and their dispatch must not stop because the
human-facing side is restarting or being scaled independently.

```bash
PORT=8443 npm start                 # one process, both surfaces
PORT=8443 AGENT_PORT=8444 npm start # worker API on its own listener
```

## Network access control

Two optional layers, both defence in depth and neither a substitute for
authentication. A caller from an allowed network with no credentials is still
refused.

```bash
DAI_AGENT_CIDRS=10.0.0.0/24,192.168.4.0/22   # who may reach /agent/v1
DAI_ADMIN_CIDRS=192.168.4.0/22               # who may reach /admin/v1
```

Unset means open, and the server logs a warning saying so at startup. The two
surfaces are configured separately because agents live on the fleet network and
humans may not.

Nodes can additionally be pinned to the network they enrolled from
(`nodes.allowed_cidrs`). That check runs *after* the certificate has identified
the node, so it answers "is this node calling from where it should be" rather
than "who is this", and it is the layer that catches valid key material copied
off a machine and used somewhere else. Refusals are written to the node's
activity log, which its owner can read.

**X-Forwarded-For is ignored unless `TRUST_PROXY` is set.** Reading it
unconditionally would let any caller declare their own source address, which
makes an allowlist worse than not having one.

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
