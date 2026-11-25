# Concurrent Transactions Test

## How to run

Start the metrics store and Grafana first, so the run's metrics are kept (see [Metrics](#metrics)):

```bash
./metrics.sh up
```

Start the infrastructure:

```bash
./deploy.sh
```

`deploy.sh` deploys to the current kubectl context. On Docker Desktop's Kubernetes, the images it builds are available to the cluster as they are. On a [kind](https://kind.sigs.k8s.io/) cluster, set `DEPLOY_KIND_CLUSTER` to the cluster's name, so `deploy.sh` loads them into it with `kind load docker-image` (kind is required only then):

```bash
env DEPLOY_KIND_CLUSTER=my-cluster ./deploy.sh
```

Pods in a kind cluster can't reach the store at `host.docker.internal:8428` on every Docker engine. If they can't, attach the store to kind's Docker network and forward to it by container name:

```bash
docker network connect kind concurrent-transactions-victoriametrics
```

```bash
env DEPLOY_KIND_CLUSTER=my-cluster METRICS_REMOTE_WRITE_URL=http://concurrent-transactions-victoriametrics:8428/api/v1/write ./deploy.sh
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
                                                                              ^          ^
                                                           k6 --remote write--+          | queries
                                                                                         |
                                                                            Grafana (Docker, localhost:3000)
```

