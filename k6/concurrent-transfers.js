// Alice, Bob and Dan each send TRANSFERS_PER_SENDER $1 transfers to Charlie at the same time,
// then the final balances and the number of stored transfers are asserted.
//
//   k6 run k6/concurrent-transfers.js
//   k6 run -e BASE_URL=http://localhost:8080 -e VUS_PER_SENDER=20 k6/concurrent-transfers.js
//   k6 run -e SUMMARY_FILE=run-1-summary.json k6/concurrent-transfers.js
//
// The end-of-test summary is saved to SUMMARY_FILE (default: summary.json). Its directory must exist.

import { check } from 'k6';
import exec from 'k6/execution';
import { Counter } from 'k6/metrics';
import { createAccount, getAccount, listTransfers, transferWithRetry } from './lib/api.js';

const SENDERS = ['alice', 'bob', 'dan'];
const INITIAL_BALANCE = 1000;
const TRANSFER_AMOUNT = 1;
const TRANSFERS_PER_SENDER = Number(__ENV.TRANSFERS_PER_SENDER || 500);
const VUS_PER_SENDER = Number(__ENV.VUS_PER_SENDER || 1);
const SUMMARY_FILE = __ENV.SUMMARY_FILE || 'summary.json';

const transfersSucceeded = new Counter('transfers_succeeded');
const transfersFailed = new Counter('transfers_failed');
const transferRetries = new Counter('transfer_retries');
const transfersReplayed = new Counter('transfers_replayed');

function senderScenario(sender) {
  return {
    executor: 'shared-iterations',
    exec: 'sendTransfer',
    vus: VUS_PER_SENDER,
    iterations: TRANSFERS_PER_SENDER,
    maxDuration: '5m',
    env: { SENDER: sender },
  };
}

export const options = {
  scenarios: Object.fromEntries(SENDERS.map((sender) => [sender, senderScenario(sender)])),
  thresholds: {
    transfers_failed: ['count==0'],
    checks: ['rate==1'],
  },
};

export function setup() {
  return {
    runId: `k6-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`,
    accounts: Object.fromEntries(
      [...SENDERS, 'charlie'].map((name) => [name, createAccount(name, INITIAL_BALANCE).id]),
    ),
  };
}

export function sendTransfer({ runId, accounts }) {
  const sender = __ENV.SENDER;
  const result = transferWithRetry({
    fromAccountId: accounts[sender],
    toAccountId: accounts.charlie,
    amount: TRANSFER_AMOUNT,
    // Stable per logical transfer, and shared by all of its retries.
    idempotencyKey: `${runId}-${sender}-${exec.scenario.iterationInTest}`,
  });

  transferRetries.add(result.retries);
  if (result.ok) {
    transfersSucceeded.add(1);
    if (result.status === 200) {
      transfersReplayed.add(1);
    }
  } else {
    transfersFailed.add(1);
    console.error(`${sender} transfer failed after ${result.retries} retries: HTTP ${result.status} ${result.body}`);
  }
}

const toCents = (amount) => Math.round(Number(amount) * 100);

export function teardown({ runId, accounts }) {
  const expectedTransfers = SENDERS.length * TRANSFERS_PER_SENDER;
  const expected = {
    ...Object.fromEntries(
      SENDERS.map((sender) => [sender, INITIAL_BALANCE - TRANSFERS_PER_SENDER * TRANSFER_AMOUNT]),
    ),
    charlie: INITIAL_BALANCE + expectedTransfers * TRANSFER_AMOUNT,
  };

  const errors = [];
  for (const [name, expectedBalance] of Object.entries(expected)) {
    const actual = getAccount(accounts[name]).balance;
    const matches = check(actual, {
      [`${name} final balance is ${expectedBalance}`]: (balance) => toCents(balance) === toCents(expectedBalance),
    });
    if (!matches) {
      errors.push(`${name}: expected ${expectedBalance}, got ${actual}`);
    }
  }

  const storedTransfers = listTransfers().filter((t) => (t.idempotencyKey || '').startsWith(`${runId}-`)).length;
  const countMatches = check(storedTransfers, {
    [`exactly ${expectedTransfers} transfers stored`]: (count) => count === expectedTransfers,
  });
  if (!countMatches) {
    errors.push(`transfers: expected ${expectedTransfers}, got ${storedTransfers}`);
  }

  if (errors.length > 0) {
    // Teardown checks can land after threshold evaluation, so fail the run explicitly.
    exec.test.fail(`Final state is wrong: ${errors.join('; ')}`);
  }
}

// Defining handleSummary replaces k6's default end-of-test output, so print the key results too.
export function handleSummary(data) {
  const count = (name) => data.metrics[name]?.values.count ?? 0;
  const checks = data.metrics.checks?.values ?? {};
  const latency = data.metrics.http_req_duration?.values ?? {};
  const failedThresholds = Object.entries(data.metrics).flatMap(([metric, { thresholds = {} }]) =>
    Object.entries(thresholds)
      .filter(([, result]) => !result.ok)
      .map(([threshold]) => `${metric}: ${threshold}`),
  );

  const lines = [
    '',
    `transfers: ${count('transfers_succeeded')} succeeded, ${count('transfers_failed')} failed, ` +
      `${count('transfer_retries')} retries, ${count('transfers_replayed')} replayed`,
    `checks: ${checks.passes ?? 0} passed, ${checks.fails ?? 0} failed`,
    `http_req_duration: avg=${latency.avg?.toFixed(2)}ms p(95)=${latency['p(95)']?.toFixed(2)}ms ` +
      `max=${latency.max?.toFixed(2)}ms`,
    `thresholds: ${failedThresholds.length === 0 ? 'all passed' : `FAILED ${failedThresholds.join(', ')}`}`,
    `writing summary to ${SUMMARY_FILE}`,
    '',
  ];

  return {
    [SUMMARY_FILE]: JSON.stringify(data, null, 2),
    stdout: lines.join('\n'),
  };
}
