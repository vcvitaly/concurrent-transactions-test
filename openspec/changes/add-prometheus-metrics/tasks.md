# Tasks

## 1. Dependencies and management port

- [ ] 1.1 Look up the Spring Boot 4.1 coordinates for Actuator and the Micrometer Prometheus registry, add them to `build.gradle`, and verify that `./gradlew build -x test` succeeds
- [ ] 1.2 In `application.yaml`, set `management.server.port: 8090` and expose only the `health` and `prometheus` web endpoints. Add an integration test (`@SpringBootTest(webEnvironment = RANDOM_PORT)` with a random management port) that verifies `/actuator/prometheus` returns 200 on the management port, and that neither `/actuator/prometheus` nor `/actuator/health` is served on the API port

## 2. Health endpoints and probes

- [ ] 2.1 Enable the liveness and readiness groups with no database contributor in either, set `management.endpoint.health.probes.add-additional-paths=true` and `server.shutdown=graceful`. Verify with an integration test that `/livez` and `/readyz` on the API port return 200 with only a `status` field (no `components`), and that detailed health is served only on the management port
- [ ] 2.2 Verify that readiness doesn't depend on the database: in an integration test, stop the Testcontainers Postgres while the app runs, then check that `/readyz` and `/livez` still return 200 and that `POST /transfers` returns a 5xx
- [ ] 2.3 Verify the shutdown behavior: publish a `ReadinessState.REFUSING_TRAFFIC` availability change event (what graceful shutdown does), then check that `/readyz` returns a non-2xx status
- [ ] 2.4 Add a named `management` container port (8090) to `helm/concurrent-transactions/templates/deployment.yaml`. Switch the probes in `values.yaml` to `httpGet` on port `http`: startup and readiness on `/readyz`, liveness on `/livez`. Remove the outdated "no HTTP health endpoint" comment. Verify with `helm lint` and `helm template` that the probes target `http` with those paths
- [ ] 2.5 Verify that the socat proxy and the main Service still expose only the `http` port, by checking the `helm template` output for `service.yaml` and `proxy.yaml`

## 3. Transfer metrics in the app

- [ ] 3.1 Create a `TransferMetrics` component that owns the `transfers` counter and the `transfer.duration` timer, both tagged by `outcome`, and maps a `TransferResult` or exception to an outcome as in the design's D10 table. Verify with unit tests on a `SimpleMeterRegistry`, one per outcome
- [ ] 3.2 Add SQLSTATE extraction to `TransferMetrics`: walk the cause chain to the innermost `SQLException`, use `unknown` when there is none, and increment `transfer.db.errors{sqlstate}` only for database exceptions. Verify with unit tests for `40P01`, `40001`, `23505`, a chain with no SQLException (`unknown`), and business exceptions (no increment)
- [ ] 3.3 Wrap the service call in `TransferController.transfer` with `TransferMetrics`: start a sample, record the outcome, and rethrow so `ApiExceptionHandler` still maps statuses. Verify with a `TransferControllerIT` test that sends a known sequence (201, 200, 200, 422) plus a `not_found` and an `invalid` request, compares the counters before and after, finds the exact increases from the transfer-metrics spec, and sees unchanged HTTP statuses
- [ ] 3.4 Verify that unparseable bodies aren't counted: `POST /transfers` with malformed JSON and with no body returns 4xx, `transfers_total` doesn't change, and `http_server_requests` records the requests
- [ ] 3.5 Verify that a real commit-time failure counts as `error`, as in design D10. Create a `DEFERRABLE INITIALLY DEFERRED` constraint trigger that raises an error for amount `13.37`, send that transfer, and check that the response is 5xx, `error` increased by 1, `created` didn't change, and both balances didn't change. Drop the trigger afterwards
- [ ] 3.6 Time `accountDao.findByIdsForUpdate` in `TransferService.forTransfer` with `transfer.lock.query` (try/finally). Verify with integration tests:
  - one thread holds the receiver's row lock for about 300ms while a transfer runs, and the recorded time is at least about 300ms
  - a `not_found` transfer still records a sample
  - uncontended transfers record a baseline well below the contended value
