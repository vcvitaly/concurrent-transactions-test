package io.github.vcvitaly.concurrenttransactionstest;

import com.jayway.jsonpath.JsonPath;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.availability.AvailabilityChangeEvent;
import org.springframework.boot.availability.ReadinessState;
import org.springframework.boot.micrometer.metrics.test.autoconfigure.AutoConfigureMetrics;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.ApplicationContext;
import org.springframework.context.annotation.Import;

import java.net.http.HttpResponse;
import java.util.Map;

import static io.github.vcvitaly.concurrenttransactionstest.HttpTestSupport.get;
import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = "management.server.port=0")
@AutoConfigureMetrics
@Import(TestcontainersConfiguration.class)
class ManagementEndpointsIT {

    @LocalServerPort
    private int apiPort;

    @LocalManagementPort
    private int managementPort;

    @Autowired
    private ApplicationContext context;

    @Test
    void prometheusIsServedOnManagementPortOnly() {
        HttpResponse<String> scrape = get(managementPort, "/actuator/prometheus");
        assertThat(scrape.statusCode()).isEqualTo(200);
        assertThat(scrape.headers().firstValue("Content-Type")).hasValueSatisfying(
                type -> assertThat(type).startsWith("text/plain"));
        assertThat(scrape.body()).contains("# TYPE jvm_memory_used_bytes gauge");

        assertThat(apiPort).isNotEqualTo(managementPort);
        assertThat(get(apiPort, "/actuator/prometheus").statusCode()).isEqualTo(404);
        assertThat(get(apiPort, "/actuator/health").statusCode()).isEqualTo(404);
        assertThat(get(apiPort, "/actuator").statusCode()).isEqualTo(404);
    }

    @Test
    void probePathsOnApiPortReturnBareStatus() {
        for (String path : new String[]{"/livez", "/readyz"}) {
            HttpResponse<String> response = get(apiPort, path);
            assertThat(response.statusCode()).as(path).isEqualTo(200);
            Map<String, Object> body = JsonPath.read(response.body(), "$");
            assertThat(body).as(path).containsOnlyKeys("status");
            assertThat(body.get("status")).isEqualTo("UP");
        }
    }

    @Test
    void detailedHealthIsServedOnManagementPortOnly() {
        HttpResponse<String> health = get(managementPort, "/actuator/health");
        assertThat(health.statusCode()).isEqualTo(200);
        Map<String, Object> components = JsonPath.read(health.body(), "$.components");
        assertThat(components).containsKeys("db", "livenessState", "readinessState");
        assertThat((Object) JsonPath.read(health.body(), "$.components.db.details.database"))
                .isEqualTo("PostgreSQL");
    }

    @Test
    void readinessFailsWhenRefusingTraffic() {
        try {
            // Graceful shutdown publishes this event before it stops accepting requests.
            AvailabilityChangeEvent.publish(context, ReadinessState.REFUSING_TRAFFIC);

            HttpResponse<String> readiness = get(apiPort, "/readyz");
            assertThat(readiness.statusCode()).isEqualTo(503);
            assertThat((String) JsonPath.read(readiness.body(), "$.status")).isEqualTo("OUT_OF_SERVICE");
            assertThat(get(apiPort, "/livez").statusCode()).isEqualTo(200);
        } finally {
            AvailabilityChangeEvent.publish(context, ReadinessState.ACCEPTING_TRAFFIC);
        }
        assertThat(get(apiPort, "/readyz").statusCode()).isEqualTo(200);
    }
}
