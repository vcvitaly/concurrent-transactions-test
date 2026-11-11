package io.github.vcvitaly.concurrenttransactionstest.account;

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
public class AccountDao {

    private static final String COLUMNS = "id, name, balance, version, created_at, updated_at";

    private static final RowMapper<Account> ROW_MAPPER = (rs, _) -> new Account(
            rs.getLong("id"),
            rs.getString("name"),
            rs.getBigDecimal("balance"),
            rs.getLong("version"),
            rs.getObject("created_at", OffsetDateTime.class),
            rs.getObject("updated_at", OffsetDateTime.class)
    );

    private final JdbcClient jdbcClient;

    public Account insert(String name, BigDecimal balance) {
        return jdbcClient.sql("""
                        INSERT INTO accounts (name, balance)
                        VALUES (:name, :balance)
                        RETURNING %s
                        """.formatted(COLUMNS))
                .param("name", name)
                .param("balance", balance)
                .query(ROW_MAPPER)
                .single();
    }

    public Optional<Account> findById(long id) {
        return jdbcClient.sql("SELECT %s FROM accounts WHERE id = :id".formatted(COLUMNS))
                .param("id", id)
                .query(ROW_MAPPER)
                .optional();
    }

    public List<Account> findAll() {
        return jdbcClient.sql("SELECT %s FROM accounts ORDER BY id".formatted(COLUMNS))
                .query(ROW_MAPPER)
                .list();
    }

    public Optional<Account> update(long id, String name, BigDecimal balance) {
        return jdbcClient.sql("""
                        UPDATE accounts
                        SET name = :name, balance = :balance, updated_at = now()
                        WHERE id = :id
                        RETURNING %s
                        """.formatted(COLUMNS))
                .param("id", id)
                .param("name", name)
                .param("balance", balance)
                .query(ROW_MAPPER)
                .optional();
    }

    /**
     * Blindly overwrites the balance with the given value. Callers compute the new value
     * from a previously read balance, which is a classic read-modify-write.
     */
    public void updateBalance(long id, BigDecimal newBalance) {
        jdbcClient.sql("UPDATE accounts SET balance = :balance, updated_at = now() WHERE id = :id")
                .param("id", id)
                .param("balance", newBalance)
                .update();
    }

    public boolean deleteById(long id) {
        return jdbcClient.sql("DELETE FROM accounts WHERE id = :id")
                .param("id", id)
                .update() > 0;
    }
}
