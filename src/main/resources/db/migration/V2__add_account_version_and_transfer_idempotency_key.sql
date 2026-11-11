ALTER TABLE accounts
    ADD COLUMN version BIGINT NOT NULL DEFAULT 0;

-- Nullable: existing transfers have no key. No unique constraint yet - deduplication comes later.
ALTER TABLE transfers
    ADD COLUMN idempotency_key VARCHAR(255);
