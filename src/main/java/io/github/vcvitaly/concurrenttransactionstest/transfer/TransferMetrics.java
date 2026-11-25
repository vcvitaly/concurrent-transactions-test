package io.github.vcvitaly.concurrenttransactionstest.transfer;

import io.github.vcvitaly.concurrenttransactionstest.common.NotFoundException;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.dao.DataAccessException;
import org.springframework.stereotype.Component;
import org.springframework.transaction.TransactionException;

import java.sql.SQLException;
import java.util.EnumMap;
import java.util.Map;
import java.util.Optional;

/**
 * Owns the transfer meters. Tags never carry per-request values (accounts, amounts, keys), only the
 * outcome and the SQLSTATE, so the number of series stays fixed.
 * <p>
 * Outcomes are recorded by the caller of the transactional {@link TransferService}, so a transfer is
 * counted only after its transaction has committed or rolled back.
 */
@Component
public class TransferMetrics {

    static final String TRANSFERS = "transfers";
    static final String DURATION = "transfer.duration";
    static final String LOCK_QUERY = "transfer.lock.query";
    static final String DB_ERRORS = "transfer.db.errors";
    static final String UNKNOWN_SQLSTATE = "unknown";

    public enum Outcome {
        CREATED, REPLAYED, INSUFFICIENT_FUNDS, NOT_FOUND, INVALID, ERROR;

        public String tag() {
            return name().toLowerCase();
        }
    }

    private final MeterRegistry registry;
    private final Map<Outcome, Counter> counters = new EnumMap<>(Outcome.class);
    private final Map<Outcome, Timer> timers = new EnumMap<>(Outcome.class);
    private final Timer lockQueryTimer;

    public TransferMetrics(MeterRegistry registry) {
        this.registry = registry;
        // Registered up front, so every outcome has a series from the first scrape and rate() works
        // on the first event.
        for (Outcome outcome : Outcome.values()) {
            counters.put(outcome, Counter.builder(TRANSFERS)
                    .description("Transfer requests that reached transfer processing, by outcome")
                    .tag("outcome", outcome.tag())
                    .register(registry));
            timers.put(outcome, Timer.builder(DURATION)
                    .description("Transfer processing time including the commit, by outcome")
                    .tag("outcome", outcome.tag())
                    .register(registry));
        }
        lockQueryTimer = Timer.builder(LOCK_QUERY)
                .description("Round trip of the SELECT ... FOR UPDATE on both accounts, including any "
                        + "wait for row locks")
                .register(registry);
    }

    public Timer.Sample start() {
        return Timer.start(registry);
    }

    public void recordSuccess(Timer.Sample sample, TransferResult result) {
        record(sample, outcomeOf(result));
    }

    public void recordFailure(Timer.Sample sample, Throwable failure) {
        record(sample, outcomeOf(failure));
        sqlStateOf(failure).ifPresent(sqlState -> Counter.builder(DB_ERRORS)
                .description("Transfers that failed with a database error, by PostgreSQL SQLSTATE")
                .tag("sqlstate", sqlState)
                .register(registry)
                .increment());
    }

    public Timer lockQueryTimer() {
        return lockQueryTimer;
    }

    private void record(Timer.Sample sample, Outcome outcome) {
        sample.stop(timers.get(outcome));
        counters.get(outcome).increment();
    }

    static Outcome outcomeOf(TransferResult result) {
        return result.created() ? Outcome.CREATED : Outcome.REPLAYED;
    }

    static Outcome outcomeOf(Throwable failure) {
        return switch (failure) {
            case InsufficientFundsException _ -> Outcome.INSUFFICIENT_FUNDS;
            case NotFoundException _ -> Outcome.NOT_FOUND;
            case IllegalArgumentException _ -> Outcome.INVALID;
            default -> Outcome.ERROR;
        };
    }

    /**
     * The SQLSTATE of the innermost {@link SQLException} in the cause chain, {@code unknown} for a
     * database failure without one, or empty when the failure didn't come from the database.
     */
    static Optional<String> sqlStateOf(Throwable failure) {
        boolean database = false;
        String sqlState = null;
        for (Throwable t = failure; t != null; t = t.getCause() == t ? null : t.getCause()) {
            if (t instanceof DataAccessException || t instanceof TransactionException) {
                database = true;
            }
            if (t instanceof SQLException sqlException) {
                database = true;
                if (sqlException.getSQLState() != null) {
                    sqlState = sqlException.getSQLState();
                }
            }
        }
        if (!database) {
            return Optional.empty();
        }
        return Optional.of(sqlState != null ? sqlState : UNKNOWN_SQLSTATE);
    }
}
