CREATE TABLE IF NOT EXISTS accounts
(
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       VARCHAR(255)   NOT NULL,
    balance    NUMERIC(19, 2) NOT NULL,
    created_at TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ    NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS transfers
(
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_account_id BIGINT         NOT NULL REFERENCES accounts (id),
    to_account_id   BIGINT         NOT NULL REFERENCES accounts (id),
    amount          NUMERIC(19, 2) NOT NULL,
    created_at      TIMESTAMPTZ    NOT NULL DEFAULT now()
);
