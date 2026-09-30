-- ============================================================================
-- Streak OS v11 — Canonical database schema (SQLite dialect)
-- ============================================================================
-- This is the canonical relational schema of the Streak OS delta database.
-- The in-app storage engine (IndexedDB object stores) mirrors these tables 1:1
-- (see db/ARCHITECTURE.md). The in-app "Export SQLite database" button produces
-- a real .sqlite file with exactly this schema (schema embedded in index.html).
--
-- PostgreSQL variant: db/schema.postgres.sql
-- Migration guide:    db/ARCHITECTURE.md
--
-- Design principles
--   1. Delta storage: `change_log` is an append-only journal of operations.
--      Domain tables are the materialized view; nothing is ever fully rewritten.
--   2. Portability: TEXT ids (UUID-ish), ISO-8601 UTC timestamps, JSON payloads
--      in TEXT (→ JSONB on PostgreSQL). No SQLite-specific types in key columns.
--   3. Sync-ready: change_log doubles as the replication/CDC stream; sync_state
--      keeps per-device cursors; tombstones arbitrate delete-vs-update (LWW).
-- ============================================================================

PRAGMA journal_mode = WAL;          -- incremental page-level writes (SQLite)
PRAGMA foreign_keys = ON;
PRAGMA synchronous  = NORMAL;

-- ----------------------------------------------------------------------------
-- meta: schema/bookkeeping key-value store (plain, readable before unlock)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta (
    key        TEXT PRIMARY KEY,
    value_json TEXT NOT NULL
);

-- ----------------------------------------------------------------------------
-- Domain tables (materialized view of the latest state)
-- Column set = indexed/queried fields; `data_json` keeps the full record so the
-- export/import is always lossless.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS activities (
    id             TEXT PRIMARY KEY,
    name           TEXT NOT NULL,
    category       TEXT,
    type           TEXT,            -- measurement type id
    unit           TEXT,
    target         REAL,
    savers         INTEGER,
    min            REAL,
    priority       INTEGER,
    initial_streak INTEGER,
    initial_best   INTEGER,
    status         TEXT,            -- 'active' | 'disabled' | ...
    created_at     TEXT,            -- ISO-8601 UTC
    updated_at     TEXT,            -- LWW stamp (delta core)
    rev_device     TEXT,            -- device that produced the current revision
    data_json      TEXT NOT NULL    -- full record (color, emoji, history, ...)
);
CREATE INDEX IF NOT EXISTS idx_activities_category ON activities(category);

CREATE TABLE IF NOT EXISTS entries (
    id          TEXT PRIMARY KEY,
    activity_id TEXT NOT NULL REFERENCES activities(id),
    date        TEXT NOT NULL,      -- YYYY-MM-DD (calendar-independent key)
    amount      REAL NOT NULL DEFAULT 0,
    note        TEXT,
    created_at  TEXT,
    updated_at  TEXT,
    rev_device  TEXT,
    data_json   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_entries_activity_date ON entries(activity_id, date);
CREATE INDEX IF NOT EXISTS idx_entries_date          ON entries(date);

CREATE TABLE IF NOT EXISTS measurement_types (
    id        TEXT PRIMARY KEY,
    name      TEXT,
    data_json TEXT NOT NULL          -- units catalog
);

CREATE TABLE IF NOT EXISTS presets (
    name      TEXT PRIMARY KEY,
    data_json TEXT NOT NULL          -- settings snapshot {config}
);

CREATE TABLE IF NOT EXISTS settings (
    key       TEXT PRIMARY KEY,      -- 'global' = program defaults
    data_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS view_settings (
    key       TEXT PRIMARY KEY,      -- per-device UI state (never synced)
    data_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS change_history (
    id    TEXT PRIMARY KEY,
    at    TEXT,
    kind  TEXT,                       -- 'change' | 'delete' | 'restore' | ...
    label TEXT,
    meta  TEXT
);

-- ----------------------------------------------------------------------------
-- change_log: THE DELTA JOURNAL (append-only; the sync upload queue)
--   seq        monotonic per device (device_id + seq = global op identity)
--   entity     activity | entry | measurementType | preset | settings | history | meta
--   op         upsert | delete | append
--   payload    the record (upsert) or null (delete); JSON
--   synced     0 = pending upload, 1 = covered by a remote batch/snapshot
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS change_log (
    seq        INTEGER PRIMARY KEY AUTOINCREMENT,
    id         TEXT UNIQUE,          -- op uuid (idempotent apply)
    device_id  TEXT NOT NULL,
    entity     TEXT NOT NULL,
    entity_id  TEXT NOT NULL,
    op         TEXT NOT NULL,
    payload_json TEXT,
    ts         TEXT,                 -- LWW arbitration stamp
    synced     INTEGER NOT NULL DEFAULT 0,
    created_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_change_log_synced ON change_log(synced, seq);
CREATE INDEX IF NOT EXISTS idx_change_log_entity ON change_log(entity, entity_id);

-- ----------------------------------------------------------------------------
-- sync_state: pull cursors per remote device
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sync_state (
    device_id  TEXT PRIMARY KEY,
    last_seq   INTEGER NOT NULL DEFAULT 0,
    epoch      INTEGER NOT NULL DEFAULT 1,  -- bumped when the remote rebases
    updated_at TEXT
);

-- ----------------------------------------------------------------------------
-- tombstones: delete markers for Last-Writer-Wins arbitration
--   (an upsert older than the tombstone must not resurrect a deleted record)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tombstones (
    key       TEXT PRIMARY KEY,      -- '<entity>:<entity_id>'
    entity    TEXT,
    entity_id TEXT,
    ts        TEXT,
    device_id TEXT
);
