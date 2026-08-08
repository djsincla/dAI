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
                          CHECK (state IN ('pending','active','cordoned','paused','offline')),
    -- Drives the pause right that no role can override.
    owner_user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
    cert_fingerprint      text UNIQUE,
    enrolled_at           timestamptz,
    paused_until          timestamptz,
    presence_state        text,
    on_ac_power           boolean,
    thermal_ok            boolean,
    last_heartbeat        timestamptz,
    -- workload class -> items/sec, observed from completed work. Never declared
    -- by the node, and never inferred from the chip: the newer M4 Pro is the
    -- slower machine of the pair measured.
    capability_profiles   jsonb NOT NULL DEFAULT '{}'::jsonb,
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
