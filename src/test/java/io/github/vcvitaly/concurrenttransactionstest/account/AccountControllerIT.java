package io.github.vcvitaly.concurrenttransactionstest.account;

import io.github.vcvitaly.concurrenttransactionstest.TestcontainersConfiguration;
import com.jayway.jsonpath.JsonPath;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.assertj.MockMvcTester;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest
@AutoConfigureMockMvc
@Import(TestcontainersConfiguration.class)
class AccountControllerIT {

    @Autowired
    private MockMvcTester mvc;

    @Test
    void createsAccountAndReadsItBack() throws Exception {
        var created = mvc.post().uri("/accounts")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                        {"name": "alice", "balance": 100.50}
                        """)
                .exchange();

        assertThat(created).hasStatus(HttpStatus.CREATED);
        assertThat(created).bodyJson().extractingPath("$.name").isEqualTo("alice");
        assertThat(created).bodyJson().extractingPath("$.balance").isEqualTo(100.50);
        assertThat(created).bodyJson().extractingPath("$.version").isEqualTo(0);
        assertThat(created).bodyJson().extractingPath("$.createdAt").isNotNull();
        assertThat(created).bodyJson().extractingPath("$.updatedAt").isNotNull();

        Number id = JsonPath.read(created.getResponse().getContentAsString(), "$.id");

        assertThat(mvc.get().uri("/accounts/{id}", id.longValue()))
                .hasStatusOk()
                .bodyJson().extractingPath("$.name").isEqualTo("alice");
    }
}
