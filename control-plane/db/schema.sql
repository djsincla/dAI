-- dAI control plane schema.
--
-- Two things here exist because the spike proved they had to:
--   work_units.lease_expires_at, because the spike coordinator held in-flight
--   units in memory with no timeout and stranded them permanently when a node
--   vanished, which happened live.
--   nodes.capability_profiles as a map rather than a scalar, because the same
--   two machines differed 7.5% on a 1.5B model and 26.3% on a 7B.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email       text NOT NULL UNIQUE,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE groups (
    id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name  text NOT NULL UNIQUE
);

CREATE TABLE group_members (
    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (group_id, user_id)
);

CREATE TABLE pools (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name      text NOT NULL UNIQUE,
    tier      text NOT NULL CHECK (tier IN ('harvest', 'cluster')),
    schedule  text NOT NULL CHECK (schedule IN ('independent-units', 'gang')),
    preempt   text NOT NULL CHECK (preempt IN ('on-user-activity', 'never')),
    priority  int  NOT NULL DEFAULT 100,
    -- Cluster pools pin explicit members; harvest pools match a tag query.
    membership jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- Pool-scoped role bindings. A group's role differs per pool, so membership is
-- not global.
CREATE TABLE role_bindings (
    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    pool_id  uuid NOT NULL REFERENCES pools(id)  ON DELETE CASCADE,
    role     text NOT NULL CHECK (role IN ('viewer', 'operator', 'admin')),
    PRIMARY KEY (group_id, pool_id)
);

CREATE TABLE nodes (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    hostname              text NOT NULL,
    chip                  text,
    memory_gb             numeric,
    -- Metal caps itself around 81% of unified memory. Agent ceilings are
    -- fractions of this, never of installed RAM.
    metal_working_set_gb  numeric,
    os_version            text,
    tier                  text NOT NULL DEFAULT 'harvest'
                          CHECK (tier IN ('harvest', 'cluster')),
    state                 text NOT NULL DEFAULT 'pending'
                          CHECK (state IN ('pending','active','cordoned','paused',
                                           'offline','superseded')),
    -- IOPlatformUUID, which survives reinstalls and OS upgrades.
    --
    -- Enrollment mints a new key and a new record every time it runs, so
    -- without this a reinstalled machine appeared as a second node and the old
    -- record stayed active-looking forever, inflating the fleet view and the
    -- capacity figures with hardware that no longer existed. Approving a node
    -- supersedes any earlier record for the same machine.
    --
    -- Not a credential. It says which record to replace; authentication is
    -- still the certificate.
    machine_id            text,
    -- Drives the pause right that no role can override.
    owner_user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
    cert_fingerprint      text UNIQUE,
    -- Kept so an admin can see what was signed, and so a revoked certificate
    -- can be identified after the fact.
    cert_pem              text,
    cert_not_after        timestamptz,
    csr_pem               text,
    -- One-time secret the node presents to collect its certificate after
    -- approval. Cleared on collection: a credential that can be replayed is
    -- a credential that will be.
    enrollment_token      text,
    revoked_at            timestamptz,
    enrolled_at           timestamptz,
    paused_until          timestamptz,
    -- Reported by the agent, and never written by the control plane.
    --
    -- This is the pause on someone's own machine, and it has to be theirs
    -- alone. An admin who can clear it turns the agent into something people
    -- work around rather than trust, and the whole arrangement depends on
    -- trust: the isolation here is policy, not hardware, so the only real
    -- guarantee a machine's owner has is that the off switch works. It is
    -- deliberately separate from state='paused', which is the administrative
    -- one and can be lifted by an operator.
    user_paused           boolean NOT NULL DEFAULT false,
    user_paused_at        timestamptz,
    presence_state        text,
    -- What each model this node can serve actually accepts, keyed by name.
    --
    -- Separate from resident_models, which is about memory right now: a
    -- context window is a property of the model and does not change with
    -- whether it happens to be loaded.
    model_context         jsonb NOT NULL DEFAULT '{}'::jsonb,
    on_ac_power           boolean,
    thermal_ok            boolean,
    last_heartbeat        timestamptz,
    -- workload class -> items/sec, observed from completed work. Never declared
    -- by the node, and never inferred from the chip: the newer M4 Pro is the
    -- slower machine of the pair measured.
    capability_profiles   jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Networks this node may connect from, comma-separated CIDRs. Pinned at
    -- enrollment so a copied certificate presented from elsewhere is refused
    -- even though the certificate itself is valid. NULL means unpinned.
    allowed_cidrs         text,
    -- Model hashes currently held in memory, hash -> resident GB. Routing
    -- prefers a node that already has the model, because E4 puts load at 1-3s
    -- and putting that on an interactive request path is the difference between
    -- a service and a curiosity.
    resident_models       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX nodes_state_idx ON nodes(state);

CREATE TABLE jobs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pool_id     uuid NOT NULL REFERENCES pools(id) ON DELETE CASCADE,
    kind        text NOT NULL CHECK (kind IN ('embed','generate','render')),
    model_hash  text,
    state       text NOT NULL DEFAULT 'pending'
                CHECK (state IN ('pending','running','complete','failed')),
    submitted_by uuid REFERENCES users(id) ON DELETE SET NULL,
    -- What this work is, in words, and where it came from.
    --
    -- Without these a fleet view can say a machine is busy but not what with,
    -- and neither an operator nor the person whose machine it is can tell real
    -- work from a load test. That matters most for the synthetic case: work
    -- generated by a harness has to be visibly synthetic, or every capacity
    -- figure it produces is quietly overstated by someone else's experiment.
    label       text,
    -- Claimed by the submitter, unlike submitted_by, which is taken from the
    -- authenticated session and cannot be spoofed. Treat it as a label, not
    -- evidence: it is here to distinguish honest traffic sources, not to
    -- withstand a dishonest one.
    source      text NOT NULL DEFAULT 'api',
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE work_units (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id            uuid NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    kind              text NOT NULL CHECK (kind IN ('embed','generate','render')),
    -- Data only. A unit references a model by hash from the signed catalogue
    -- and can never name an interpreter, a path, or a command.
    payload           jsonb NOT NULL,
    result            jsonb,
    -- Which machine actually produced this, kept after the lease is released.
    --
    -- lease_node_id is cleared on completion, since the lease is over, so
    -- without this the answer to "where did this result come from" was
    -- discarded at the moment it became worth knowing.
    completed_by      uuid REFERENCES nodes(id) ON DELETE SET NULL,
    state             text NOT NULL DEFAULT 'pending'
                      CHECK (state IN ('pending','leased','done','failed')),
    -- Position lets a requeued remainder go back at the head, so a partially
    -- served unit is not stranded behind the whole backlog.
    position          bigint NOT NULL,
    lease_node_id     uuid REFERENCES nodes(id) ON DELETE SET NULL,
    lease_expires_at  timestamptz,
    attempts          int NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now()
);

-- The dispatch query: pending units of a servable kind, in position order.
CREATE INDEX work_units_dispatch_idx
    ON work_units (kind, state, position)
    WHERE state = 'pending';

-- The reaper query: leases past their expiry.
CREATE INDEX work_units_lease_idx
    ON work_units (lease_expires_at)
    WHERE state = 'leased';

CREATE TABLE join_tokens (
    token       text PRIMARY KEY,
    pool_id     uuid REFERENCES pools(id) ON DELETE SET NULL,
    expires_at  timestamptz,
    used_at     timestamptz
);

-- Owner-readable regardless of role bindings: without it every unrelated
-- slowdown gets blamed on the agent and there is no way to disprove it.
CREATE TABLE activity_log (
    id          bigserial PRIMARY KEY,
    node_id     uuid NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    at          timestamptz NOT NULL DEFAULT now(),
    event       text NOT NULL,
    detail      jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX activity_log_node_idx ON activity_log(node_id, at DESC);

-- Presence history, written on heartbeat.
--
-- The headline fleet graph is aggregate eligible capacity over 24 hours, split
-- by GPU and ANE. The overnight swell as machines lock is the value proposition
-- made visible, and the ANE band is the daytime capacity E5 bought. Neither can
-- be drawn from current state alone.
--
-- Also answers the two questions a wrangler actually has about a node: can I
-- count on it tonight (the idle pattern), and how often does it interrupt
-- (yields per week, which is the early warning that a policy is too aggressive).
CREATE TABLE presence_samples (
    node_id        uuid NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    at             timestamptz NOT NULL DEFAULT now(),
    presence_state text NOT NULL,
    on_ac_power    boolean,
    PRIMARY KEY (node_id, at)
);

CREATE INDEX presence_samples_at_idx ON presence_samples(at DESC);

-- The model catalogue: what weights exist, and what they are.
--
-- Until this table there was no such thing. `jobs.model_hash` was free text
-- matched against whatever a node happened to report holding, so "which
-- machines have the 32B" could only be answered by asking the machines, and
-- "should they have it" could not be asked at all. Models were staged by hand
-- with scp, unverified, and the record of what was where lived in somebody's
-- memory.
--
-- IF NOT EXISTS on the tables below, unlike the rest of this file, because
-- these were added to a schema that was already deployed and the DDL had to be
-- safe to apply to a live database.
CREATE TABLE IF NOT EXISTS models (
    id             text PRIMARY KEY,
    runtime        text NOT NULL,
    kind           text NOT NULL,
    size_bytes     bigint NOT NULL,
    -- Advertised context, which testing showed is often fiction: a 3B claiming
    -- 32k fell apart between 8k and 10k. Recorded as what the weights claim,
    -- separately from what the fleet is willing to promise.
    context_length integer,
    quantization   text,
    -- Chat template family, which is what the tool dialect is matched on. Model
    -- names lie about this and templates do not.
    family         text,
    imported_at    timestamptz NOT NULL DEFAULT now(),
    imported_by    uuid REFERENCES users(id),
    CONSTRAINT models_runtime_check CHECK (runtime IN ('mlx', 'coreml')),
    CONSTRAINT models_kind_check CHECK (kind IN ('generate', 'embed'))
);

-- One row per file, hashed individually.
--
-- Per file rather than per model because a 17GB model is four shards, and the
-- failure this exists to catch is one truncated shard out of four. A single
-- whole-model hash would detect it and be unable to say which part to fetch
-- again; per file makes verification precise and transfer resumable.
CREATE TABLE IF NOT EXISTS model_files (
    model_id   text NOT NULL REFERENCES models(id) ON DELETE CASCADE,
    path       text NOT NULL,
    size_bytes bigint NOT NULL,
    sha256     text NOT NULL,
    PRIMARY KEY (model_id, path)
);

-- Desired state: which pools are supposed to hold which models.
--
-- The fleet view could show what a machine had and never what it should have,
-- so drift was invisible by construction. This is the declared half; the
-- observed half is nodes.resident_models, and the difference between them is
-- the only thing worth looking at.
CREATE TABLE IF NOT EXISTS pool_models (
    pool_id     uuid NOT NULL REFERENCES pools(id) ON DELETE CASCADE,
    model_id    text NOT NULL REFERENCES models(id) ON DELETE CASCADE,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    assigned_by uuid REFERENCES users(id),
    PRIMARY KEY (pool_id, model_id)
);

CREATE INDEX IF NOT EXISTS pool_models_model_idx ON pool_models(model_id);

-- What a node has on disk, as opposed to what it has loaded.
--
-- `resident_models` answers "is this in memory right now", which flaps every
-- time a model is released and is the wrong question for a catalogue: orca held
-- 18GB of weights on disk and reported holding nothing, because nothing had
-- asked it to load them yet. An operator reading that would redistribute
-- weights that were already there.
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS stored_models jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Imports in flight, and the ones that failed.
--
-- Separate from `models` on purpose. A model is registered only once every one
-- of its files has landed and hashed, because a half-registered model would be
-- assignable to pools and fetched by nodes that could never complete it. That
-- invariant is worth keeping, and it leaves nowhere to record an import that is
-- still running: hashing eighteen gigabytes takes minutes, during which the
-- catalogue showed nothing at all and the only honest reading of the page was
-- that the import had failed.
CREATE TABLE IF NOT EXISTS model_imports (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    model_id    text NOT NULL,
    source      text NOT NULL,
    state       text NOT NULL DEFAULT 'running',
    files_done  integer NOT NULL DEFAULT 0,
    files_total integer NOT NULL DEFAULT 0,
    bytes_done  bigint  NOT NULL DEFAULT 0,
    error       text,
    started_at  timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    started_by  uuid REFERENCES users(id),
    CONSTRAINT model_imports_state_check CHECK (state IN ('running', 'done', 'failed'))
);

CREATE INDEX IF NOT EXISTS model_imports_recent_idx ON model_imports(started_at DESC);

-- Fleet-level actions, and who took them.
--
-- Separate from activity_log, which is per node and answers "what has this
-- machine been doing" for the person who owns it. This answers "who told the
-- fleet to do that", which is a different question with a different reader.
--
-- It exists because pushing a model to a pool commits every machine in it to
-- fetching up to eighteen gigabytes, and the only record of it was a single
-- mutable row in pool_models: unassign and reassign, and the history was gone.
-- An action with fleet-wide consequences and no trace is one nobody can be
-- asked about.
CREATE TABLE IF NOT EXISTS audit_log (
    id      bigserial PRIMARY KEY,
    at      timestamptz NOT NULL DEFAULT now(),
    user_id uuid REFERENCES users(id),
    action  text NOT NULL,
    subject text NOT NULL,
    detail  jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS audit_log_subject_idx ON audit_log(subject, at DESC);
CREATE INDEX IF NOT EXISTS audit_log_at_idx ON audit_log(at DESC);

-- What each machine is running.
--
-- A version string is a claim and the fingerprint is evidence: the hash of the
-- executable actually running. Both are needed because a binary can be replaced
-- by this control plane, by an MDM, or by somebody at a keyboard, and only the
-- node knows which one won. Two deploys in one day once left both machines on a
-- build from hours earlier, discoverable only by comparing file sizes over ssh.
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS agent_version text;
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS agent_fingerprint text;

-- Agent builds the fleet may be asked to run.
--
-- The hash is the point. A version string is what somebody typed; this is what
-- the bytes are, and it is what a node checks before it will replace the binary
-- it is currently running with one it just downloaded.
CREATE TABLE IF NOT EXISTS agent_builds (
    version     text PRIMARY KEY,
    sha256      text NOT NULL,
    size_bytes  bigint NOT NULL,
    notes       text,
    uploaded_at timestamptz NOT NULL DEFAULT now(),
    uploaded_by uuid REFERENCES users(id)
);

-- Who is allowed to replace the binary on these machines.
--
-- `external` by default, and the default matters: a system that arrives able to
-- push executables to other people's Macs without anyone opting in is the wrong
-- system. External covers both MDM and somebody installing by hand, and in that
-- mode the control plane records what it expects and reports what it sees,
-- while never acting. Two things racing to own the same binary is worse than
-- either owning it alone.
ALTER TABLE pools ADD COLUMN IF NOT EXISTS agent_channel text NOT NULL DEFAULT 'external';
ALTER TABLE pools ADD COLUMN IF NOT EXISTS desired_agent_version text;
ALTER TABLE pools ADD CONSTRAINT pools_agent_channel_check
    CHECK (agent_channel IN ('managed', 'external'));

-- Upgrades attempted, and how they ended.
--
-- Written by the node rather than the control plane, because the interesting
-- outcome is the one the control plane cannot observe: a binary that starts,
-- fails to reach home, and is rolled back by the machine itself. Without this
-- the fleet would show a node that never moved and no trace of it having tried.
CREATE TABLE IF NOT EXISTS agent_upgrades (
    id           bigserial PRIMARY KEY,
    node_id      uuid NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    from_version text,
    to_version   text NOT NULL,
    state        text NOT NULL,
    detail       text,
    at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT agent_upgrades_state_check
        CHECK (state IN ('started', 'committed', 'reverted', 'failed'))
);

CREATE INDEX IF NOT EXISTS agent_upgrades_node_idx ON agent_upgrades(node_id, at DESC);

-- Sign-in, replacing a scheme where the user id was the credential.
--
-- The console used to authenticate with a bare user id. That value is an
-- identifier rather than a secret: it is returned by the jobs API, written to
-- the audit log, stamped on every imported model, and visible in any screenshot
-- of the fleet view. Anyone who read it anywhere had full administrative access,
-- with no expiry and no way to revoke it short of deleting the user.
ALTER TABLE users ADD COLUMN IF NOT EXISTS username text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS must_change_password boolean NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS password_changed_at timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS users_username_key ON users(lower(username));

-- Credentials that are secrets, of two kinds with one lookup.
--
-- A session is what a browser gets and expires by itself. An api_key is what a
-- program gets and does not, because a tool pointed at the serving API cannot be
-- asked to sign in, but it is named and individually revocable.
--
-- Only the hash is stored, for the same reason the password column is a hash: a
-- copy of this database should be a list of hashes, not a set of working
-- credentials.
CREATE TABLE IF NOT EXISTS auth_tokens (
    token_hash   text PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind         text NOT NULL,
    label        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz,
    expires_at   timestamptz,
    CONSTRAINT auth_tokens_kind_check CHECK (kind IN ('session', 'api_key'))
);

CREATE INDEX IF NOT EXISTS auth_tokens_user_idx ON auth_tokens(user_id, kind);
