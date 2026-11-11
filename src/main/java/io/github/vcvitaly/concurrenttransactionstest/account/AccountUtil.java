package io.github.vcvitaly.concurrenttransactionstest.account;

import io.github.vcvitaly.concurrenttransactionstest.common.NotFoundException;
import lombok.experimental.UtilityClass;

@UtilityClass
public class AccountUtil {

    public static NotFoundException notFound(long id) {
        return new NotFoundException("Account %d not found".formatted(id));
    }
}
