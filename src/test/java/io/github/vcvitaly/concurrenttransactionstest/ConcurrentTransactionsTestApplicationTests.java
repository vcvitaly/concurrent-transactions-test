package io.github.vcvitaly.concurrenttransactionstest;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;

@SpringBootTest
@Import(TestcontainersConfiguration.class)
class ConcurrentTransactionsTestApplicationTests {

    @Test
    void contextLoads() {
    }

}
