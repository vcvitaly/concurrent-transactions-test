package io.github.vcvitaly.concurrenttransactionstest.transfer;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;

@Repository
@RequiredArgsConstructor
public class TransferDao {

    private static final String COLUMNS = "id, from_account_id, to_account_id, amount, idempotency_key, created_at";

    private static final RowMapper<Transfer> ROW_MAPPER = (rs, _) -> new Transfer(
            rs.getLong("id"),
            rs.getLong("from_account_id"),
            rs.getLong("to_account_id"),
            rs.getBigDecimal("amount"),
            rs.getString("idempotency_key"),
            rs.getObject("created_at", OffsetDateTime.class)
    );

    private final JdbcClient jdbcClient;

    /**
     * Inserts the transfer unless one with the same (from, to, idempotency key) already exists.
     * Returns empty on conflict. Transfers without a key (NULL) never conflict.
     */
    public Optional<Transfer> insertIfAbsent(long fromAccountId, long toAccountId, BigDecimal amount,
                                             String idempotencyKey) {
        return jdbcClient.sql("""
                        INSERT INTO transfers (from_account_id, to_account_id, amount, idempotency_key)
                        VALUES (:from, :to, :amount, :idempotencyKey)
                        ON CONFLICT ON CONSTRAINT uq_transfers_idempotency DO NOTHING
                        RETURNING %s
                        """.formatted(COLUMNS))
                .param("from", fromAccountId)
                .param("to", toAccountId)
                .param("amount", amount)
                .param("idempotencyKey", idempotencyKey)
                .query(ROW_MAPPER)
                .optional();
    }

    public Optional<Transfer> findByIdempotencyKey(long fromAccountId, long toAccountId, String idempotencyKey) {
        return jdbcClient.sql("""
                        SELECT %s FROM transfers
                        WHERE from_account_id = :from AND to_account_id = :to AND idempotency_key = :idempotencyKey
                        """.formatted(COLUMNS))
                .param("from", fromAccountId)
                .param("to", toAccountId)
                .param("idempotencyKey", idempotencyKey)
                .query(ROW_MAPPER)
                .optional();
    }

    public Optional<Transfer> findById(long id) {
        return jdbcClient.sql("SELECT %s FROM transfers WHERE id = :id".formatted(COLUMNS))
                .param("id", id)
                .query(ROW_MAPPER)
                .optional();
    }

    public List<Transfer> findAll() {
        return jdbcClient.sql("SELECT %s FROM transfers ORDER BY id".formatted(COLUMNS))
                .query(ROW_MAPPER)
                .list();
    }
}
