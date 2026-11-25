package io.github.vcvitaly.concurrenttransactionstest;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Import;
import org.springframework.test.annotation.DirtiesContext;
import org.testcontainers.postgresql.PostgreSQLContainer;

import static io.github.vcvitaly.concurrenttransactionstest.HttpTestSupport.get;
import static io.github.vcvitaly.concurrenttransactionstest.HttpTestSupport.postJson;
import static org.assertj.core.api.Assertions.assertThat;

/** Stops this test's own Postgres container, so the context is discarded afterwards. */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {
                "management.server.port=0",
                // Fail fast instead of waiting the default 30s for a connection.
                "spring.datasource.hikari.connection-timeout=2000"
        })
@Import(TestcontainersConfiguration.class)
@DirtiesContext
class DatabaseOutageIT {

    @LocalServerPort
    private int apiPort;

    @Autowired
    private PostgreSQLContainer postgres;

    @Test
    void probesStayUpAndTransfersFailWhenDatabaseIsDown() {
        assertThat(get(apiPort, "/readyz").statusCode()).isEqualTo(200);

        postgres.stop();

        assertThat(get(apiPort, "/readyz").statusCode()).isEqualTo(200);
        assertThat(get(apiPort, "/livez").statusCode()).isEqualTo(200);
        int status = postJson(apiPort, "/transfers", """
                {"fromAccountId": 1, "toAccountId": 2, "amount": 1.00, "idempotencyKey": "outage"}
                """).statusCode();
        assertThat(status).isBetween(500, 599);
    }
}
