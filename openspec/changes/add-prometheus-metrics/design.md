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

An `emptyDir` survives container restarts but not pod deletion. The remote-write buffer is therefore lost when the pod is deleted, which is why teardown flushes first (D6).
- *Alternative: a StatefulSet with a PVC.* The store outside the cluster makes local persistence pointless. Rejected.

### D4. Find replicas through DNS on a headless Service
The app chart gains a headless Service `<fullname>-metrics` (`clusterIP: None`, management port only, the app's selector labels) with `publishNotReadyAddresses: true`, behind `metrics.enabled` (default `true`). Prometheus uses `dns_sd_configs` (type A, port 8090, `refresh_interval: 5s`) on that name. Each pod IP becomes a target, with `instance` set to `<pod-ip>:8090`.
- Publishing not-ready addresses means an unready replica is still scraped. Its metrics often explain why it became unready.
- *Alternative: `kubernetes_sd_configs` (role: pod).* It gives pod-name labels, but needs a ServiceAccount, Role and RoleBinding. It's the upgrade path if IP-based `instance` labels become a problem.

### D5. VictoriaMetrics in Docker, managed by `metrics.sh`
- **`metrics/compose.yaml`:** one `victoriametrics` service with a pinned `victoriametrics/victoria-metrics` tag, port 8428, a named volume `victoriametrics-data`, and `-retentionPeriod` (for example `6` months). VictoriaMetrics accepts Prometheus remote write natively at `/api/v1/write`, and serves vmui at `/vmui` and a Prometheus-compatible query API.
- **Port binding:** prefer `127.0.0.1:8428:8428`, so the unauthenticated store isn't exposed to the LAN. The reachability check used an all-interfaces binding. Whether a `127.0.0.1` binding is reachable from pods via `host.docker.internal` on Docker Desktop is not yet checked. Task 5.2 checks it, and falls back to all interfaces with a README note if it isn't reachable.
- **`metrics.sh` commands,** written in the strict-bash style of `deploy.sh`:
  - `up`: `docker compose up -d`, then wait for `/health`
  - `down`: stop, keeping the volume
  - `reset`: delete the volume, after an interactive confirmation or `--yes`
  - `status`: health, plus the newest sample timestamp of `up{job="concurrent-transactions"}`

### D6. Teardown flushes forwarding, then removes Prometheus
`deploy.sh --teardown` order:
1. speedbump
2. app release, so the last scrapes happen
3. flush wait
4. Prometheus release
5. Postgres release and its PVC

**Flush wait:** poll Prometheus through the API server's service proxy, with `kubectl get --raw /api/v1/namespaces/<ns>/services/prometheus:9090/proxy/api/v1/query?query=...`. This needs no exec and no port-forward. It's caught up when both hold:
- `prometheus_remote_storage_samples_pending` is 0
- `prometheus_remote_storage_highest_timestamp_in_seconds - prometheus_remote_storage_queue_highest_sent_timestamp_seconds` is below 2 scrape intervals

The wait polls every 2s for up to 60s, then prints a warning and continues. If Prometheus isn't installed, or remote write is disabled, the step is skipped.

### D7. `deploy.sh` install changes
`PROMETHEUS_RELEASE="prometheus"` is installed after the app with `--wait`. It passes `scrape.dnsName=${APP_RELEASE}-concurrent-transactions-metrics`, and `remoteWrite.url=${METRICS_REMOTE_WRITE_URL}` when that variable is set, so the default store can be overridden. `deploy.sh` doesn't check whether the store is running, because forwarding catches up from the WAL once the store starts.

### D8. k6 pushes to VictoriaMetrics directly
The README documents `-o experimental-prometheus-rw` with `K6_PROMETHEUS_RW_SERVER_URL=http://localhost:8428/api/v1/write` and `K6_PROMETHEUS_RW_TREND_STATS`. The existing `SUMMARY_FILE` flow is unchanged.

### D9. Management port 8090 serves health and Prometheus only
`management.server.port: 8090`. The exposed endpoints are `health` and `prometheus`, with the liveness and readiness groups enabled.
- Liveness has no database check, so a Postgres outage doesn't cause restart loops.
- Readiness becomes ready after the context has started, which is after Flyway migrations.
- The Helm probes switch to `httpGet` on the named `management` port.
- The socat proxy forwards only the Service's `http` port, so 8090 is reachable only through the headless metrics Service.

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

- *Alternative: `@Observed` on the service, or an aspect.* It risks running inside the transaction boundary and counting `created` before a failed commit. Rejected.

### D11. Measure lock wait inside the service, and classify database errors by SQLSTATE
- **Lock wait:** `transfer.lock.wait` wraps `accountDao.findByIdsForUpdate` in `TransferService.forTransfer`, with a try/finally so failures are timed too.
- **Database errors:** for an exception whose cause chain contains a `SQLException`, `TransferMetrics` takes the innermost one's `getSQLState()` and increments `transfer.db.errors{sqlstate}`, using `unknown` when there is none. This covers the 409 path (for example `23505`), deadlocks and serialization failures.
- **Meter names** (Micrometer → Prometheus): `transfers` → `transfers_total`, `transfer.duration` → `transfer_duration_seconds`, `transfer.lock.wait` → `transfer_lock_wait_seconds`, `transfer.db.errors` → `transfer_db_errors_total`. `percentiles-histogram` is enabled only for the two timers.

## Risks / Trade-offs

- [The store is down for longer than the collector's WAL buffer, about 2h, or the Prometheus pod is deleted while behind] → Those samples are lost from the store. The README says to start the store (`./metrics.sh up`) before load tests. Teardown flushes and warns (D6).
- [`host.docker.internal` from pods depends on Docker Desktop's DNS and networking] → Checked on the current setup. `remoteWrite.url` can be overridden (`METRICS_REMOTE_WRITE_URL`) if a future setup needs a different address.
- [Binding the store to all interfaces would expose an unauthenticated write and query API on the LAN] → Prefer `127.0.0.1`, checked by task 5.2. If that binding isn't reachable from pods, document the exposure.
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
