package io.github.vcvitaly.concurrenttransactionstest.transfer;

import io.github.vcvitaly.concurrenttransactionstest.common.NotFoundException;
import io.github.vcvitaly.concurrenttransactionstest.transfer.TransferMetrics.Outcome;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MockClock;
import io.micrometer.core.instrument.Timer;
import io.micrometer.core.instrument.simple.SimpleConfig;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.dao.CannotAcquireLockException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.dao.QueryTimeoutException;
import org.springframework.jdbc.UncategorizedSQLException;

import java.math.BigDecimal;
import java.sql.SQLException;
import java.time.Duration;
import java.util.Arrays;
import java.util.concurrent.TimeUnit;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

class TransferMetricsTest {

    private MockClock clock;
    private SimpleMeterRegistry registry;
    private TransferMetrics metrics;

    @BeforeEach
    void setUp() {
        clock = new MockClock();
        registry = new SimpleMeterRegistry(SimpleConfig.DEFAULT, clock);
        metrics = new TransferMetrics(registry);
    }

    @Test
    void registersEveryOutcomeUpFront() {
        for (Outcome outcome : Outcome.values()) {
            assertThat(counter(outcome)).isNotNull();
            assertThat(timer(outcome)).isNotNull();
        }
        assertThat(registry.find(TransferMetrics.LOCK_QUERY).timer()).isNotNull();
    }

    @Test
    void createdResult() {
        Timer.Sample sample = metrics.start();
        clock.add(Duration.ofMillis(40));
        metrics.recordSuccess(sample, result(true));

        assertOnlyOutcome(Outcome.CREATED);
        assertThat(timer(Outcome.CREATED).totalTime(TimeUnit.MILLISECONDS)).isEqualTo(40);
    }

    @Test
    void replayedResult() {
        metrics.recordSuccess(metrics.start(), result(false));

        assertOnlyOutcome(Outcome.REPLAYED);
    }

    static Stream<Arguments> failures() {
        return Stream.of(
                Arguments.of(new InsufficientFundsException("low"), Outcome.INSUFFICIENT_FUNDS),
                Arguments.of(new NotFoundException("missing"), Outcome.NOT_FOUND),
                Arguments.of(new IllegalArgumentException("bad"), Outcome.INVALID),
                Arguments.of(new IllegalStateException("boom"), Outcome.ERROR),
                Arguments.of(dbFailure("40P01"), Outcome.ERROR)
        );
    }

    @ParameterizedTest
    @MethodSource("failures")
    void failureOutcomes(RuntimeException failure, Outcome expected) {
        Timer.Sample sample = metrics.start();
        clock.add(Duration.ofMillis(7));
        metrics.recordFailure(sample, failure);

        assertOnlyOutcome(expected);
        assertThat(timer(expected).totalTime(TimeUnit.MILLISECONDS)).isEqualTo(7);
    }

    @ParameterizedTest
    @MethodSource("sqlStates")
    void countsDatabaseErrorsBySqlState(RuntimeException failure, String sqlState) {
        metrics.recordFailure(metrics.start(), failure);

        assertThat(registry.find(TransferMetrics.DB_ERRORS).counters()).hasSize(1);
        assertThat(registry.get(TransferMetrics.DB_ERRORS).tag("sqlstate", sqlState).counter().count())
                .isEqualTo(1);
    }

    static Stream<Arguments> sqlStates() {
        return Stream.of(
                Arguments.of(new CannotAcquireLockException("deadlock", sqlException("40P01")), "40P01"),
                Arguments.of(new UncategorizedSQLException("commit", "COMMIT", sqlException("40001")), "40001"),
                Arguments.of(new DataIntegrityViolationException("dup", sqlException("23505")), "23505"),
                // A database exception with no SQLException in its chain.
                Arguments.of(new QueryTimeoutException("timeout"), "unknown")
        );
    }

    @Test
    void usesInnermostSqlState() {
        SQLException inner = sqlException("40P01");
        SQLException outer = new SQLException("outer", "08006", inner);
        metrics.recordFailure(metrics.start(), new UncategorizedSQLException("x", "SELECT", outer));

        assertThat(registry.get(TransferMetrics.DB_ERRORS).tag("sqlstate", "40P01").counter().count())
                .isEqualTo(1);
    }

    @ParameterizedTest
    @MethodSource("businessFailures")
    void businessFailuresAreNotDatabaseErrors(RuntimeException failure) {
        metrics.recordFailure(metrics.start(), failure);

        assertThat(registry.find(TransferMetrics.DB_ERRORS).counters()).isEmpty();
    }

    static Stream<RuntimeException> businessFailures() {
        return Stream.of(
                new InsufficientFundsException("low"),
                new NotFoundException("missing"),
                new IllegalArgumentException("bad"),
                new IllegalStateException("not a database error")
        );
    }

    private void assertOnlyOutcome(Outcome expected) {
        Arrays.stream(Outcome.values()).forEach(outcome -> {
            double want = outcome == expected ? 1 : 0;
            assertThat(counter(outcome).count()).as(outcome.tag()).isEqualTo(want);
            assertThat(timer(outcome).count()).as(outcome.tag()).isEqualTo((long) want);
        });
    }

    private Counter counter(Outcome outcome) {
        return registry.get(TransferMetrics.TRANSFERS).tag("outcome", outcome.tag()).counter();
    }

    private Timer timer(Outcome outcome) {
        return registry.get(TransferMetrics.DURATION).tag("outcome", outcome.tag()).timer();
    }

    private static TransferResult result(boolean created) {
        return new TransferResult(new Transfer(1, 1, 2, BigDecimal.ONE, "k", null), created);
    }

    private static SQLException sqlException(String sqlState) {
        return new SQLException("database error", sqlState);
    }

    private static RuntimeException dbFailure(String sqlState) {
        return new CannotAcquireLockException("db", sqlException(sqlState));
    }
}
