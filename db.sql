-- Schema for the ETL demo. Idempotent: safe to re-run.

-- The read model. revenue is NUMERIC(20,4): the 2024 INT column overflowed on
-- large updates, and revenue is money-shaped, not counter-shaped.
CREATE TABLE IF NOT EXISTS users_revenue (
    user_id TEXT PRIMARY KEY,
    revenue NUMERIC(20,4) NOT NULL DEFAULT 0
);

-- Per-partition byte offset, advanced in the SAME transaction as the revenue
-- writes: a crash can neither lose events (offset ahead of the writes) nor
-- replay them (writes ahead of the offset).
CREATE TABLE IF NOT EXISTS processor_offsets (
    partition TEXT PRIMARY KEY,
    byte_offset BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Idempotency keys: a retried or re-sent event id is applied exactly once.
CREATE TABLE IF NOT EXISTS applied_events (
    event_id TEXT PRIMARY KEY,
    partition TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
