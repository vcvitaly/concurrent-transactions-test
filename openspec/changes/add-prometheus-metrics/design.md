# Design

## Context

See proposal.md for motivation and specs/ for the required behavior. These parts of the current setup shape the approach:

- **Cluster:** a kind cluster provisioned by Docker Desktop (context `docker-desktop`, Kubernetes v1.36.1, node `desktop-control-plane`). Checked on 2026-11-24: a pod resolves `host.docker.internal` (to `192.168.65.254`), and can GET and POST to a VictoriaMetrics container published on host port 8428. The write was read back from the host.
- **Load-test path:** the service runs as 2 replicas behind a ClusterIP Service. Load tests go k6 → speedbump → socat proxy → Service, so anything exposed on port 8080 is reachable through that path.
- **App pod labels:** `app.kubernetes.io/name=concurrent-transactions` plus the instance label. Proxy pods use a `-proxy` name label, so a label selector can tell them apart.
- **Transfer flow:** `TransferService.transfer` is `@Transactional`. It locks both accounts with `SELECT ... ORDER BY id FOR UPDATE` (`AccountDao.findByIdsForUpdate`), inserts the transfer with `ON CONFLICT DO NOTHING` for idempotency, then withdraws and deposits. `TransferController` maps the result to 201 or 200, and `ApiExceptionHandler` maps exceptions to statuses.
- **Existing tooling:** the charts in `helm/` are hand-written, with restricted security contexts. `deploy.sh` is a strict-mode bash script. Teardown uninstalls the releases but keeps the namespace and the kind cluster.
- **Probes:** they are TCP checks, because the service has no HTTP health endpoint yet.

## Goals / Non-Goals

**Goals:**
- Keep the in-cluster and out-of-cluster parts apart, with the simplest connection between them: one plain-HTTP URL from the cluster to the host, with no credentials, TLS or RBAC.
- The in-cluster part is fully disposable. All history lives in the Docker store.
- Leave the request path and the k6 setup unchanged.

**Non-Goals:**
- Dashboards (Grafana), alerting rules, recording rules.
- Metrics for the account endpoints beyond what the built-in HTTP metrics give.
- Scraping Postgres, speedbump or the socat proxy.
- Running VictoriaMetrics as a hardened or shared production store.

## Decisions

### D1. The app exposes metrics for Prometheus to pull, instead of pushing them
Prometheus scrapes `/actuator/prometheus`. Pulling gives an `up` series per replica, and the app never needs to know where any store is.
- *Alternative: OTLP push from the app.* It has no `up` signal and couples the app to the store. Rejected.

### D2. Prometheus in the cluster, streaming to VictoriaMetrics in Docker
```
 app pods <--scrape 5s-- [k8s: Prometheus, emptyDir] --remote_write (HTTP)--> host.docker.internal:8428
                                   ^                                                  |
                       port-forward (live view)                     [Docker: VictoriaMetrics + volume]
                                                                                      ^
                                                             k6 --remote_write--> localhost:8428
```
The connection goes from the cluster to the host, over plain HTTP. That direction was checked (Context).
- *Alternative: Prometheus in Docker, scraping through the API server's pod proxy.* Rejected. It works, as checked on 2026-11-24, but only with `tls_config.server_name: localhost`, because the API server certificate doesn't list `host.docker.internal`. It also needs a ServiceAccount, Role, token Secret, a credentials file written by `deploy.sh`, a host-port rewrite and a rendered config. All of that disappears when the connection goes the other way.
- *Alternative: a batch export with `vmctl` (port-forward plus remote-read) before teardown.* Rejected. It has to be remembered or hooked into teardown, needs a PVC to survive a forgotten export, and re-running it gives overlapping time ranges. Streaming reaches the same end state with no extra step.
- *Alternative: Prometheus `--agent` mode or vmagent.* Both are lighter, but they lose the live query UI in the cluster. Full Prometheus with short retention costs little more.

### D3. A hand-rolled `helm/prometheus` chart with disposable storage
- **Workload:** a Deployment with one replica and the `Recreate` strategy, using `prom/prometheus` with a pinned 3.x tag.
- **Storage:** an `emptyDir` with a `sizeLimit` (for example 1Gi), plus `--storage.tsdb.retention.time` (for example 6h) and `--storage.tsdb.retention.size` (for example 512MB). Local data only has to cover the live view and the remote-write buffer.
- **Other objects:** a ConfigMap holding `prometheus.yml`, and a ClusterIP Service `prometheus` on 9090.
- **Security:** runs as 65534 with `fsGroup: 65534`, read-only root filesystem, dropped capabilities, `automountServiceAccountToken: false`. Readiness is on `/-/ready` and liveness on `/-/healthy`.
- **Config changes:** a `checksum/config` pod annotation restarts the pod when the config changes.
- **Values:** `scrape.dnsName` (required), `scrape.port` (8090), `scrape.interval` (5s), `remoteWrite.url` (default `http://host.docker.internal:8428/api/v1/write`; empty disables it), plus the retention and size values.

