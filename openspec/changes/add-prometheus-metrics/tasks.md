# Tasks

## 1. Check that a container can reach the API server

- [ ] 1.1 From a throwaway container on Docker Desktop (`curlimages/curl` with `--add-host host.docker.internal:host-gateway`), call `https://host.docker.internal:<port>/version` with the cluster CA, using `--connect-to` so TLS verifies against `localhost`. Verify that it returns the server version with full TLS verification. If it doesn't, work through the fallbacks in design D10 and record the working `server_name` (or network approach) in design.md before continuing

## 2. Dependencies and management port

- [ ] 2.1 Look up the Spring Boot 4.1 coordinates for Actuator and the Micrometer Prometheus registry, add them to `build.gradle`, and verify that `./gradlew build -x test` succeeds
- [ ] 2.2 In `application.yaml`, set `management.server.port: 8090` and expose only the `health` and `prometheus` web endpoints. Add an integration test (`@SpringBootTest(webEnvironment = RANDOM_PORT)` with a random management port) that verifies `/actuator/prometheus` returns 200 on the management port and is not served on the API port

## 3. Health endpoints and probes

- [ ] 3.1 Enable the liveness and readiness health groups, with no database check in liveness. Verify with an integration test that `/actuator/health/liveness` and `/actuator/health/readiness` return 200 on the management port of a started app
- [ ] 3.2 Add a named `management` container port (8090) to `helm/concurrent-transactions/templates/deployment.yaml`. Switch the probes in `values.yaml` to `httpGet`: startup and readiness on the readiness path, liveness on the liveness path. Remove the outdated "no HTTP health endpoint" comment. Verify with `helm lint` and `helm template` that the rendered probes target port `management`
- [ ] 3.3 Verify that the socat proxy and the main Service still expose only the `http` port, by checking the `helm template` output for `service.yaml` and `proxy.yaml`

## 4. Transfer metrics in the app

- [ ] 4.1 Create a `TransferMetrics` component that owns the `transfers` counter and the `transfer.duration` timer, both tagged by `outcome`, and maps a `TransferResult` or exception to an outcome as in the design's D12 table. Verify with unit tests on a `SimpleMeterRegistry`, one per outcome
- [ ] 4.2 Add SQLSTATE extraction to `TransferMetrics`: walk the cause chain to the innermost `SQLException`, use `unknown` when there is none, and increment `transfer.db.errors{sqlstate}` only for database exceptions. Verify with unit tests for `40P01`, `40001`, `23505`, a chain with no SQLException (`unknown`), and business exceptions (no increment)
- [ ] 4.3 Wrap the service call in `TransferController.transfer` with `TransferMetrics`: start a sample, record the outcome, and rethrow so `ApiExceptionHandler` still maps statuses. Verify with a `TransferControllerIT` test that `created`, `replayed`, `insufficient_funds`, `not_found` and `invalid` each increase their counter by exactly 1, and that HTTP statuses are unchanged
- [ ] 4.4 Verify that a commit failure counts as `error` and not `created`, with a controller-level test where the service throws a `TransactionSystemException` after the transfer logic
- [ ] 4.5 Time `accountDao.findByIdsForUpdate` in `TransferService.forTransfer` with `transfer.lock.wait` (try/finally). Verify with an integration test: one thread holds the receiver's row lock in an open transaction for about 300ms while a transfer runs, and the recorded lock wait is at least about 300ms. Also verify that a `not_found` transfer still records a lock-wait sample
- [ ] 4.6 Enable `percentiles-histogram` only for `transfer.duration` and `transfer.lock.wait`. Verify that the scraped `/actuator/prometheus` output contains `transfer_duration_seconds_bucket` and `transfer_lock_wait_seconds_bucket`, and that no other app meter has buckets
- [ ] 4.7 Verify low cardinality: after transfers between several account pairs with distinct idempotency keys, the scrape output has no transfer metric series with account, amount or key tags, and the series count doesn't grow with the number of pairs

## 5. Scrape identity in the app chart

- [ ] 5.1 Add `templates/scraper-rbac.yaml` to `helm/concurrent-transactions`, behind `metrics.scraper.enabled` (default `true`): a ServiceAccount `<fullname>-scraper`, a Role with `pods: get, list, watch` and `pods/proxy: get`, a RoleBinding, and a `kubernetes.io/service-account-token` Secret for that ServiceAccount. Verify with `helm lint`, and with `helm template` with the value on and off
- [ ] 5.2 After installing the chart on the cluster, verify least privilege with `kubectl auth can-i --as=system:serviceaccount:<ns>:<fullname>-scraper`: `list pods` and `get pods/proxy` are allowed in the namespace; `get secrets` in the namespace and `list pods` in `default` are denied

## 6. `deploy.sh` writes the scrape credentials

