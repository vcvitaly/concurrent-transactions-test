# Spec Delta

## Purpose

Makes the transfer service's behavior under contention visible from the server side (outcomes, latency, row-lock query time and database errors), so load-test runs can be explained and compared.

## ADDED Requirements

### Requirement: Metrics endpoint on a separate management port
The service SHALL expose its metrics in the Prometheus text exposition format over HTTP on a management port that is separate from the API port. The API port SHALL NOT serve the metrics.

#### Scenario: Metrics are served on the management port
- **WHEN** a client sends a GET request to the metrics path on the management port of a running replica
- **THEN** the response is HTTP 200 in Prometheus text format and includes the transfer metrics defined in this spec

#### Scenario: Metrics are not served on the API port
- **WHEN** a client requests the metrics path on the API port
- **THEN** no metrics are returned

### Requirement: Transfer outcome counter
The service SHALL count each `POST /transfers` request that reaches transfer processing in a `transfers_total` counter with exactly one `outcome` tag. The values are `created`, `replayed`, `insufficient_funds`, `not_found`, `invalid` and `error`. A request reaches transfer processing when its body has been parsed into a transfer request.

#### Scenario: New transfer
- **WHEN** a transfer request moves money and the service responds 201
- **THEN** `transfers_total{outcome="created"}` increases by 1

#### Scenario: Repeated idempotency key
- **WHEN** a transfer request reuses the (from, to, idempotency key) of an existing transfer and the service responds 200 with the original transfer
- **THEN** `transfers_total{outcome="replayed"}` increases by 1 and `transfers_total{outcome="created"}` does not change

#### Scenario: Known sequence of responses
- **WHEN** a test sends one new transfer (201), then the same request twice more (200, 200), then a transfer that exceeds the balance (422), noting the counter values before and after
- **THEN** `created` increased by exactly 1, `replayed` by exactly 2, `insufficient_funds` by exactly 1, and no other outcome changed

#### Scenario: Insufficient funds
- **WHEN** a transfer request is rejected because the sender's balance is below the amount
- **THEN** `transfers_total{outcome="insufficient_funds"}` increases by 1

#### Scenario: Unknown account
- **WHEN** a transfer request names an account that does not exist
- **THEN** `transfers_total{outcome="not_found"}` increases by 1

#### Scenario: Invalid request
- **WHEN** a parsed transfer request fails validation (missing account, same account on both sides, or a non-positive amount)
- **THEN** `transfers_total{outcome="invalid"}` increases by 1

#### Scenario: Unexpected failure
- **WHEN** a transfer request fails for any other reason, such as a database error
- **THEN** `transfers_total{outcome="error"}` increases by 1

#### Scenario: Unparseable request body
- **WHEN** a `POST /transfers` request has malformed JSON or no body
- **THEN** `transfers_total` does not change, and the request is visible only in the built-in HTTP server request metrics

### Requirement: Outcomes reflect the committed result
The service SHALL record a transfer's outcome only after its transaction has committed or rolled back. A transfer whose commit fails SHALL NOT be counted as `created` or `replayed`.

#### Scenario: Commit fails after the transfer logic finished
- **WHEN** a transfer's statements all succeed but the database rejects the transaction at commit time
- **THEN** the request is counted as `error`, not as `created`, and no money has moved

### Requirement: Transfer duration
The service SHALL record, in a `transfer_duration_seconds` timer, the time from the start of transfer processing until the transaction has finished. It SHALL carry the same `outcome` tag as `transfers_total` and publish histogram buckets, so percentiles can be computed across replicas. Request parsing and response writing are not included.

#### Scenario: Duration is recorded per outcome
- **WHEN** a transfer request completes transfer processing with any outcome
- **THEN** `transfer_duration_seconds_count` for that outcome increases by 1 and its `_sum` grows by the processing time

#### Scenario: Percentiles can be aggregated
- **WHEN** the metrics are scraped
- **THEN** `transfer_duration_seconds_bucket` series with `le` tags are present

### Requirement: Row-lock query time
The service SHALL record, in a `transfer_lock_query_seconds` timer with histogram buckets, how long each transfer's lock query on its two accounts takes. The time covers the whole query, including any wait for row locks held by other transactions. It SHALL be recorded whether the query succeeds or fails.

#### Scenario: Lock is contended
- **WHEN** another transaction holds the receiving account's row lock for about 300ms while a transfer runs
- **THEN** the transfer's recorded lock-query time is at least about 300ms

#### Scenario: Uncontended baseline
- **WHEN** transfers run one at a time with no other transactions
- **THEN** their recorded lock-query times show the query's own cost, which is the baseline that contention is compared against

#### Scenario: Lock query fails
- **WHEN** the lock query fails, for example because an account does not exist
- **THEN** the time spent is still recorded in `transfer_lock_query_seconds`

### Requirement: Database error counter
The service SHALL count transfers that fail with a database error in a `transfer_db_errors_total` counter tagged with the error's PostgreSQL `sqlstate`. When no SQLSTATE is available, the tag value SHALL be `unknown`.

#### Scenario: Deadlock
- **WHEN** a transfer fails because PostgreSQL detected a deadlock
- **THEN** `transfer_db_errors_total{sqlstate="40P01"}` increases by 1

#### Scenario: Serialization failure
- **WHEN** a transfer fails with a serialization failure
- **THEN** `transfer_db_errors_total{sqlstate="40001"}` increases by 1

#### Scenario: Business rejections are not database errors
- **WHEN** a transfer is rejected for insufficient funds or failed validation
- **THEN** `transfer_db_errors_total` does not change

### Requirement: Low-cardinality tags
Transfer metric tags SHALL NOT include account IDs, transfer IDs, amounts, idempotency keys or any other per-request value.

#### Scenario: Many distinct accounts
- **WHEN** transfers are made between many different accounts with distinct idempotency keys
- **THEN** the number of transfer metric series does not grow with the number of accounts or keys
