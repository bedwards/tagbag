-- tagbag coordination layer schema
-- Migration 001: initial tables

BEGIN;

CREATE TABLE IF NOT EXISTS webhook_events (
    id          SERIAL PRIMARY KEY,
    event_type  TEXT NOT NULL,
    repo        TEXT NOT NULL,
    payload_hash TEXT NOT NULL,
    processed_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cross_links (
    id           SERIAL PRIMARY KEY,
    source_type  TEXT NOT NULL CHECK (source_type IN ('commit', 'pr', 'branch')),  -- commit, pr, branch
    source_id    TEXT NOT NULL,
    source_repo  TEXT NOT NULL,
    target_type  TEXT NOT NULL CHECK (target_type IN ('work_item')),  -- work_item
    target_id    TEXT NOT NULL,
    target_project TEXT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS activity_log (
    id           SERIAL PRIMARY KEY,
    event_type   TEXT NOT NULL,
    repo         TEXT NOT NULL,
    ref          TEXT,
    actor        TEXT,
    summary      TEXT,
    identifier   TEXT,
    details_json JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE UNIQUE INDEX IF NOT EXISTS idx_webhook_events_repo_hash ON webhook_events (repo, payload_hash);
CREATE UNIQUE INDEX IF NOT EXISTS idx_cross_links_source_target ON cross_links (source_type, source_id, source_repo, target_id);
CREATE INDEX IF NOT EXISTS idx_cross_links_target_id    ON cross_links (target_id);
CREATE INDEX IF NOT EXISTS idx_activity_log_created_at  ON activity_log (created_at);
CREATE INDEX IF NOT EXISTS idx_activity_log_identifier  ON activity_log (identifier);

COMMIT;
