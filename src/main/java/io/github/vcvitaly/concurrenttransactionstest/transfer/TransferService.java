package io.github.vcvitaly.concurrenttransactionstest.transfer;

import io.github.vcvitaly.concurrenttransactionstest.account.Account;
import io.github.vcvitaly.concurrenttransactionstest.account.AccountService;
import io.github.vcvitaly.concurrenttransactionstest.account.AccountDao;
import io.github.vcvitaly.concurrenttransactionstest.common.NotFoundException;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.List;

@Service
@RequiredArgsConstructor
public class TransferService {

    private final AccountService accountService;
    private final AccountDao accountDao;
    private final TransferDao transferDao;

    /**
     * Naive transfer: read both balances, check, then write back computed values.
     * <p>
     * Intentionally NO locking (no SELECT ... FOR UPDATE, no version column, no app-level
     * synchronization). {@code @Transactional} only makes withdraw + deposit + audit row atomic;
     * under Postgres' default READ COMMITTED isolation concurrent transfers can still read the
     * same stale balance and overwrite each other (lost update), or overdraw an account.
     */
    @Transactional
    public Transfer transfer(TransferRequest request) {
        validate(request);
        long fromId = request.fromAccountId();
        long toId = request.toAccountId();
        BigDecimal amount = request.amount();

        Account from = accountService.get(fromId);
        Account to = accountService.get(toId);

        if (from.balance().compareTo(amount) < 0) {
            throw new InsufficientFundsException(
                    "Account %d has insufficient funds: balance %s, requested %s"
                            .formatted(fromId, from.balance(), amount));
        }

        // withdraw
        accountDao.updateBalance(fromId, from.balance().subtract(amount));
        // deposit
        accountDao.updateBalance(toId, to.balance().add(amount));

        return transferDao.insert(fromId, toId, amount, request.idempotencyKey());
    }

    public Transfer get(long id) {
        return transferDao.findById(id)
                .orElseThrow(() -> new NotFoundException("Transfer %d not found".formatted(id)));
    }

    public List<Transfer> getAll() {
        return transferDao.findAll();
    }

    private static void validate(TransferRequest request) {
        if (request.fromAccountId() == null || request.toAccountId() == null) {
            throw new IllegalArgumentException("fromAccountId and toAccountId are required");
        }
        if (request.fromAccountId().equals(request.toAccountId())) {
            throw new IllegalArgumentException("Cannot transfer to the same account");
        }
        if (request.amount() == null || request.amount().compareTo(BigDecimal.ZERO) <= 0) {
            throw new IllegalArgumentException("amount must be positive");
        }
    }
}
