package io.github.vcvitaly.concurrenttransactionstest.common;

public class NotFoundException extends RuntimeException {

    public NotFoundException(String message) {
        super(message);
    }
}
