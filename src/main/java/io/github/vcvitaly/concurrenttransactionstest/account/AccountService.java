package io.github.vcvitaly.concurrenttransactionstest.account;

import io.github.vcvitaly.concurrenttransactionstest.common.NotFoundException;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.util.List;

@Service
@RequiredArgsConstructor
public class AccountService {

    private final AccountDao accountDao;

    public Account create(AccountRequest request) {
        validate(request);
        return accountDao.insert(request.name(), request.balance());
    }

    public Account get(long id) {
        return accountDao.findById(id).orElseThrow(() -> AccountUtil.notFound(id));
    }

    public List<Account> getAll() {
        return accountDao.findAll();
    }

    public Account update(long id, AccountRequest request) {
        validate(request);
        return accountDao.update(id, request.name(), request.balance()).orElseThrow(() -> AccountUtil.notFound(id));
    }

    public void delete(long id) {
        if (!accountDao.deleteById(id)) {
            throw AccountUtil.notFound(id);
        }
    }

    private static void validate(AccountRequest request) {
        if (request.name() == null || request.name().isBlank()) {
            throw new IllegalArgumentException("name must not be blank");
        }
        if (request.balance() == null || request.balance().compareTo(BigDecimal.ZERO) < 0) {
            throw new IllegalArgumentException("balance must be non-negative");
        }
    }
}
