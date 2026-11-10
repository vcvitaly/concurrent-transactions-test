package io.github.vcvitaly.concurrenttransactionstest.transfer;

import java.math.BigDecimal;
import java.time.OffsetDateTime;

public record Transfer(
        long id,
        long fromAccountId,
        long toAccountId,
        BigDecimal amount,
        OffsetDateTime createdAt
) {
}