- **Prometheus** runs in the cluster, installed and removed by `deploy.sh`. Its local data is disposable. It scrapes every replica through the headless Service `app-concurrent-transactions-metrics` and forwards everything to the store.
- **VictoriaMetrics** is the long-term store. It runs in Docker outside the cluster, so history survives `./deploy.sh --teardown` and runs can be compared over time.
- **Grafana** runs next to the store, in the same Docker Compose project, and queries it. It is where queries and dashboards are saved; see [Grafana](#grafana).

`deploy.sh` never starts, stops or deletes the store or Grafana, or their data.

### The store and Grafana

| Command | What it does |
| --- | --- |
| `./metrics.sh up` | Starts the store and Grafana, waits until both are healthy, and prints their URLs. Fails naming whichever one isn't healthy |
| `./metrics.sh down` | Stops both. Their data is kept in the Docker volumes `victoriametrics-data` and `grafana-data` |
| `./metrics.sh status` | Shows whether the store and Grafana are healthy, each on its own line, and when the app was last scraped. Exits non-zero if either is down |
| `./metrics.sh reset` | Stops both and **permanently deletes the store's data** (`victoriametrics-data`), after asking. Grafana's data is kept. `--yes` skips the question |
| `./metrics.sh reset --grafana` | The same, and also **permanently deletes Grafana's data** (`grafana-data`): scratch dashboards, unexported edits and preferences. Can be combined with `--yes` |
| `./metrics.sh export-dashboards` | Writes every dashboard in Grafana's "Repo" folder to `metrics/grafana/dashboards/<uid>.json`; see [Grafana](#grafana) |

`reset` says which volumes it deleted and which it kept. Outside a terminal, without `--yes`, it deletes nothing and names the volumes it would have deleted.

Start the store before a load test. If it is down, Prometheus keeps buffering and catches up when it starts, but only for about 2 hours, and only while Prometheus is still running.

The store's UI, vmui, is at <http://localhost:8428/vmui>, and Grafana is at <http://localhost:3000>, with no login. Data is kept for 6 months; set `METRICS_RETENTION` (months, or a value such as `30d`) when running `./metrics.sh up` to change that.

The store listens only on `127.0.0.1:8428`, and pods still reach it through `host.docker.internal`. Its API has no authentication, so anyone who can reach it can read and write metrics. Grafana listens only on `127.0.0.1:3000`, and anyone who can reach it is an admin, with no login. To listen on another address for both, which `./metrics.sh up` warns about, set it explicitly:

```bash
env METRICS_BIND_ADDRESS=0.0.0.0 ./metrics.sh up
```

To forward from the cluster to a store other than `http://host.docker.internal:8428/api/v1/write`, set `METRICS_REMOTE_WRITE_URL` when deploying:

```bash
env METRICS_REMOTE_WRITE_URL=http://my-store:8428/api/v1/write ./deploy.sh
```

On `./deploy.sh --teardown`, the app is removed first, then teardown waits up to 60s for Prometheus to forward what it scraped, and prints the pending, failed and dropped sample counts. It warns and carries on if forwarding didn't finish, for example because the store isn't running. This is best effort: check the store if a run's last seconds matter.

### Grafana

Grafana at <http://localhost:3000> opens with no login. The store is its default datasource, `VictoriaMetrics` (uid `victoriametrics`), so any query that works in vmui, including MetricsQL functions, works in Grafana too.

Dashboards live in two kinds of folder:

- **Repo** holds the dashboards committed in `metrics/grafana/dashboards/`. They are loaded on start, and a changed file is picked up within a few seconds, with no restart. They can be edited and saved in the UI, but a UI edit lasts only until Grafana restarts or the file changes, unless you export it.
- **Every other folder**, including the default one, is scratch space. Those dashboards are kept only in Grafana's data volume: they survive `down`, `up` and a plain `reset`, but not `reset --grafana`, and are never written to the repo.

To save a query, add it as a panel to a dashboard: in **Explore**, run the query, then use **Add to dashboard**, or add a panel to a dashboard directly and save the dashboard. To keep a dashboard in the repo, move it into the Repo folder (dashboard settings, **Folder**), then export:

```bash
./metrics.sh export-dashboards
```

This writes every dashboard in Repo to `metrics/grafana/dashboards/<uid>.json`, with sorted keys and without the volatile `id` and `version`, so an unchanged dashboard produces no diff. Commit the files like any other change. It never deletes a file: if a file has no matching dashboard in Repo, for example because the dashboard was deleted in the UI, it reports the file, and you remove it with git if it should go.

**Export before you pull, switch branches or stop the stack.** A Repo dashboard's file is its durable copy. When the file changes, or Grafana restarts (`./metrics.sh down` and `up`, or a Docker restart), Grafana serves the file's version again and unexported UI edits to it are lost. Scratch dashboards outside Repo aren't affected.

### Live view in Prometheus

While the cluster is up, port-forward Prometheus and open <http://localhost:9090> (the targets page is <http://localhost:9090/targets>):

```bash
kubectl -n concurrent-transactions port-forward service/prometheus 9090:9090
```

### Queries

The committed [Transfers dashboard](http://localhost:3000/d/transfers) in Grafana has panels for transfer outcomes, row-lock query time percentiles and per-replica `up`. Its file is `metrics/grafana/dashboards/transfers.json`.

Run these in Grafana's Explore, in vmui, or in Prometheus during a run.

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

### Smoke test

`metrics/test/smoke.sh` checks the store, Grafana and `metrics.sh` end to end: start, status, the datasource and MetricsQL through Grafana, the committed dashboards and their queries, UI saves, file changes, `export-dashboards`, `reset` and `reset --grafana`. It needs Docker, `curl`, `jq` and `awk`, but no cluster, and takes a few minutes.

It runs against a separate instance, `ct-metrics-test` on ports 18428 and 13000 with a temporary copy of the dashboards, seeded with an hour of synthetic data. It never touches the default instance's data, refuses to run if pointed at it, never binds beyond loopback, and removes its containers and volumes whether it passes or fails.

```bash
metrics/test/smoke.sh
```

### End-to-end test

`metrics/test/e2e.sh` checks what the smoke test can't: a real deploy and k6 run. It creates a throwaway kind cluster, `ct-e2e`, with its own kubeconfig, and its own metrics instance, `ct-metrics-e2e` on ports 18438 and 13010. It deploys the stack with `DEPLOY_KIND_CLUSTER`, forwarding metrics to that instance, runs two short k6 loads through speedbump (a warm-up, so the app's histogram series exist, then the measured run), and checks that:

- both app replicas are scraped, the `created` counter grew by the measured run's transfers, k6's own metrics arrived, and every panel of the Transfers dashboard shows the run's data through Grafana;
- Grafana stays healthy during `./deploy.sh --teardown`, and its scratch and Repo dashboards are unchanged.

It needs Docker, `kind`, `kubectl`, `helm` and `k6` (plus `curl`, `jq` and `awk`), and takes about 3 to 5 minutes, mostly building images and creating the cluster. It never reads or writes your kubeconfig (it checks the file and your current context are unchanged), never touches another cluster, refuses to start if a cluster named `ct-e2e` already exists, and never touches the default metrics instance. It deletes its cluster, containers, volumes and background processes whether it passes or fails.

```bash
metrics/test/e2e.sh
```
