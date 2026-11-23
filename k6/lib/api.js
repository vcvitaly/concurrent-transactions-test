import http from 'k6/http';
import { sleep } from 'k6';

export const BASE_URL = (__ENV.BASE_URL || 'http://localhost:8080').replace(/\/$/, '');
export const MAX_RETRIES = 3;

const JSON_PARAMS = {
  headers: { 'Content-Type': 'application/json' },
  timeout: '10s',
};

export function createAccount(name, balance) {
  const res = http.post(`${BASE_URL}/accounts`, JSON.stringify({ name, balance }), {
    ...JSON_PARAMS,
    tags: { name: 'POST /accounts' },
  });
  if (res.status !== 201) {
    throw new Error(`Could not create account ${name}: HTTP ${res.status} ${res.body}`);
  }
  return res.json();
}

export function getAccount(id) {
  const res = http.get(`${BASE_URL}/accounts/${id}`, {
    ...JSON_PARAMS,
    tags: { name: 'GET /accounts/{id}' },
  });
  if (res.status !== 200) {
    throw new Error(`Could not read account ${id}: HTTP ${res.status} ${res.body}`);
  }
  return res.json();
}

export function listTransfers() {
  const res = http.get(`${BASE_URL}/transfers`, {
    ...JSON_PARAMS,
    timeout: '60s',
    tags: { name: 'GET /transfers' },
  });
  if (res.status !== 200) {
    throw new Error(`Could not list transfers: HTTP ${res.status} ${res.body}`);
  }
  return res.json();
}

// Network errors (status 0), conflicts and server errors may be transient.
// Other 4xx responses will not change on retry.
function isRetryable(status) {
  return status === 0 || status === 409 || status >= 500;
}

/**
 * Sends a transfer, retrying up to MAX_RETRIES times (4 attempts in total).
 * Every attempt reuses the idempotency key, so a retry after a lost response cannot move money twice.
 */
export function transferWithRetry({ fromAccountId, toAccountId, amount, idempotencyKey }) {
  const body = JSON.stringify({ fromAccountId, toAccountId, amount, idempotencyKey });
  let res;

  for (let retries = 0; retries <= MAX_RETRIES; retries++) {
    res = http.post(`${BASE_URL}/transfers`, body, {
      ...JSON_PARAMS,
      tags: { name: 'POST /transfers' },
    });

    // 201 = created, 200 = an earlier attempt already succeeded.
    if (res.status === 201 || res.status === 200) {
      return { ok: true, status: res.status, retries };
    }
    if (!isRetryable(res.status) || retries === MAX_RETRIES) {
      return { ok: false, status: res.status, retries, body: res.body };
    }
    sleep(0.05 * 2 ** retries + Math.random() * 0.05);
  }
  return { ok: false, status: res.status, retries: MAX_RETRIES, body: res.body };
}
