# Concurrent Transactions Test

## How to run

Start the metrics store first, so the run's metrics are kept (see [Metrics](#metrics)):

```bash
./metrics.sh up
```

Start the infrastructure:

```bash
./deploy.sh
```

Port-forward speedbump to `localhost:8081`, and keep this terminal open:

```bash
kubectl -n concurrent-transactions port-forward pod/speedbump 8081:8081
```

Run the load test through it:

```bash
k6 run --no-connection-reuse -e BASE_URL=http://localhost:8081 -e SUMMARY_FILE=run-(date +%s)-summary.json k6/concurrent-transfers.js
```

Stop the infrastructure:

```bash
./deploy.sh --teardown
```

## Metrics

Each app replica serves Prometheus metrics on its management port, 8090, at `/actuator/prometheus`. That port isn't part of the app Service, so it can't be reached through the socat proxy or speedbump. Only the bare probe statuses `/livez` and `/readyz` are on the API port.

```
app pods <--scrape every 5s-- Prometheus (in the cluster) --remote write--> VictoriaMetrics (Docker, localhost:8428)
                                                                                   ^
                                                                k6 --remote write--+
```

- **Prometheus** runs in the cluster, installed and removed by `deploy.sh`. Its local data is disposable. It scrapes every replica through the headless Service `app-concurrent-transactions-metrics` and forwards everything to the store.
- **VictoriaMetrics** is the long-term store. It runs in Docker outside the cluster, so history survives `./deploy.sh --teardown` and runs can be compared over time. `deploy.sh` never starts, stops or deletes it.

### The store

| Command | What it does |
| --- | --- |
| `./metrics.sh up` | Starts the store and waits until it is healthy |
| `./metrics.sh down` | Stops the store. The data is kept in the Docker volume `victoriametrics-data` |
| `./metrics.sh status` | Shows whether the store is healthy, and when the app was last scraped |
| `./metrics.sh reset` | Stops the store and **permanently deletes all its data**, after asking. `--yes` skips the question |

Start the store before a load test. If it is down, Prometheus keeps buffering and catches up when it starts, but only for about 2 hours, and only while Prometheus is still running.

The store's UI, vmui, is at <http://localhost:8428/vmui>. Data is kept for 6 months; set `METRICS_RETENTION` (months, or a value such as `30d`) when running `./metrics.sh up` to change that.

The store listens only on `127.0.0.1:8428`, and pods still reach it through `host.docker.internal`. Its API has no authentication, so anyone who can reach it can read and write metrics. To listen on another address, which `./metrics.sh up` warns about, set it explicitly:

```bash
env METRICS_BIND_ADDRESS=0.0.0.0 ./metrics.sh up
```

To forward from the cluster to a store other than `http://host.docker.internal:8428/api/v1/write`, set `METRICS_REMOTE_WRITE_URL` when deploying:

```bash
env METRICS_REMOTE_WRITE_URL=http://my-store:8428/api/v1/write ./deploy.sh
```

On `./deploy.sh --teardown`, the app is removed first, then teardown waits up to 60s for Prometheus to forward what it scraped, and prints the pending, failed and dropped sample counts. It warns and carries on if forwarding didn't finish, for example because the store isn't running. This is best effort: check the store if a run's last seconds matter.

### Live view in Prometheus

While the cluster is up, port-forward Prometheus and open <http://localhost:9090> (the targets page is <http://localhost:9090/targets>):

```bash
kubectl -n concurrent-transactions port-forward service/prometheus 9090:9090
```

### Queries

Run these in vmui, or in Prometheus during a run.

Transfer outcomes per second:

```promql
sum by (outcome) (rate(transfers_total[30s]))
```

p99 of the row-lock query time:

```promql
histogram_quantile(0.99, sum by (le) (rate(transfer_lock_query_seconds_bucket[30s])))
```

Whether each replica is scraped (1 = up):

```promql
up{job="concurrent-transactions"}
```

Database errors by SQLSTATE (for example `40P01` deadlock, `40001` serialization failure, `23505` unique violation):

```promql
sum by (sqlstate) (increase(transfer_db_errors_total[1m]))
```

The app's transfer metrics:

| Metric | Meaning |
| --- | --- |
| `transfers_total{outcome}` | Transfer requests whose body was parsed, by outcome: `created`, `replayed`, `insufficient_funds`, `not_found`, `invalid`, `error`. Counted after the transaction commits or rolls back. Unparseable bodies appear only in `http_server_requests_seconds` |
| `transfer_duration_seconds{outcome}` | Transfer processing time, including the commit. Has histogram buckets |
| `transfer_lock_query_seconds` | The whole `SELECT ... FOR UPDATE` round trip on both accounts, including any wait for row locks. Has histogram buckets |
| `transfer_db_errors_total{sqlstate}` | Transfers that failed with a database error, by PostgreSQL SQLSTATE (`unknown` when there is none) |

`transfer_lock_query_seconds` covers the whole query, not only the time spent waiting for locks. Uncontended, it is a sub-millisecond primary-key lookup, so a high percentile on its own doesn't prove lock contention: compare it with the uncontended baseline, for example `histogram_quantile(0.5, ...)` over a quiet period when transfers arrive one at a time.

### k6 metrics in the store

k6 can push its own metrics to the store, next to the server's:

```bash
env K6_PROMETHEUS_RW_SERVER_URL=http://localhost:8428/api/v1/write 'K6_PROMETHEUS_RW_TREND_STATS=p(50),p(95),p(99),max' k6 run -o experimental-prometheus-rw --no-connection-reuse -e BASE_URL=http://localhost:8081 -e SUMMARY_FILE=run-(date +%s)-summary.json k6/concurrent-transfers.js
```

Its series are prefixed with `k6_`, for example `k6_http_reqs_total` and `k6_transfers_replayed_total`.

### Comparing a run with k6

The server and k6 count different things. A transfer whose 201 was lost and that k6 retried is one `created` plus one `replayed` on the server, and retries after a 409 or 500 add server `error` outcomes that k6 doesn't report. Two checks hold despite retries:

- the increase in `created` over the run equals the number of logical transfers (3 × `TRANSFERS_PER_SENDER`)
- the increase in `replayed` is at least k6's `transfers_replayed`

Note the run's start and end times (`date +%s`), and query the counters at each edge:

```bash
curl -s http://localhost:8428/api/v1/query --data-urlencode 'query=sum(transfers_total{outcome="created"})' -d time=<run-start>
```

```bash
curl -s http://localhost:8428/api/v1/query --data-urlencode 'query=sum(transfers_total{outcome="created"})' -d time=<run-end>
```

The server doesn't know which k6 run a request came from, so this only works with one run at a time per deployment. A replica that restarted during the run resets its counters; use `sum(increase(transfers_total{outcome="created"}[<seconds>s]))` at `time=<run-end>` instead.
