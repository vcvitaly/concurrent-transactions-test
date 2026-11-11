package io.github.vcvitaly.concurrenttransactionstest.transfer;

/**
 * @param transfer the transfer that was created, or the original one for a repeated idempotency key
 * @param created  {@code false} when the request was a duplicate and no money was moved
 */
public record TransferResult(Transfer transfer, boolean created) {
}
