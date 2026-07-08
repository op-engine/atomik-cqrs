-- atomik-cqrs schema — Postgres 17 (minimum: 15)
-- Apply with: psql $ATOMIK_DATABASE_URL < init.sql

CREATE TABLE IF NOT EXISTS events (
  global_seq BIGSERIAL NOT NULL,
  id VARCHAR(32) PRIMARY KEY,
  tenant_id VARCHAR(32) NOT NULL,
  aggregate_id VARCHAR(32) NOT NULL,
  aggregate_type VARCHAR(128) NOT NULL,
  event_type VARCHAR(128) NOT NULL,
  event_data JSONB NOT NULL,
  event_metadata JSONB,
  version INT NOT NULL,
  timestamp BIGINT NOT NULL,
  created_by VARCHAR(32) NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_aggregate ON events(tenant_id, aggregate_id, version ASC);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(tenant_id, aggregate_type, event_type, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_events_global_seq ON events(global_seq ASC);

CREATE TABLE IF NOT EXISTS idempotency_keys (
  tenant_id VARCHAR(32) NOT NULL,
  idempotency_key VARCHAR(256) NOT NULL,
  command_type VARCHAR(128) NOT NULL,
  result JSONB NOT NULL,
  created_at BIGINT NOT NULL,
  PRIMARY KEY (tenant_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS audit_logs (
  id VARCHAR(32) PRIMARY KEY,
  tenant_id VARCHAR(32) NOT NULL,
  event_type VARCHAR(128) NOT NULL,
  user_id VARCHAR(32) NOT NULL,
  ip_address VARCHAR(64),
  user_agent VARCHAR(256),
  timestamp BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_tenant ON audit_logs(tenant_id, timestamp DESC);

CREATE TABLE IF NOT EXISTS projection_checkpoints (
  name VARCHAR(256) PRIMARY KEY,
  position BIGINT NOT NULL DEFAULT 0,
  updated_at BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS snapshots (
  id BIGSERIAL PRIMARY KEY,
  tenant_id VARCHAR(32) NOT NULL,
  aggregate_id VARCHAR(32) NOT NULL,
  aggregate_type VARCHAR(128) NOT NULL,
  version INT NOT NULL,
  state JSONB NOT NULL,
  created_at BIGINT NOT NULL,
  UNIQUE (tenant_id, aggregate_id)
);
