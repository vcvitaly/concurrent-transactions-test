# Tasks

## 1. Dependencies and management port

- [ ] 1.1 Look up the Spring Boot 4.1 coordinates for Actuator and the Micrometer Prometheus registry, add them to `build.gradle`, and verify that `./gradlew build -x test` succeeds
- [ ] 1.2 In `application.yaml`, set `management.server.port: 8090` and expose only the `health` and `prometheus` web endpoints. Add an integration test (`@SpringBootTest(webEnvironment = RANDOM_PORT)` with a random management port) that verifies `/actuator/prometheus` returns 200 on the management port and is not served on the API port

## 2. Health endpoints and probes

- [ ] 2.1 Enable the liveness and readiness health groups, with no database check in liveness. Verify with an integration test that `/actuator/health/liveness` and `/actuator/health/readiness` return 200 on the management port of a started app
- [ ] 2.2 Add a named `management` container port (8090) to `helm/concurrent-transactions/templates/deployment.yaml`. Switch the probes in `values.yaml` to `httpGet`: startup and readiness on the readiness path, liveness on the liveness path. Remove the outdated "no HTTP health endpoint" comment. Verify with `helm lint` and `helm template` that the rendered probes target port `management`
- [ ] 2.3 Verify that the socat proxy and the main Service still expose only the `http` port, by checking the `helm template` output for `service.yaml` and `proxy.yaml`

## 3. Transfer metrics in the app

- [ ] 3.1 Create a `TransferMetrics` component that owns the `transfers` counter and the `transfer.duration` timer, both tagged by `outcome`, and maps a `TransferResult` or exception to an outcome as in the design's D10 table. Verify with unit tests on a `SimpleMeterRegistry`, one per outcome
- [ ] 3.2 Add SQLSTATE extraction to `TransferMetrics`: walk the cause chain to the innermost `SQLException`, use `unknown` when there is none, and increment `transfer.db.errors{sqlstate}` only for database exceptions. Verify with unit tests for `40P01`, `40001`, `23505`, a chain with no SQLException (`unknown`), and business exceptions (no increment)
- [ ] 3.3 Wrap the service call in `TransferController.transfer` with `TransferMetrics`: start a sample, record the outcome, and rethrow so `ApiExceptionHandler` still maps statuses. Verify with a `TransferControllerIT` test that `created`, `replayed`, `insufficient_funds`, `not_found` and `invalid` each increase their counter by exactly 1, and that HTTP statuses are unchanged
- [ ] 3.4 Verify that a commit failure counts as `error` and not `created`, with a controller-level test where the service throws a `TransactionSystemException` after the transfer logic
- [ ] 3.5 Time `accountDao.findByIdsForUpdate` in `TransferService.forTransfer` with `transfer.lock.wait` (try/finally). Verify with an integration test: one thread holds the receiver's row lock in an open transaction for about 300ms while a transfer runs, and the recorded lock wait is at least about 300ms. Also verify that a `not_found` transfer still records a lock-wait sample
- [ ] 3.6 Enable `percentiles-histogram` only for `transfer.duration` and `transfer.lock.wait`. Verify that the scraped `/actuator/prometheus` output contains `transfer_duration_seconds_bucket` and `transfer_lock_wait_seconds_bucket`, and that no other app meter has buckets
- [ ] 3.7 Verify low cardinality: after transfers between several account pairs with distinct idempotency keys, the scrape output has no transfer metric series with account, amount or key tags, and the series count doesn't grow with the number of pairs

## 4. Headless metrics Service in the app chart

- [ ] 4.1 Add `templates/metrics-service.yaml` to `helm/concurrent-transactions`: a headless Service `<fullname>-metrics` with `clusterIP: None`, `publishNotReadyAddresses: true`, only the `management` port, and the app's selector labels, behind `metrics.enabled` (default `true`). Verify with `helm template` with the value on and off, and check that the selector doesn't match the proxy pods' labels

## 5. VictoriaMetrics store in Docker

- [ ] 5.1 Create `metrics/compose.yaml` with a pinned `victoriametrics/victoria-metrics` service: port 8428, a named volume `victoriametrics-data`, and `-retentionPeriod`. Verify with `docker compose -f metrics/compose.yaml config`
- [ ] 5.2 Check whether a `127.0.0.1:8428:8428` binding is reachable from a pod: start the stack, then from a throwaway curl pod `GET http://host.docker.internal:8428/health`. Keep the `127.0.0.1` binding if it works. Otherwise switch to all interfaces, and record the result and the LAN exposure in design.md D5
- [ ] 5.3 Create `metrics.sh` with `up` (wait for `/health`), `down` (keep the volume), `reset` (confirmation or `--yes`; deletes the volume) and `status` (health plus the newest `up` sample timestamp). Verify with `shellcheck metrics.sh`, then: `down` followed by `up` keeps the data, and `reset` without `--yes` asks before deleting
- [ ] 5.4 Document in `README.md` the store lifecycle (`./metrics.sh up/down/reset/status`, independent of `deploy.sh`), vmui at `http://localhost:8428/vmui`, and the advice to start the store before load tests. Verify that the documented commands run as written

