-- NULLs are distinct in Postgres unique constraints, so transfers without an idempotency key are not affected.
ALTER TABLE transfers
    ADD CONSTRAINT uq_transfers_idempotency UNIQUE (from_account_id, to_account_id, idempotency_key);
