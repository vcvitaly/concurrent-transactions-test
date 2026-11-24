# Design

## Context

See proposal.md for motivation and specs/ for the required behavior. These parts of the current setup shape the approach:

- The service runs as 2 replicas behind a ClusterIP Service. Load tests reach it through two hops: k6 → speedbump (a latency proxy pod) → socat proxy → Service. Anything exposed on port 8080 is reachable through that path.
- `TransferService.transfer` is `@Transactional`. It locks both accounts with `SELECT ... ORDER BY id FOR UPDATE` (`AccountDao.findByIdsForUpdate`), inserts the transfer with `ON CONFLICT DO NOTHING` for idempotency, then withdraws and deposits. `TransferController` maps the result to 201 or 200. Exceptions are mapped to HTTP statuses by `ApiExceptionHandler`.
- The Helm charts in `helm/` are hand-written, with restricted security contexts. `deploy.sh` installs them with `--wait` and builds third-party images itself rather than adding Helm repositories.
- The Postgres chart uses a StatefulSet with a volume claim template. Teardown deletes that PVC explicitly, because claims outlive the release.
- The probes are TCP checks, because the service has no HTTP health endpoint yet.

## Goals / Non-Goals

**Goals:**
- Keep the infrastructure small: one Prometheus pod, no operator, no CRDs, no RBAC.
- Leave the request path and the k6 setup unchanged. Metrics and health checks must not add hops or ports to the load-test path.
- Keep the instrumentation code in one place and easy to read next to the transfer logic.

**Non-Goals:**
- Dashboards (Grafana), alerting rules, recording rules.
- Metrics for the account endpoints beyond what the built-in HTTP metrics give.
- Scraping Postgres, speedbump or the socat proxy.

## Decisions

### D1. The app exposes metrics for Prometheus to pull, instead of pushing them
Prometheus scrapes `/actuator/prometheus`. Pulling gives an `up` series per replica, which shows dead or hung pods during stress tests. The app also doesn't need to know where Prometheus is, deploy order doesn't matter, and the scrape interval is set in one place.
- *Alternative: OTLP push from Micrometer.* It needs no discovery, but there is no `up` signal, and the app would depend on the metrics server being reachable. Rejected for the app. Pushing stays the right choice for k6 (D8), because k6 is short-lived and the cluster can't reach the laptop it runs on.

### D2. Use Prometheus instead of VictoriaMetrics
Prometheus is the default that the Micrometer, k6 and Kubernetes docs assume, and it has a built-in query UI. At this scale the two use about the same resources. If long-term storage is ever needed, Prometheus can forward to VictoriaMetrics with `remote_write`, and the app doesn't change.

### D3. A hand-rolled `helm/prometheus` chart
The chart has a StatefulSet (`prom/prometheus`, pinned tag), a ConfigMap holding `prometheus.yml`, and a ClusterIP Service on 9090. Its style matches `helm/postgres`: helpers, restricted security context, no service account token. The pod runs as 65534 with `fsGroup: 65534` so it can write to the volume, with a read-only root filesystem. A `checksum/config` annotation on the pod template restarts Prometheus when the scrape config changes, so `--web.enable-lifecycle` isn't needed.
- *Alternative: `prometheus-community/prometheus`.* By default it also installs Alertmanager, node-exporter, kube-state-metrics and Pushgateway, and it needs a Helm repository.
- *Alternative: `kube-prometheus-stack`.* An operator plus CRDs is far beyond what this needs.

### D4. Find replicas through DNS on a headless Service
The app chart gains a headless Service `<fullname>-metrics` (`clusterIP: None`, management port only, same pod selector) with `publishNotReadyAddresses: true`. Prometheus uses `dns_sd_configs` (type A, port 8090, `refresh_interval: 5s`) on that name, which `deploy.sh` passes to the Prometheus chart as a value. Each pod IP becomes its own target, and its `instance` label is `<pod-ip>:8090`.
- Publishing not-ready addresses means an unready replica, for example one whose connection pool is exhausted, is still scraped. Its metrics are often what explains why it became unready.
- *Alternative: `kubernetes_sd_configs` (role: pod).* It gives pod-name labels, but needs a ServiceAccount, Role and RoleBinding. Rejected for now. It's the upgrade path if IP-based `instance` labels become a problem.
- *Alternative: scraping the existing ClusterIP Service.* Each scrape would hit a random replica and mix their counters. Rejected.

### D5. Management port 8090 serves health and Prometheus only
`management.server.port: 8090`. The exposed endpoints are `health` and `prometheus`. Health probe groups are enabled, so `/actuator/health/liveness` and `/actuator/health/readiness` exist. The socat proxy only forwards the Service's `http` port, so 8090 is not on the load-test path. 8090 also avoids two confusing overlaps: 8081 (speedbump) and 9090 (Prometheus).
- Liveness uses the liveness state only. It doesn't include a database check, so a Postgres outage doesn't cause restart loops.
- Readiness uses Spring's readiness state, which becomes ready after the context has started. Flyway runs during startup, so migrations finish before the replica is ready.
- The Helm probes switch to `httpGet` on a named `management` port. The startup probe uses the readiness path and keeps its current generous `failureThreshold`.

### D6. Instrumentation sits outside the transaction
Outcome counting and duration timing happen in `TransferController.transfer`, around the call to the transactional `TransferService` proxy. Any exception thrown by the proxy, including one from a failed commit, reaches the controller. The controller starts a `Timer.Sample`, calls the service, maps the result or exception to an outcome, records `transfers` and `transfer.duration`, then returns the result or rethrows. Rethrowing keeps `ApiExceptionHandler` as the only place that maps HTTP statuses. A small `TransferMetrics` component owns the meters and the outcome mapping, so the controller stays short.

