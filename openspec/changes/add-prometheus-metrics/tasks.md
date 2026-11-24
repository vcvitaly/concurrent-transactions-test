# Tasks

## 1. Dependencies and management port

- [ ] 1.1 Look up the Spring Boot 4.1 coordinates for Actuator and the Micrometer Prometheus registry, add them to `build.gradle`, and verify that `./gradlew build -x test` succeeds
- [ ] 1.2 In `application.yaml`, set `management.server.port: 8090` and expose only the `health` and `prometheus` web endpoints. Add an integration test (`@SpringBootTest(webEnvironment = RANDOM_PORT)` with a random management port) that verifies `/actuator/prometheus` returns 200 on the management port and is not served on the API port

## 2. Health endpoints and probes

- [ ] 2.1 Enable the liveness and readiness health groups, with no database check in liveness. Verify with an integration test that `/actuator/health/liveness` and `/actuator/health/readiness` return 200 on the management port of a started app
- [ ] 2.2 Add a named `management` container port (8090) to `helm/concurrent-transactions/templates/deployment.yaml`. Switch the probes in `values.yaml` to `httpGet`: startup and readiness on the readiness path, liveness on the liveness path. Remove the outdated "no HTTP health endpoint" comment. Verify with `helm lint` and `helm template` that the rendered probes target port `management`
- [ ] 2.3 Verify that the socat proxy and the main Service still expose only the `http` port, by checking the `helm template` output for `service.yaml` and `proxy.yaml`

## 3. Transfer metrics in the app

- [ ] 3.1 Create a `TransferMetrics` component that owns the `transfers` counter and the `transfer.duration` timer, both tagged by `outcome`, and maps a `TransferResult` or exception to an outcome as in the design's D6 table. Verify with unit tests on a `SimpleMeterRegistry`, one per outcome
- [ ] 3.2 Add SQLSTATE extraction to `TransferMetrics`: walk the cause chain to the innermost `SQLException`, use `unknown` when there is none, and increment `transfer.db.errors{sqlstate}` only for database exceptions. Verify with unit tests for `40P01`, `40001`, `23505`, a chain with no SQLException (`unknown`), and business exceptions (no increment)
- [ ] 3.3 Wrap the service call in `TransferController.transfer` with `TransferMetrics`: start a sample, record the outcome, and rethrow so `ApiExceptionHandler` still maps statuses. Verify with a `TransferControllerIT` test that `created`, `replayed`, `insufficient_funds`, `not_found` and `invalid` each increase their counter by exactly 1, and that HTTP statuses are unchanged
- [ ] 3.4 Verify that a commit failure counts as `error` and not `created`, with a controller-level test where the service throws a `TransactionSystemException` after the transfer logic
- [ ] 3.5 Time `accountDao.findByIdsForUpdate` in `TransferService.forTransfer` with `transfer.lock.wait` (try/finally). Verify with an integration test: one thread holds the receiver's row lock in an open transaction for about 300ms while a transfer runs, and the recorded lock wait is at least about 300ms. Also verify that a `not_found` transfer still records a lock-wait sample
- [ ] 3.6 Enable `percentiles-histogram` only for `transfer.duration` and `transfer.lock.wait`. Verify that the scraped `/actuator/prometheus` output contains `transfer_duration_seconds_bucket` and `transfer_lock_wait_seconds_bucket`, and that no other app meter has buckets
- [ ] 3.7 Verify low cardinality: after transfers between several account pairs with distinct idempotency keys, the scrape output has no transfer metric series with account, amount or key tags, and the series count doesn't grow with the number of pairs

## 4. Headless metrics Service in the app chart

- [ ] 4.1 Add `templates/metrics-service.yaml` to `helm/concurrent-transactions`: a headless Service `<fullname>-metrics` with `clusterIP: None`, `publishNotReadyAddresses: true`, only the `management` port, and the app's selector labels, behind a `metrics.enabled` value that defaults to true. Verify with `helm template` with the value on and off

## 5. Prometheus chart

- [ ] 5.1 Create the `helm/prometheus` chart (Chart.yaml, `_helpers.tpl`, values.yaml) in the style of `helm/postgres`. Values: a pinned `prom/prometheus` 3.x tag, `scrape.dnsName` (required), `scrape.port` (8090), `scrape.interval` (5s), retention time and size, and volume size. Verify with `helm lint`
- [ ] 5.2 Add a ConfigMap rendering `prometheus.yml` with one scrape job that uses `dns_sd_configs` (type A, `refresh_interval: 5s`) on `scrape.dnsName`, metrics path `/actuator/prometheus`, and `scrape_interval` from values. Verify that `helm template` fails with a clear message when `scrape.dnsName` is missing, and renders the config otherwise
- [ ] 5.3 Add the StatefulSet: one replica, a `data` volume claim template, `--storage.tsdb.retention.time`, `--storage.tsdb.retention.size`, `--web.enable-remote-write-receiver`, runAsUser and fsGroup 65534, read-only root filesystem, dropped capabilities, `automountServiceAccountToken: false`, readiness and liveness on `/-/ready` and `/-/healthy`, and a `checksum/config` pod annotation. Verify with `helm template` that changing `scrape.interval` changes the checksum
- [ ] 5.4 Add a ClusterIP Service `prometheus` on port 9090. Verify that it renders and selects the StatefulSet's pods

## 6. Deploy script and docs

- [ ] 6.1 In `deploy.sh`, add `PROMETHEUS_RELEASE="prometheus"` and install it with `helm upgrade --install --wait` after the app, passing `scrape.dnsName=${APP_RELEASE}-concurrent-transactions-metrics`. Verify that `bash -n deploy.sh` and `shellcheck deploy.sh` pass
- [ ] 6.2 In the teardown, uninstall the Prometheus release between the app and Postgres, do not delete `data-prometheus-0`, and print a closing message that names the kept PVC and the `kubectl delete pvc` command for it. Update the header comment to say that metrics survive teardown. Verify by reading the script and with `shellcheck`
- [ ] 6.3 Update `README.md` with the Prometheus port-forward command, the starter queries (outcome rate by `outcome`, p99 lock wait, `up`), the optional k6 remote-write command (`-o experimental-prometheus-rw`, `K6_PROMETHEUS_RW_SERVER_URL`, `K6_PROMETHEUS_RW_TREND_STATS`), and how to delete the kept metrics volume. Verify that every documented command matches the release, Service names and ports in the charts and script

## 7. End-to-end checks on a cluster

- [ ] 7.1 Run `./deploy.sh` on a clean namespace. Verify that all pods become ready and the Prometheus UI shows 2 `up` targets for the app with distinct `instance` labels
- [ ] 7.2 Run the documented k6 load test through speedbump. Verify that the README queries return data, that the `created` and `replayed` counts summed across replicas match the k6 summary's `transfers_succeeded` and `transfers_replayed`, and that `transfer_db_errors_total{sqlstate="40P01"}` is absent or 0
- [ ] 7.3 Run k6 again with the remote-write output. Verify that k6 metrics such as `k6_http_reqs_total` can be queried next to the app's metrics
- [ ] 7.4 Delete one app pod during a run. Verify that its target drops out or shows `up=0`, and that the replacement pod is scraped without any config change
- [ ] 7.5 Run `./deploy.sh --teardown` and then `./deploy.sh`. Verify that the closing message named the kept PVC, the Postgres PVC was deleted, and queries for the earlier run still return data