An `emptyDir` survives container restarts but not pod deletion. The remote-write buffer is therefore lost when the pod is deleted. Two things guard against that: teardown drains first (D6), and Prometheus flushes its remote-write queues on SIGTERM for up to `flush_deadline` (1 minute by default). The pod sets `terminationGracePeriodSeconds: 90`, above that deadline, so `helm uninstall` doesn't kill it partway through the flush.
- *Alternative: a StatefulSet with a PVC.* The store outside the cluster makes local persistence pointless. Rejected.

### D4. Find replicas through DNS on a headless Service
The app chart gains a headless Service `<fullname>-metrics` (`clusterIP: None`, management port only, the app's selector labels) with `publishNotReadyAddresses: true`, behind `metrics.enabled` (default `true`). Prometheus uses `dns_sd_configs` (type A, port 8090, `refresh_interval: 5s`) on that name. Each pod IP becomes a target, with `instance` set to `<pod-ip>:8090`.
- Publishing not-ready addresses means an unready replica is still scraped. Its metrics often explain why it became unready.
- *Alternative: `kubernetes_sd_configs` (role: pod).* It gives pod-name labels, but needs a ServiceAccount, Role and RoleBinding. It's the upgrade path if IP-based `instance` labels become a problem.

### D5. VictoriaMetrics in Docker, managed by `metrics.sh`
- **`metrics/compose.yaml`:** one `victoriametrics` service with a pinned `victoriametrics/victoria-metrics` tag, port 8428, a named volume `victoriametrics-data`, and `-retentionPeriod` (for example `6` months). VictoriaMetrics accepts Prometheus remote write natively at `/api/v1/write`, and serves vmui at `/vmui` and a Prometheus-compatible query API.
- **Port binding:** `${METRICS_BIND_ADDRESS:-127.0.0.1}:8428:8428`, so the unauthenticated store is loopback-only by default. The reachability check used an all-interfaces binding. Task 5.2 checked whether pods reach a `127.0.0.1` binding through `host.docker.internal` on Docker Desktop.
  - **Result (2026-11-25, VictoriaMetrics v1.157.0, Docker Desktop kind cluster):** it works. A throwaway `curlimages/curl` pod POSTed a sample to `http://host.docker.internal:8428/api/v1/import/prometheus` with the store bound to `127.0.0.1:8428`, and the sample was read back from the host through `/api/v1/export`. Docker Desktop forwards `host.docker.internal` traffic to the host's loopback, so the all-interfaces binding is never needed. `METRICS_BIND_ADDRESS` stays as an explicit option.
  - `metrics.sh up` warns whenever the bind address isn't loopback. A routine `./metrics.sh up` never exposes the store.
- **`metrics.sh` commands,** written in the strict-bash style of `deploy.sh`:
  - `up`: `docker compose up -d`, then wait for `/health`
  - `down`: stop, keeping the volume
  - `reset`: delete the volume, after an interactive confirmation or `--yes`
  - `status`: health, plus the newest sample timestamp of `up{job="concurrent-transactions"}`

### D6. Teardown drains forwarding on a best-effort basis, then removes Prometheus
`deploy.sh --teardown` order:
1. speedbump
2. app release, so the last scrapes happen
3. drain wait
4. Prometheus release, which flushes again on shutdown (D3)
5. Postgres release and its PVC

**Where the status comes from:** the collector's own `/metrics` text, read through the API server's service proxy with `kubectl get --raw /api/v1/namespaces/<ns>/services/prometheus:9090/proxy/metrics --request-timeout=5s`. This needs no exec and no port-forward. Prometheus doesn't scrape itself (task 6.2 has only the app job), so PromQL over `prometheus_remote_storage_*` would return nothing. A self-scrape job would also lag by one scrape interval, which is exactly when the answer matters.

**Drained when both hold:**
- `prometheus_remote_storage_samples_pending` is 0
- `prometheus_remote_storage_highest_timestamp_in_seconds` minus `prometheus_remote_storage_queue_highest_sent_timestamp_seconds` is below 2 scrape intervals

The wait polls every 2s, with each poll capped at 5s and the whole wait at 60s. It then prints the pending count and the totals of `prometheus_remote_storage_samples_failed_total` and `prometheus_remote_storage_samples_dropped_total`. If it timed out, failed or dropped are non-zero, or the status couldn't be read, it prints a warning and continues.

This is **best effort**. Queue gauges don't cover samples the store permanently rejected, or samples still in the WAL but not yet read. Delivery is therefore checked end to end by task 8.5, which looks for the last expected sample in VictoriaMetrics. If Prometheus isn't installed, or remote write is disabled, the step is skipped.

### D7. `deploy.sh` install changes
`PROMETHEUS_RELEASE="prometheus"` is installed after the app with `--wait`. It passes `scrape.dnsName=${APP_RELEASE}-concurrent-transactions-metrics`, and `remoteWrite.url=${METRICS_REMOTE_WRITE_URL}` when that variable is set, so the default store can be overridden. `deploy.sh` doesn't check whether the store is running, because forwarding catches up from the WAL once the store starts.

### D8. k6 pushes to VictoriaMetrics directly
The README documents `-o experimental-prometheus-rw` with `K6_PROMETHEUS_RW_SERVER_URL=http://localhost:8428/api/v1/write` and `K6_PROMETHEUS_RW_TREND_STATS`. The existing `SUMMARY_FILE` flow is unchanged.

### D9. Health: probes on the API port, everything else on 8090
- **Management port:** `management.server.port: 8090` exposes `health` (with details) and `prometheus`. The socat proxy forwards only the Service's `http` port, so 8090 is reachable only through the headless metrics Service.
- **Probe paths:** `management.endpoint.health.probes.add-additional-paths=true` also serves `/livez` and `/readyz` on the **API port (8080)**. The Helm startup, readiness and liveness probes use these paths on the `http` port. The probes then fail when the API listener isn't serving, even if 8090 is fine.
- **Details:** `/livez` and `/readyz` return only `{"status": ...}`, with details never shown on them. They are reachable through the proxies, which the `service-health` spec allows. Detailed health stays on 8090.
- **Liveness** is the liveness state only. There's no database check, so a Postgres outage doesn't cause restart loops.
- **Readiness** is the readiness state only, also with no database check. It becomes ready after the context has started, which is after Flyway migrations. During graceful shutdown (`server.shutdown=graceful`) it turns to refusing traffic.
- **Why readiness skips the database:** Postgres is shared, so a database check would make both replicas unready together. The Service would have no endpoints, and k6 would see connection errors (status 0) instead of 500s, which hides what happened. For a rig that studies failures, server errors are the useful signal.
- *Alternative: probes on 8090.* They wouldn't detect a broken API listener. Rejected.
- *Alternative: database in readiness.* Rejected, see above.

### D10. Instrumentation sits outside the transaction
Outcome counting and duration timing happen in `TransferController.transfer`, around the call to the transactional `TransferService` proxy, so a failed commit reaches the controller as an exception. A `TransferMetrics` component owns the meters and the outcome mapping. The controller records the outcome and rethrows, so `ApiExceptionHandler` remains the only place that maps HTTP statuses.

| Result | Outcome |
|---|---|
| `TransferResult.created() == true` | `created` |
| `TransferResult.created() == false` | `replayed` |
| `InsufficientFundsException` | `insufficient_funds` |
| `NotFoundException` | `not_found` |
| `IllegalArgumentException` | `invalid` |
| anything else | `error` |

**Scope.** The wrapper only sees requests whose body Spring has parsed into a `TransferRequest`. Malformed JSON and missing bodies fail before the controller method runs, so they appear only in `http_server_requests`, and the spec says so. The timer likewise measures transfer processing (the service call, including commit), not request parsing or response writing.

**Testing commit-time failure for real.** A mocked service that throws can't prove the counting happens after the transaction proxy completes. The integration test creates a deferred constraint trigger on `transfers`: `CREATE CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED`, whose function raises an error for a marker amount such as `13.37`. The error then fires only at commit, after `TransferService.transfer` has returned. The test asserts that the response is a server error, `error` increased by 1, `created` didn't change and no balance changed. It drops the trigger afterwards.

- *Alternative: `@Observed` on the service, or an aspect.* It risks running inside the transaction boundary and counting `created` before a failed commit. Rejected.

### D11. Time the lock query inside the service, and classify database errors by SQLSTATE
- **Lock query:** `transfer.lock.query` wraps `accountDao.findByIdsForUpdate` in `TransferService.forTransfer`, with a try/finally so failures are timed too. It measures the whole `SELECT ... FOR UPDATE` round trip, including any wait for row locks, query execution and row mapping, and it is named and documented that way. The query is a primary-key lookup of two rows, so an uncontended run gives a sub-millisecond baseline, and contention shows up as the difference from that baseline. The README states that a high percentile on its own doesn't prove lock contention: compare it with the baseline.
- **Database errors:** for an exception whose cause chain contains a `SQLException`, `TransferMetrics` takes the innermost one's `getSQLState()` and increments `transfer.db.errors{sqlstate}`, using `unknown` when there is none. This covers the 409 path (for example `23505`), deadlocks and serialization failures.
- **Meter names** (Micrometer → Prometheus): `transfers` → `transfers_total`, `transfer.duration` → `transfer_duration_seconds`, `transfer.lock.query` → `transfer_lock_query_seconds`, `transfer.db.errors` → `transfer_db_errors_total`. `percentiles-histogram` is enabled only for the two timers.

### D12. How metric counts are checked against k6
Server outcomes and k6 counters measure different things. A transfer whose 201 response was lost, and that k6 retried and got a 200, is one `created` plus one `replayed` on the server. k6 counts it as one `transfers_succeeded` and one `transfers_replayed`, where the replay is included in the success count. Retries after a 409 or 500 also add server `error` outcomes that k6 never reports.
- **Exact checks** live in the integration tests: a known sequence of 201, 200, 200 and 422 responses, with counter values compared before and after (transfer-metrics spec).
- **Load-run checks** use only the invariants that hold under retries, over a documented time window `[run start, run end]`, assuming one run at a time per deployment:
  - the server's `created` difference, computed from two instant queries of `sum(transfers_total{outcome="created"})` at the window's edges, equals the number of logical transfers. k6's teardown already confirms that this many are stored.
  - the server's `replayed` difference is at least k6's `transfers_replayed`
- k6 tags never reach the server, so overlapping runs against one deployment can't be told apart. The README states the one-run-at-a-time assumption.

## Risks / Trade-offs

- [The store is down for longer than the collector's WAL buffer, about 2h, or the Prometheus pod is deleted while behind] → Those samples are lost from the store. The README says to start the store (`./metrics.sh up`) before load tests. Teardown drains, reports and warns (D6), and Prometheus flushes on shutdown (D3).
- [`host.docker.internal` from pods depends on Docker Desktop's DNS and networking] → Checked on the current setup. `remoteWrite.url` can be overridden (`METRICS_REMOTE_WRITE_URL`) if a future setup needs a different address.
- [Binding the store to all interfaces would expose an unauthenticated write and query API on the LAN] → The default is always `127.0.0.1`. Any other binding needs `METRICS_BIND_ADDRESS` and prints a warning (D5).
- [Readiness without a database check keeps both replicas in service during a Postgres outage] → Intended: the outage shows up as 500s and in `transfer_db_errors_total`, not as connection refusals (D9).
- [The probe paths `/livez` and `/readyz` are reachable through the proxies] → They return only an overall status. Details and metrics stay on 8090.
- [The drain check can report "drained" while samples were permanently rejected] → It also reports the failed and dropped totals. End-to-end delivery is checked in VictoriaMetrics (task 8.5).
- [With DNS discovery, `instance` is a pod IP, so per-replica series break across rollouts] → Acceptable when comparing runs with `sum`. `kubernetes_sd_configs` is the upgrade path.
- [Spring Boot 4 split Actuator and Micrometer into new module artifacts, so names from older docs may not resolve] → Confirm the coordinates against the Boot 4.1 reference first, and fail fast in the integration tests if `/actuator/prometheus` is missing.
- [`./metrics.sh reset` deletes all history] → It needs confirmation or `--yes`.

## Migration Plan

1. Run `./metrics.sh up` to start the store.
2. Run `./deploy.sh`. The app rolls out with HTTP probes and the headless metrics Service, and Prometheus is installed and starts forwarding.
3. Check that `up{job="concurrent-transactions"}` has 2 series in vmui (`localhost:8428/vmui`).
4. To roll back: `helm rollback app` restores the TCP probes and removes the headless Service, and `helm uninstall prometheus` stops collection. The store keeps its data until `./metrics.sh reset`.

## Open Questions

- The exact retention values: store retention (for example 6 months), and collector retention and `emptyDir` size. They can be tuned in values or Compose without changing the specs.
- The Prometheus and VictoriaMetrics image tags to pin. Pick the current stable releases at implementation time.