Outcomes:

| Result | Outcome |
|---|---|
| `TransferResult.created() == true` | `created` |
| `TransferResult.created() == false` | `replayed` |
| `InsufficientFundsException` | `insufficient_funds` |
| `NotFoundException` | `not_found` |
| `IllegalArgumentException` | `invalid` |
| anything else | `error` |

- *Alternative: `@Observed` on the service, or an aspect.* Without careful advice ordering, the aspect could run inside the transaction boundary and count `created` before a failed commit. It is also harder to follow. Rejected.
- *Alternative: the built-in `http.server.requests` metric with a `status` tag.* It can't tell 409 from 500 causes, and it has no SQLSTATE. It stays available as a cross-check.

### D7. Measure lock wait inside the service, and classify database errors by SQLSTATE
- **Lock wait:** `transfer.lock.wait` wraps the `accountDao.findByIdsForUpdate` call in `TransferService.forTransfer`, with a try/finally so failures are timed too. The lock call is the only place where the wait can be measured precisely.
- **Database errors:** when the outcome mapping in D6 sees a `DataAccessException` (or any exception with a `SQLException` in its cause chain), it reads `getSQLState()` from the innermost `SQLException` and increments `transfer.db.errors` with that `sqlstate` tag, or `unknown` if there is none. This covers the 409 `DataIntegrityViolationException` path (for example `23505`) as well as deadlocks and serialization failures.
- **Meter names** (Micrometer → Prometheus): `transfers` → `transfers_total`, `transfer.duration` → `transfer_duration_seconds`, `transfer.lock.wait` → `transfer_lock_wait_seconds`, `transfer.db.errors` → `transfer_db_errors_total`. `percentiles-histogram` is enabled only for `transfer.duration` and `transfer.lock.wait`, to keep the number of bucket series small.

### D8. k6 pushes to Prometheus by remote write
Prometheus runs with `--web.enable-remote-write-receiver`. The README documents running k6 with `-o experimental-prometheus-rw` and `K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write` through the Prometheus port-forward. Set `K6_PROMETHEUS_RW_TREND_STATS` so latency trends are exported. Pushing is optional, and the existing `SUMMARY_FILE` flow is unchanged.

### D9. Teardown keeps the metrics volume
Prometheus stores data in a StatefulSet volume claim template (`data-prometheus-0`). `helm uninstall` leaves claims created from templates in place. `deploy.sh --teardown` uninstalls the Prometheus release and does **not** delete that claim, unlike the Postgres one. Its closing message names the kept PVC and gives the delete command. The next deploy recreates `prometheus-0`, which mounts the same claim and loads the existing TSDB. Retention uses both `--storage.tsdb.retention.time` (default 15d) and `--storage.tsdb.retention.size`, set below the volume size, so the volume never fills.
- *Alternative: leave Prometheus running during teardown.* A teardown that leaves pods behind would be surprising. Rejected.
- *Alternative: a separate PVC with `helm.sh/resource-policy: keep`.* This also works, but the volume claim template matches the Postgres chart and needs no extra template.

### D10. Changes to `deploy.sh`
It gets `PROMETHEUS_RELEASE="prometheus"` and installs that release after the app, passing `scrape.dnsName=<app-fullname>-metrics` (`app-concurrent-transactions-metrics`) and the port, again with `--wait`. Teardown order: speedbump, app, Prometheus (volume kept), Postgres, then delete the Postgres PVC.

## Risks / Trade-offs

- [Spring Boot 4 split Actuator and Micrometer into new module artifacts, so names from older docs may not resolve] → Confirm the exact starter coordinates against the Boot 4.1 reference before writing `build.gradle`, and fail fast in the integration tests if `/actuator/prometheus` is missing.
- [With DNS discovery, `instance` is a pod IP, which changes every rollout, so per-replica series break across deploys] → Acceptable for comparing load-test runs, where you aggregate with `sum`. Switch to `kubernetes_sd_configs` if per-pod history matters.
- [The kept PVC keeps using disk after every teardown] → The size-based retention caps it, and the teardown message names the PVC and the delete command.
- [After a rollback that downgrades Prometheus, the newer TSDB format on the kept volume may not open] → Pin the image tag. On a failed start, delete the PVC, since metrics history isn't critical.
- [A 5s scrape interval and histograms add load] → About 2 targets × a few hundred series. This is negligible next to the load test.
- [Moving the probes onto 8090 means a broken management server marks pods unready even if the API works] → This is intended, since health and metrics are part of the deliverable. The startup probe's threshold stays generous.
- [A failed commit is attributed to `error`, and lock wait isn't recorded if the request fails before reaching the lock (validation)] → This matches the specs. The validation path never waits for a lock.

## Migration Plan

1. Deploy the app changes first. Running `./deploy.sh` on an existing namespace rolls the app with HTTP probes and the headless metrics Service, then installs Prometheus.
2. Check that both targets are up in the Prometheus UI and run a k6 run. The README queries should then return data.
3. To roll back: `helm rollback app` restores the TCP probes and removes the headless Service, and `helm uninstall prometheus` stops collection. The metrics PVC can stay or be deleted by hand.

## Open Questions

- The exact retention values and volume size (for example 15d, 1.5GB of 2Gi). These can be tuned in `values.yaml` without changing the specs.
- The Prometheus image tag to pin. Pick the current 3.x release at implementation time.