- [ ] 6.1 Add `.metrics/` to `.gitignore`. Verify that `git check-ignore .metrics/k8s/token` matches
- [ ] 6.2 In `deploy.sh`, after the app install, wait for the token Secret's `.data.token` to be filled in, then write `token`, `ca.crt` and `api-server` (the kubeconfig server URL, with `127.0.0.1`/`localhost` rewritten to `host.docker.internal`) into `.metrics/k8s/`, with mode 600 and atomic writes. Print a hint to run `./metrics.sh reload` when `api-server` or `ca.crt` changed. Verify with `shellcheck deploy.sh`, and by running a deploy and checking the three files and their permissions
- [ ] 6.3 Confirm that `--teardown` neither touches `.metrics/` nor calls Docker, and update the script's header comment to say that metrics are managed by `metrics.sh`. Verify by reading the script and running a teardown while the metrics stack is up: it keeps running

## 7. Metrics stack in Docker

- [ ] 7.1 Create `metrics/compose.yaml` with a pinned `prom/prometheus` 3.x service:
  - published on `127.0.0.1:9090`, with the `prometheus-data` volume
  - `extra_hosts: host.docker.internal:host-gateway`
  - read-only mounts of `.metrics/prometheus.yml` and `.metrics/k8s/`
  - the flags for retention time and size, the remote-write receiver and lifecycle

  Verify with `docker compose -f metrics/compose.yaml config`
- [ ] 7.2 Create `metrics/prometheus.yml.tmpl` with the `kubernetes_sd_configs` pod job from design D4. It includes: the namespace and label selector, the token file, CA and `server_name` (from task 1.1), relabeling to the pod-proxy metrics path, `instance` set to the pod name, `scrape_interval: 5s`, and an optional `remote_write` placeholder. Verify by rendering it and running `promtool check config` from the Prometheus image
- [ ] 7.3 Create `metrics.sh` with `up`, `reload`, `down`, `reset` (confirmation or `--yes`; deletes only `prometheus-data` unless `--include-vm` is given) and `forwarding-status` (task 8.2). It renders the template, leaves out the Kubernetes job (with a hint) when `.metrics/k8s/` is missing, and waits for `/-/ready` on `up`. Verify with `shellcheck metrics.sh`, then: `up` with no cluster serves the UI, `down` followed by `up` keeps the data, and `reset` without `--yes` asks before deleting
- [ ] 7.4 Update `README.md` with:
  - the metrics lifecycle (`./metrics.sh up/down/reset`, independent of `deploy.sh`)
  - the UI URL `http://localhost:9090`
  - the starter queries: outcome rate by `outcome`, p99 lock wait, `up` per pod
  - the k6 remote-write command (`-o experimental-prometheus-rw`, `K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write`, `K6_PROMETHEUS_RW_TREND_STATS`)
  - a note that the scrape identity's `pods/proxy` access covers every pod in the namespace

  Verify that every documented command runs as written

## 8. Forwarding to VictoriaMetrics

- [ ] 8.1 Add the `victoriametrics` service under the `victoriametrics` profile in `metrics/compose.yaml` (pinned image, `127.0.0.1:8428`, its own volume). Make `metrics.sh up --local-vm` start it and render `remote_write` to `http://victoriametrics:8428/api/v1/write`, and make a set `VM_REMOTE_WRITE_URL` render that URL instead. Verify with `promtool check config` for all three cases: no URL, local VictoriaMetrics, external URL
- [ ] 8.2 Implement `metrics.sh forwarding-status` as in design D8: pending samples are 0 and the sent timestamp is within 2 scrape intervals. It exits non-zero when not caught up or when no `remote_write` is configured. Verify that it reports "caught up" with the local VictoriaMetrics running, and fails while the VictoriaMetrics container is stopped
- [ ] 8.3 Document in `README.md` how to enable forwarding (local or external), the `forwarding-status` check before `reset`, and that data collected before forwarding was turned on is not backfilled. Verify that the documented steps run as written

## 9. End-to-end checks on the cluster

- [ ] 9.1 Run `./deploy.sh` on a clean namespace, then `./metrics.sh up --local-vm`. Verify that `localhost:9090` shows 2 `up` targets whose `instance` values are the app pod names, and that no Postgres, speedbump or proxy pods are targets
- [ ] 9.2 Run the documented k6 load test with the remote-write output. Verify that:
  - the README queries return data
  - the `created` and `replayed` counts summed across pods match the k6 summary's `transfers_succeeded` and `transfers_replayed`
  - k6 series such as `k6_http_reqs_total` appear in Prometheus
  - `transfer_db_errors_total{sqlstate="40P01"}` is absent or 0
- [ ] 9.3 Delete one app pod during a run. Verify that its target drops out or shows `up=0`, and that the replacement pod is scraped without any config change
- [ ] 9.4 Run `./deploy.sh --teardown` with the metrics stack up. Verify that Prometheus keeps running and still answers queries for the earlier run. Run `./deploy.sh` again and verify that scraping resumes within a minute without restarting Prometheus
- [ ] 9.5 Verify that the same run's service and k6 series can be queried in VictoriaMetrics at `localhost:8428`. Stop VictoriaMetrics for a few minutes, restart it, and verify that the gap is filled. Then confirm `./metrics.sh forwarding-status` reports caught up, run `./metrics.sh reset --yes` (which deletes only Prometheus's data), start the stack again, and verify that the data is still in VictoriaMetrics