- [ ] 3.7 Enable `percentiles-histogram` only for `transfer.duration` and `transfer.lock.query`. Verify that the scraped `/actuator/prometheus` output contains `transfer_duration_seconds_bucket` and `transfer_lock_query_seconds_bucket`, and that no other app meter has buckets
- [ ] 3.8 Verify low cardinality: after transfers between several account pairs with distinct idempotency keys, the scrape output has no transfer metric series with account, amount or key tags, and the series count doesn't grow with the number of pairs

## 4. Headless metrics Service in the app chart

- [ ] 4.1 Add `templates/metrics-service.yaml` to `helm/concurrent-transactions`: a headless Service `<fullname>-metrics` with `clusterIP: None`, `publishNotReadyAddresses: true`, only the `management` port, and the app's selector labels, behind `metrics.enabled` (default `true`). Verify with `helm template` with the value on and off, and check that the selector doesn't match the proxy pods' labels

## 5. VictoriaMetrics store in Docker

- [ ] 5.1 Create `metrics/compose.yaml` with a pinned `victoriametrics/victoria-metrics` service: port binding `${METRICS_BIND_ADDRESS:-127.0.0.1}:8428:8428`, a named volume `victoriametrics-data`, and `-retentionPeriod`. Verify with `docker compose -f metrics/compose.yaml config` that the default binding is `127.0.0.1`
- [ ] 5.2 Check whether pods can reach the loopback binding: start the stack with the default binding, POST a sample from a throwaway pod to `http://host.docker.internal:8428/api/v1/import/prometheus`, and read it back from the host. Record the result in design.md D5. If it fails, keep the loopback default and document `METRICS_BIND_ADDRESS=0.0.0.0` as the explicit opt-in that makes forwarding work
- [ ] 5.3 Create `metrics.sh` with `up` (wait for `/health`; warn when `METRICS_BIND_ADDRESS` isn't loopback), `down` (keep the volume), `reset` (confirmation or `--yes`; deletes the volume) and `status` (health plus the newest `up` sample timestamp). Verify with `shellcheck metrics.sh`, then: `down` followed by `up` keeps the data, `reset` without `--yes` asks before deleting, and `METRICS_BIND_ADDRESS=0.0.0.0 ./metrics.sh up` prints the warning
- [ ] 5.4 Document in `README.md`:
  - the store lifecycle (`./metrics.sh up/down/reset/status`, independent of `deploy.sh`)
  - vmui at `http://localhost:8428/vmui`
  - the advice to start the store before load tests
  - `METRICS_BIND_ADDRESS` and what it exposes

  Verify that the documented commands run as written

## 6. Prometheus chart

- [ ] 6.1 Create the `helm/prometheus` chart (Chart.yaml, `_helpers.tpl`, values.yaml) in the style of `helm/postgres`. Values: a pinned `prom/prometheus` 3.x tag, `scrape.dnsName` (required), `scrape.port` (8090), `scrape.interval` (5s), `remoteWrite.url` (default `http://host.docker.internal:8428/api/v1/write`), retention time and size, the `emptyDir` `sizeLimit`, and `terminationGracePeriodSeconds` (90). Verify with `helm lint`
- [ ] 6.2 Add a ConfigMap rendering `prometheus.yml`: one job named `concurrent-transactions` with `dns_sd_configs` (type A, `refresh_interval: 5s`) on `scrape.dnsName`, metrics path `/actuator/prometheus`, `scrape_interval` from values, and a `remote_write` block only when `remoteWrite.url` is set. There is no self-scrape job, because the drain check reads `/metrics` directly. Verify that `helm template` fails clearly without `scrape.dnsName`, and run `promtool check config` on the rendered config with and without a URL
- [ ] 6.3 Add the Deployment: one replica, `Recreate`, an `emptyDir` with `sizeLimit`, the retention flags, `terminationGracePeriodSeconds` from values, runAsUser and fsGroup 65534, read-only root filesystem, dropped capabilities, `automountServiceAccountToken: false`, `/-/ready` and `/-/healthy` probes, and a `checksum/config` annotation. Verify with `helm template` that:
  - changing `scrape.interval` changes the checksum
  - the grace period is above 60s
  - no PVC is rendered
- [ ] 6.4 Add a ClusterIP Service `prometheus` on 9090. Verify that it renders and selects the Deployment's pods

## 7. Deploy script and docs

- [ ] 7.1 In `deploy.sh`, add `PROMETHEUS_RELEASE="prometheus"` and install it with `helm upgrade --install --wait` after the app, passing `scrape.dnsName=${APP_RELEASE}-concurrent-transactions-metrics`, and `remoteWrite.url` when `METRICS_REMOTE_WRITE_URL` is set. Verify that `bash -n deploy.sh` and `shellcheck deploy.sh` pass
- [ ] 7.2 Add the best-effort drain from design D6 to teardown:
  - read `/metrics` through the service proxy with `kubectl get --raw ... --request-timeout=5s`, polling every 2s for up to 60s in total
  - drained when pending samples are 0 and the sent timestamp is within 2 scrape intervals
  - print pending, failed and dropped totals, and warn but continue on timeout, on non-zero failed or dropped totals, or when the status can't be read
  - skip when Prometheus is absent or remote write is disabled

  Set the teardown order to speedbump, app, drain, Prometheus, Postgres and its PVC, and update the header comment. Verify with `shellcheck`, and with a teardown while the store is stopped: it warns with the pending count and finishes within about 60s plus the normal teardown time
- [ ] 7.3 Update `README.md` with:
  - the Prometheus port-forward for the live view
  - starter queries for vmui: outcome rate by `outcome`, p99 lock-query time, `up` per replica
  - a note that a high lock-query percentile needs comparing with the uncontended baseline
  - the k6 remote-write command (`-o experimental-prometheus-rw`, `K6_PROMETHEUS_RW_SERVER_URL=http://localhost:8428/api/v1/write`, `K6_PROMETHEUS_RW_TREND_STATS`)
  - the `METRICS_REMOTE_WRITE_URL` override
  - how to compare a run with k6 (design D12: the time window, one run at a time per deployment)

  Verify that every documented command matches the release, Service names and ports in the charts and scripts

## 8. End-to-end checks

- [ ] 8.1 Run `./metrics.sh up`, then `./deploy.sh` on a clean namespace. Verify that all pods become ready and that no Postgres, speedbump or proxy pods are targets (the port-forwarded Prometheus targets page). After one minute of steady state, verify that `count_over_time(up{job="concurrent-transactions"}[1m])` in vmui is at least 11 for each replica
- [ ] 8.2 Run the documented k6 load test with the remote-write output, noting its start and end times. Verify that:
  - the README queries return data in vmui
  - over that window, the difference in `sum(transfers_total{outcome="created"})` equals the number of logical transfers (3 × `TRANSFERS_PER_SENDER`)
  - the difference in `replayed` is at least k6's `transfers_replayed`
  - k6 series such as `k6_http_reqs_total` are in VictoriaMetrics
  - `transfer_db_errors_total{sqlstate="40P01"}` is absent or 0
- [ ] 8.3 Delete one app pod during a run. Verify that its target drops out or shows `up=0`, and that the replacement pod is scraped without any config change
- [ ] 8.4 Run `./metrics.sh down` for a few minutes during a run, then `./metrics.sh up`. Verify that the gap is filled in VictoriaMetrics
- [ ] 8.5 Immediately after a run, run `./deploy.sh --teardown` with the store running. Verify that:
  - the drain step reports 0 pending, failed and dropped samples
  - no Prometheus pod, Service or PVC remains
  - in vmui, the last `up{job="concurrent-transactions"}` sample is within two scrape intervals of when the app was removed
  - after a redeploy, new series continue in the same store
