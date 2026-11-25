package io.github.vcvitaly.concurrenttransactionstest.transfer;

import com.jayway.jsonpath.JsonPath;
import io.github.vcvitaly.concurrenttransactionstest.TestcontainersConfiguration;
import io.github.vcvitaly.concurrenttransactionstest.transfer.TransferMetrics.Outcome;
import io.micrometer.core.instrument.MeterRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.assertj.MockMvcTester;

import java.util.EnumMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@AutoConfigureMockMvc
@Import(TestcontainersConfiguration.class)
class TransferControllerIT {

    @Autowired
    private MockMvcTester mvc;

    @Autowired
    private MeterRegistry meterRegistry;

    @Test
    void transfersMoneyBetweenAccounts() throws Exception {
        long fromId = createAccount("alice", "100.00");
        long toId = createAccount("bob", "20.00");

        var transfer = mvc.post().uri("/transfers")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                        {"fromAccountId": %d, "toAccountId": %d, "amount": 30.50, "idempotencyKey": "key-1"}
                        """.formatted(fromId, toId))
                .exchange();

        assertThat(transfer).hasStatus(HttpStatus.CREATED);
        assertThat(transfer).bodyJson().extractingPath("$.fromAccountId").isEqualTo((int) fromId);
        assertThat(transfer).bodyJson().extractingPath("$.toAccountId").isEqualTo((int) toId);
        assertThat(transfer).bodyJson().extractingPath("$.amount").isEqualTo(30.50);
        assertThat(transfer).bodyJson().extractingPath("$.idempotencyKey").isEqualTo("key-1");

        assertThat(mvc.get().uri("/accounts/{id}", fromId))
                .hasStatusOk()
                .bodyJson().extractingPath("$.balance").isEqualTo(69.50);
        assertThat(mvc.get().uri("/accounts/{id}", toId))
                .hasStatusOk()
                .bodyJson().extractingPath("$.balance").isEqualTo(50.50);

        Number transferId = JsonPath.read(transfer.getResponse().getContentAsString(), "$.id");
        assertThat(mvc.get().uri("/transfers/{id}", transferId.longValue()))
                .hasStatusOk()
                .bodyJson().extractingPath("$.amount").isEqualTo(30.50);
    }

    @Test
    void returnsOriginalTransferForDuplicateIdempotencyKey() throws Exception {
        long fromId = createAccount("carol", "100.00");
        long toId = createAccount("dave", "0.00");
        String body = """
                {"fromAccountId": %d, "toAccountId": %d, "amount": 10.00, "idempotencyKey": "dup-key"}
                """.formatted(fromId, toId);

        var first = postTransfer(body).exchange();
        assertThat(first).hasStatus(HttpStatus.CREATED);
        Number originalId = JsonPath.read(first.getResponse().getContentAsString(), "$.id");

        var duplicate = postTransfer(body).exchange();
        assertThat(duplicate).hasStatus(HttpStatus.OK);
        assertThat(duplicate).bodyJson().extractingPath("$.id").isEqualTo(originalId);
        assertThat(duplicate).bodyJson().extractingPath("$.amount").isEqualTo(10.00);

        // Money must move only once.
        assertThat(mvc.get().uri("/accounts/{id}", fromId))
                .hasStatusOk()
                .bodyJson().extractingPath("$.balance").isEqualTo(90.00);
        assertThat(mvc.get().uri("/accounts/{id}", toId))
                .hasStatusOk()
                .bodyJson().extractingPath("$.balance").isEqualTo(10.00);
    }

    @Test
    void countsEachOutcomeExactly() throws Exception {
        long fromId = createAccount("erin", "50.00");
        long toId = createAccount("frank", "0.00");
        String body = """
                {"fromAccountId": %d, "toAccountId": %d, "amount": 20.00, "idempotencyKey": "seq-1"}
                """.formatted(fromId, toId);
        Map<Outcome, Double> before = outcomeCounts();

        assertThat(postTransfer(body)).hasStatus(HttpStatus.CREATED);
        assertThat(postTransfer(body)).hasStatus(HttpStatus.OK);
        assertThat(postTransfer(body)).hasStatus(HttpStatus.OK);
        assertThat(postTransfer("""
                {"fromAccountId": %d, "toAccountId": %d, "amount": 999.00, "idempotencyKey": "seq-2"}
                """.formatted(fromId, toId))).hasStatus(HttpStatus.UNPROCESSABLE_CONTENT);
        assertThat(postTransfer("""
                {"fromAccountId": %d, "toAccountId": %d, "amount": 1.00, "idempotencyKey": "seq-3"}
                """.formatted(fromId, Long.MAX_VALUE))).hasStatus(HttpStatus.NOT_FOUND);
        assertThat(postTransfer("""
                {"fromAccountId": %d, "toAccountId": %d, "amount": 1.00, "idempotencyKey": "seq-4"}
                """.formatted(fromId, fromId))).hasStatus(HttpStatus.BAD_REQUEST);

        Map<Outcome, Double> after = outcomeCounts();
        Map<Outcome, Double> expected = new EnumMap<>(Map.of(
                Outcome.CREATED, 1.0,
                Outcome.REPLAYED, 2.0,
                Outcome.INSUFFICIENT_FUNDS, 1.0,
                Outcome.NOT_FOUND, 1.0,
                Outcome.INVALID, 1.0,
                Outcome.ERROR, 0.0));
        for (Outcome outcome : Outcome.values()) {
            assertThat(after.get(outcome) - before.get(outcome)).as(outcome.tag())
                    .isEqualTo(expected.get(outcome));
        }
    }

    private Map<Outcome, Double> outcomeCounts() {
        Map<Outcome, Double> counts = new EnumMap<>(Outcome.class);
        for (Outcome outcome : Outcome.values()) {
            counts.put(outcome, meterRegistry.get(TransferMetrics.TRANSFERS)
                    .tag("outcome", outcome.tag()).counter().count());
        }
        return counts;
    }

    private MockMvcTester.MockMvcRequestBuilder postTransfer(String body) {
        return mvc.post().uri("/transfers")
                .contentType(MediaType.APPLICATION_JSON)
                .content(body);
    }

    private long createAccount(String name, String balance) throws Exception {
        var result = mvc.post().uri("/accounts")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                        {"name": "%s", "balance": %s}
                        """.formatted(name, balance))
                .exchange();
        assertThat(result).hasStatus(HttpStatus.CREATED);
        Number id = JsonPath.read(result.getResponse().getContentAsString(), "$.id");
        return id.longValue();
    }
}
