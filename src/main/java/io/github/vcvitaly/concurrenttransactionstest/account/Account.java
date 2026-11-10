package io.github.vcvitaly.concurrenttransactionstest.account;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

public record Account(
        long id,
        String name,
        BigDecimal balance,
        OffsetDateTime createdAt,
        OffsetDateTime updatedAt
) {
}
