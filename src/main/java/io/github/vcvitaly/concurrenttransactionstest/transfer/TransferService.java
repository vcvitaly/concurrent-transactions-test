package io.github.vcvitaly.concurrenttransactionstest.transfer;

import io.github.vcvitaly.concurrenttransactionstest.account.Account;
import io.github.vcvitaly.concurrenttransactionstest.account.AccountService;
import io.github.vcvitaly.concurrenttransactionstest.account.AccountDao;
import io.github.vcvitaly.concurrenttransactionstest.account.AccountUtil;
import io.github.vcvitaly.concurrenttransactionstest.common.NotFoundException;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.util.*;
import java.util.function.Function;
import java.util.stream.Collectors;

import static java.util.function.Predicate.not;

@Service
@RequiredArgsConstructor
public class TransferService {

    private final AccountDao accountDao;
    private final TransferDao transferDao;

    /**
     * Naive transfer: read both balances, check, then write back computed values.
     * <p>
     * Idempotency: the transfer row is inserted first with ON CONFLICT DO NOTHING. If a transfer with
     * the same (from, to, idempotency key) already exists, the original is returned and no money moves.
     * A concurrent duplicate blocks on the unique index until the first transaction finishes, so only
     * one of them ever moves money.
     */
    @Transactional(isolation = Isolation.SERIALIZABLE)
    public TransferResult transfer(TransferRequest request) {
        validate(request);
        long fromId = request.fromAccountId();
        long toId = request.toAccountId();
        BigDecimal amount = request.amount();
        String idempotencyKey = request.idempotencyKey();

        SequencedMap<Long, Account> accountById = forTransfer(Set.of(fromId, toId));
        Account from = accountById.get(fromId);
        Account to = accountById.get(toId);

        Optional<Transfer> inserted = transferDao.insertIfAbsent(fromId, toId, amount, idempotencyKey);
        if (inserted.isEmpty()) {
            Transfer original = transferDao.findByIdempotencyKey(fromId, toId, idempotencyKey)
                    .orElseThrow(() -> new IllegalStateException(
                            "Idempotency conflict but no transfer found for key " + idempotencyKey));
            return new TransferResult(original, false);
        }

        // Insufficient funds throws and rolls back the transfer row inserted above.
        if (from.balance().compareTo(amount) < 0) {
            throw new InsufficientFundsException(
                    "Account %d has insufficient funds: balance %s, requested %s"
                            .formatted(fromId, from.balance(), amount));
        }

        // withdraw
        if (accountDao.withdraw(fromId, amount) != 1) {
            throw new IllegalStateException(
                    "%d has has insufficient balance after internal verification: requested %s".formatted(fromId, amount)
            );
        }
        // deposit
        accountDao.deposit(toId, amount);

        return new TransferResult(inserted.get(), true);
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

    private SequencedMap<Long, Account> forTransfer(Set<Long> accountIdPair) {
        if (accountIdPair.size() > 2) {
            throw new IllegalArgumentException("Cannot select more than 2 accounts for transfer, got " + accountIdPair.size());
        }
        SequencedMap<Long, Account> accountById = accountDao.findByIdsForUpdate(accountIdPair).stream()
                .collect(Collectors.toMap(
                        Account::id,
                        Function.identity(),
                        (a, _) -> {
                            throw new IllegalArgumentException("Duplicate id passed " + a.id());
                        },
                        LinkedHashMap::new
                ));
        if (accountById.size() < 2) {
            throw new NotFoundException(
                    "Could not find account ids for transfer: " +
                            accountIdPair.stream()
                                    .filter(not(accountById::containsKey))
                                    .toList()
            );
        }
        return accountById;
    }
}