## 6. Prometheus chart

- [ ] 6.1 Create the `helm/prometheus` chart (Chart.yaml, `_helpers.tpl`, values.yaml) in the style of `helm/postgres`. Values: a pinned `prom/prometheus` 3.x tag, `scrape.dnsName` (required), `scrape.port` (8090), `scrape.interval` (5s), `remoteWrite.url` (default `http://host.docker.internal:8428/api/v1/write`), retention time and size, and the `emptyDir` `sizeLimit`. Verify with `helm lint`
- [ ] 6.2 Add a ConfigMap rendering `prometheus.yml`: one job named `concurrent-transactions` with `dns_sd_configs` (type A, `refresh_interval: 5s`) on `scrape.dnsName`, metrics path `/actuator/prometheus`, `scrape_interval` from values, and a `remote_write` block only when `remoteWrite.url` is set. Verify that `helm template` fails clearly without `scrape.dnsName`, and run `promtool check config` on the rendered config with and without a URL
- [ ] 6.3 Add the Deployment: one replica, `Recreate`, an `emptyDir` with `sizeLimit`, the retention flags, runAsUser and fsGroup 65534, read-only root filesystem, dropped capabilities, `automountServiceAccountToken: false`, `/-/ready` and `/-/healthy` probes, and a `checksum/config` annotation. Verify with `helm template` that changing `scrape.interval` changes the checksum and that no PVC is rendered
- [ ] 6.4 Add a ClusterIP Service `prometheus` on 9090. Verify that it renders and selects the Deployment's pods

## 7. Deploy script and docs

- [ ] 7.1 In `deploy.sh`, add `PROMETHEUS_RELEASE="prometheus"` and install it with `helm upgrade --install --wait` after the app, passing `scrape.dnsName=${APP_RELEASE}-concurrent-transactions-metrics`, and `remoteWrite.url` when `METRICS_REMOTE_WRITE_URL` is set. Verify that `bash -n deploy.sh` and `shellcheck deploy.sh` pass
- [ ] 7.2 Add the flush wait from design D6 to teardown, using `kubectl get --raw` through the service proxy, polling every 2s for up to 60s, warning and continuing on timeout, and skipping when Prometheus is absent or remote write is disabled. Set the teardown order to speedbump, app, flush, Prometheus, Postgres and its PVC. Update the header comment. Verify with `shellcheck`, and with a teardown while the store is stopped: it warns and finishes within about 60s plus the normal teardown time
- [ ] 7.3 Update `README.md` with:
  - the Prometheus port-forward for the live view
  - starter queries for vmui: outcome rate by `outcome`, p99 lock wait, `up` per replica
  - the k6 remote-write command (`-o experimental-prometheus-rw`, `K6_PROMETHEUS_RW_SERVER_URL=http://localhost:8428/api/v1/write`, `K6_PROMETHEUS_RW_TREND_STATS`)
  - the `METRICS_REMOTE_WRITE_URL` override

  Verify that every documented command matches the release, Service names and ports in the charts and scripts

## 8. End-to-end checks

- [ ] 8.1 Run `./metrics.sh up`, then `./deploy.sh` on a clean namespace. Verify that all pods become ready, that `up{job="concurrent-transactions"}` in vmui has 2 series with value 1, and that no Postgres, speedbump or proxy pods are targets (check the port-forwarded Prometheus UI's targets page)
- [ ] 8.2 Run the documented k6 load test with the remote-write output. Verify that:
  - the README queries return data in vmui
  - the `created` and `replayed` counts summed across replicas match the k6 summary's `transfers_succeeded` and `transfers_replayed`
  - k6 series such as `k6_http_reqs_total` are in VictoriaMetrics
  - `transfer_db_errors_total{sqlstate="40P01"}` is absent or 0
- [ ] 8.3 Delete one app pod during a run. Verify that its target drops out or shows `up=0`, and that the replacement pod is scraped without any config change
- [ ] 8.4 Run `./metrics.sh down` for a few minutes during a run, then `./metrics.sh up`. Verify that the gap is filled in VictoriaMetrics
- [ ] 8.5 Immediately after a run, run `./deploy.sh --teardown`. Verify that the flush step reports caught up, that no Prometheus pod, Service or PVC remains, that vmui still returns the run's data up to its last scrape, and that after a redeploy the new series continue in the same store
