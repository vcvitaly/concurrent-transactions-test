package io.github.vcvitaly.concurrenttransactionstest.transfer;

import com.jayway.jsonpath.JsonPath;
import io.github.vcvitaly.concurrenttransactionstest.TestcontainersConfiguration;
import io.github.vcvitaly.concurrenttransactionstest.transfer.TransferMetrics.Outcome;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.micrometer.metrics.test.autoconfigure.AutoConfigureMetrics;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.net.http.HttpResponse;
import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

import static io.github.vcvitaly.concurrenttransactionstest.HttpTestSupport.get;
import static io.github.vcvitaly.concurrenttransactionstest.HttpTestSupport.postJson;
import static org.assertj.core.api.Assertions.assertThat;

/** Transfer metrics over real HTTP, with the Prometheus registry and the management port enabled. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = "management.server.port=0")
@AutoConfigureMetrics
@Import(TestcontainersConfiguration.class)
class TransferMetricsIT {

    private static final Pattern LABEL_KEY = Pattern.compile("(\\w+)=\"");
    private static final Set<String> TRANSFER_METRIC_PREFIXES =
            Set.of("transfers_", "transfer_duration_", "transfer_lock_query_", "transfer_db_errors_");

    @LocalServerPort
    private int apiPort;

    @LocalManagementPort
    private int managementPort;

    @Autowired
    private MeterRegistry registry;

    @Autowired
    private JdbcClient jdbc;

    @Autowired
    private TransactionTemplate tx;

    @Test
    void unparseableBodiesAreNotCounted() throws InterruptedException {
        double transfersBefore = totalTransfers();
        long httpBefore = httpRequests("/transfers", "400");

        assertThat(postJson(apiPort, "/transfers", "{not json").statusCode()).isEqualTo(400);
        assertThat(postJson(apiPort, "/transfers", "").statusCode()).isEqualTo(400);

        assertThat(totalTransfers()).isEqualTo(transfersBefore);
        // The observation is stopped after the response is written, so give it a moment.
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (httpRequests("/transfers", "400") < httpBefore + 2 && System.nanoTime() < deadline) {
            Thread.sleep(20);
        }
        assertThat(httpRequests("/transfers", "400")).isEqualTo(httpBefore + 2);
    }

    @Test
    void commitTimeFailureCountsAsError() {
        long fromId = createAccount("100.00");
        long toId = createAccount("0.00");
        jdbc.sql("""
                CREATE OR REPLACE FUNCTION reject_marker_amount() RETURNS trigger AS $$
                BEGIN
                    IF NEW.amount = 13.37 THEN
                        RAISE EXCEPTION 'marker amount rejected at commit';
                    END IF;
                    RETURN NEW;
                END
                $$ LANGUAGE plpgsql
                """).update();
        jdbc.sql("""
                CREATE CONSTRAINT TRIGGER reject_marker_amount AFTER INSERT ON transfers
                DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_marker_amount()
                """).update();
        try {
            double createdBefore = outcome(Outcome.CREATED);
            double errorBefore = outcome(Outcome.ERROR);

            int status = postJson(apiPort, "/transfers", transferBody(fromId, toId, "13.37", "commit-fail"))
                    .statusCode();

            assertThat(status).isBetween(500, 599);
            assertThat(outcome(Outcome.ERROR)).isEqualTo(errorBefore + 1);
            assertThat(outcome(Outcome.CREATED)).isEqualTo(createdBefore);
            assertThat(balance(fromId)).isEqualByComparingTo("100.00");
            assertThat(balance(toId)).isEqualByComparingTo("0.00");
        } finally {
            jdbc.sql("DROP TRIGGER IF EXISTS reject_marker_amount ON transfers").update();
            jdbc.sql("DROP FUNCTION IF EXISTS reject_marker_amount()").update();
        }
    }

    @Test
    void lockQueryTimeIncludesRowLockWait() throws Exception {
        long fromId = createAccount("100.00");
        long toId = createAccount("0.00");
        Timer timer = registry.get(TransferMetrics.LOCK_QUERY).timer();

        // Uncontended baseline.
        long baselineCount = timer.count();
        double baselineTotal = timer.totalTime(TimeUnit.MILLISECONDS);
        for (int i = 0; i < 5; i++) {
            assertThat(postJson(apiPort, "/transfers", transferBody(fromId, toId, "1.00", "base-" + i))
                    .statusCode()).isEqualTo(201);
        }
        assertThat(timer.count()).isEqualTo(baselineCount + 5);
        double baselineMean = (timer.totalTime(TimeUnit.MILLISECONDS) - baselineTotal) / 5;

        // Another transaction holds the receiver's row lock for about 300ms.
        CountDownLatch locked = new CountDownLatch(1);
        CompletableFuture<Void> holder = CompletableFuture.runAsync(() -> tx.executeWithoutResult(_ -> {
            jdbc.sql("SELECT id FROM accounts WHERE id = :id FOR UPDATE").param("id", toId).query(Long.class).single();
            locked.countDown();
            try {
                Thread.sleep(300);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }));
        assertThat(locked.await(5, TimeUnit.SECONDS)).isTrue();
        long contendedCount = timer.count();
        double contendedTotal = timer.totalTime(TimeUnit.MILLISECONDS);
        assertThat(postJson(apiPort, "/transfers", transferBody(fromId, toId, "1.00", "contended"))
                .statusCode()).isEqualTo(201);
        holder.get(5, TimeUnit.SECONDS);

        assertThat(timer.count()).isEqualTo(contendedCount + 1);
        double contended = timer.totalTime(TimeUnit.MILLISECONDS) - contendedTotal;
        assertThat(contended).isGreaterThanOrEqualTo(250);
        assertThat(baselineMean).isLessThan(contended / 5);

        // A failing lock query (unknown account) is still timed.
        long notFoundCount = timer.count();
        assertThat(postJson(apiPort, "/transfers", transferBody(fromId, Long.MAX_VALUE, "1.00", "nf"))
                .statusCode()).isEqualTo(404);
        assertThat(timer.count()).isEqualTo(notFoundCount + 1);
    }

    @Test
    void onlyTransferTimersHaveHistogramBuckets() {
        long fromId = createAccount("10.00");
        long toId = createAccount("0.00");
        assertThat(postJson(apiPort, "/transfers", transferBody(fromId, toId, "1.00", "hist"))
                .statusCode()).isEqualTo(201);

        List<String> bucketNames = samples(scrape()).stream()
                .map(TransferMetricsIT::metricName)
                .filter(name -> name.endsWith("_bucket"))
                .distinct()
                .toList();

        assertThat(bucketNames).containsExactlyInAnyOrder(
                "transfer_duration_seconds_bucket", "transfer_lock_query_seconds_bucket");
    }

    @Test
    void transferSeriesDoNotGrowWithAccountsOrKeys() {
        makeTransfersBetweenNewPairs(3);
        List<String> first = transferSeries(scrape());

        makeTransfersBetweenNewPairs(6);
        String scrape = scrape();
        List<String> second = transferSeries(scrape);

        assertThat(second).hasSameSizeAs(first);
        Set<String> labelKeys = second.stream()
                .flatMap(series -> LABEL_KEY.matcher(series).results())
                .map(m -> m.group(1))
                .collect(Collectors.toSet());
        assertThat(labelKeys).isSubsetOf("outcome", "le", "sqlstate");
    }

    private void makeTransfersBetweenNewPairs(int pairs) {
        for (int i = 0; i < pairs; i++) {
            long fromId = createAccount("10.00");
            long toId = createAccount("0.00");
            assertThat(postJson(apiPort, "/transfers",
                    transferBody(fromId, toId, "1.%02d".formatted(i), UUID.randomUUID().toString()))
                    .statusCode()).isEqualTo(201);
        }
    }

    private String scrape() {
        HttpResponse<String> response = get(managementPort, "/actuator/prometheus");
        assertThat(response.statusCode()).isEqualTo(200);
        return response.body();
    }

    private static List<String> samples(String scrape) {
        return scrape.lines().filter(line -> !line.isBlank() && !line.startsWith("#")).toList();
    }

    private static List<String> transferSeries(String scrape) {
        return samples(scrape).stream()
                .filter(line -> TRANSFER_METRIC_PREFIXES.stream().anyMatch(line::startsWith))
                .map(line -> line.substring(0, line.lastIndexOf(' ')))
                .toList();
    }

    private static String metricName(String sample) {
        Matcher m = Pattern.compile("^[a-zA-Z_:][a-zA-Z0-9_:]*").matcher(sample);
        return m.find() ? m.group() : sample;
    }

    private double outcome(Outcome outcome) {
        return registry.get(TransferMetrics.TRANSFERS).tag("outcome", outcome.tag()).counter().count();
    }

    private double totalTransfers() {
        return Arrays.stream(Outcome.values()).mapToDouble(this::outcome).sum();
    }

    private long httpRequests(String uri, String status) {
        return registry.find("http.server.requests").tag("uri", uri).tag("status", status).timers().stream()
                .mapToLong(Timer::count)
                .sum();
    }

    private long createAccount(String balance) {
        HttpResponse<String> response = postJson(apiPort, "/accounts", """
                {"name": "acct-%s", "balance": %s}
                """.formatted(UUID.randomUUID(), balance));
        assertThat(response.statusCode()).isEqualTo(201);
        Number id = JsonPath.read(response.body(), "$.id");
        return id.longValue();
    }

    private BigDecimal balance(long accountId) {
        HttpResponse<String> response = get(apiPort, "/accounts/" + accountId);
        assertThat(response.statusCode()).isEqualTo(200);
        return new BigDecimal(JsonPath.read(response.body(), "$.balance").toString());
    }

    private static String transferBody(long fromId, long toId, String amount, String key) {
        return """
                {"fromAccountId": %d, "toAccountId": %d, "amount": %s, "idempotencyKey": "%s"}
                """.formatted(fromId, toId, amount, key);
    }
}
