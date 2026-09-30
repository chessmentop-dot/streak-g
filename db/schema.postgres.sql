-- ============================================================================
-- Streak OS v11 — PostgreSQL schema (target for the future server migration)
-- ============================================================================
-- 1:1 translation of db/schema.sql (SQLite). The in-app delta core speaks the
-- same operation model (change_log + domain tables), so a small API server can
-- expose the exact same semantics over PostgreSQL — see db/ARCHITECTURE.md.
--
-- Key dialect differences handled here:
--   TEXT JSON payloads  → JSONB (indexable, queryable)
--   INTEGER AUTOINCREMENT → BIGINT GENERATED ALWAYS AS IDENTITY
--   ISO-8601 TEXT stamps → TIMESTAMPTZ (canonical UTC in transit)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS streak_os;
SET search_path TO streak_os;

-- ----------------------------------------------------------------------------
-- meta
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta (
    key        TEXT PRIMARY KEY,
    value_json JSONB NOT NULL
);

-- ----------------------------------------------------------------------------
-- Domain tables
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS activities (
    id             TEXT PRIMARY KEY,
    name           TEXT NOT NULL,
    category       TEXT,
    type           TEXT,
    unit           TEXT,
    target         NUMERIC,
    savers         INTEGER,
    min            NUMERIC,
    priority       INTEGER,
    initial_streak INTEGER DEFAULT 0,
    initial_best   INTEGER DEFAULT 0,
    status         TEXT DEFAULT 'active',
    created_at     TIMESTAMPTZ,
    updated_at     TIMESTAMPTZ,
    rev_device     TEXT,
    data_json      JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_activities_category ON activities(category);
CREATE INDEX IF NOT EXISTS idx_activities_name     ON activities USING gin (to_tsvector('simple', name));

CREATE TABLE IF NOT EXISTS entries (
    id          TEXT PRIMARY KEY,
    activity_id TEXT NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
    date        DATE NOT NULL,
    amount      NUMERIC NOT NULL DEFAULT 0,
    note        TEXT,
    created_at  TIMESTAMPTZ,
    updated_at  TIMESTAMPTZ,
    rev_device  TEXT,
    data_json   JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_entries_activity_date ON entries(activity_id, date);
CREATE INDEX IF NOT EXISTS idx_entries_date          ON entries(date);

CREATE TABLE IF NOT EXISTS measurement_types (
    id        TEXT PRIMARY KEY,
    name      TEXT,
    data_json JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS presets (
    name      TEXT PRIMARY KEY,
    data_json JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key       TEXT PRIMARY KEY,
    data_json JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS view_settings (
    key       TEXT PRIMARY KEY,
    data_json JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS change_history (
    id    TEXT PRIMARY KEY,
    at    TIMESTAMPTZ,
    kind  TEXT,
    label TEXT,
    meta  TEXT
);

-- ----------------------------------------------------------------------------
-- change_log: delta journal / CDC stream (append-only)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS change_log (
    seq          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id           TEXT UNIQUE,
    device_id    TEXT NOT NULL,
    entity       TEXT NOT NULL,
    entity_id    TEXT NOT NULL,
    op           TEXT NOT NULL CHECK (op IN ('upsert','delete','append')),
    payload_json JSONB,
    ts           TIMESTAMPTZ,
    synced       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_change_log_synced ON change_log(synced, seq);
CREATE INDEX IF NOT EXISTS idx_change_log_entity ON change_log(entity, entity_id);
CREATE INDEX IF NOT EXISTS idx_change_log_device ON change_log(device_id, seq);

-- ----------------------------------------------------------------------------
-- sync_state: pull cursors per device
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_state (
    device_id  TEXT PRIMARY KEY,
    last_seq   BIGINT NOT NULL DEFAULT 0,
    epoch      INTEGER NOT NULL DEFAULT 1,
    updated_at TIMESTAMPTZ
);

-- ----------------------------------------------------------------------------
-- tombstones: LWW delete markers
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tombstones (
    key       TEXT PRIMARY KEY,
    entity    TEXT,
    entity_id TEXT,
    ts        TIMESTAMPTZ,
    device_id TEXT
);

-- ----------------------------------------------------------------------------
-- Useful reporting views (examples of what the relational model unlocks)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_daily_totals AS
SELECT e.activity_id,
       a.name,
       e.date,
       SUM(e.amount) AS total,
       COUNT(*)      AS log_count
FROM entries e
JOIN activities a ON a.id = e.activity_id
GROUP BY e.activity_id, a.name, e.date;

CREATE OR REPLACE VIEW v_pending_ops AS
SELECT device_id, COUNT(*) AS pending_ops
FROM change_log
WHERE synced = FALSE
GROUP BY device_id;
