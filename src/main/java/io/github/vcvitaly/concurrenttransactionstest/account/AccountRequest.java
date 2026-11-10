package io.github.vcvitaly.concurrenttransactionstest.account;

import java.math.BigDecimal;

/** Request body for both creating and updating an account. */
public record AccountRequest(String name, BigDecimal balance) {
}
