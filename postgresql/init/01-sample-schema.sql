-- Runs once on first start of l1 (docker-entrypoint-initdb.d).
CREATE TABLE IF NOT EXISTS events (
    id         bigserial PRIMARY KEY,
    kind       text        NOT NULL,
    payload    jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS events_kind_created_idx ON events (kind, created_at DESC);
