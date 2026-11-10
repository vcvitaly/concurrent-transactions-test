package io.github.vcvitaly.concurrenttransactionstest.transfer;

public class InsufficientFundsException extends RuntimeException {

    public InsufficientFundsException(String message) {
        super(message);
    }
}
