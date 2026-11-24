# Design

## Context

See proposal.md for motivation and specs/ for the required behavior. These parts of the current setup shape the approach:

- **Cluster:** a kind cluster provisioned by Docker Desktop. Its kubeconfig points the API server at `https://127.0.0.1:<port>` on the Mac host. From inside a Docker container, `127.0.0.1` is the container itself, while `host.docker.internal` reaches the host.
- **Load-test path:** the service runs as 2 replicas behind a ClusterIP Service. Load tests go k6 → speedbump → socat proxy → Service, so anything exposed on port 8080 is reachable through that path.
- **App pod labels:** `app.kubernetes.io/name=concurrent-transactions` plus the instance label. Proxy pods use a `-proxy` name label, so a label selector can tell them apart.
- **Transfer flow:** `TransferService.transfer` is `@Transactional`. It locks both accounts with `SELECT ... ORDER BY id FOR UPDATE` (`AccountDao.findByIdsForUpdate`), inserts the transfer with `ON CONFLICT DO NOTHING` for idempotency, then withdraws and deposits. `TransferController` maps the result to 201 or 200, and `ApiExceptionHandler` maps exceptions to statuses.
- **Existing tooling:** the charts in `helm/` are hand-written, with restricted security contexts. `deploy.sh` is a strict-mode bash script with `deploy` and `--teardown` modes. Teardown uninstalls the releases but keeps the namespace and the kind cluster.
- **Probes:** they are TCP checks, because the service has no HTTP health endpoint yet.

## Goals / Non-Goals

**Goals:**
- Keep the cluster and the metrics store as two separate concerns. The cluster holds only what lets it be scraped (an identity). Prometheus and its data live in Docker and are managed only by `metrics.sh`.
- Leave the request path and the k6 setup unchanged. Metrics and health checks must not add hops or ports to the load-test path.
- Keep the instrumentation code in one place and easy to read next to the transfer logic.

**Non-Goals:**
- Dashboards (Grafana), alerting rules, recording rules.
- Metrics for the account endpoints beyond what the built-in HTTP metrics give.
- Scraping Postgres, speedbump or the socat proxy.
- Backfilling local data into VictoriaMetrics with `promtool`, and running VictoriaMetrics as a production long-term store. The optional local VictoriaMetrics is for trying out forwarding.

## Decisions

### D1. The app exposes metrics for Prometheus to pull, instead of pushing them
Prometheus scrapes `/actuator/prometheus`. Pulling gives an `up` series per replica, which shows dead or hung pods during stress tests, and the app never needs to know where Prometheus is.
- *Alternative: OTLP push from the app.* It has no `up` signal and couples the app to the metrics endpoint. Rejected. Pushing is used only for k6 (D9), which is short-lived and runs on the host.

### D2. Use Prometheus as the local store and VictoriaMetrics as optional long-term storage
Prometheus is the default that the Micrometer, k6 and Kubernetes docs assume, and it has a built-in query UI. VictoriaMetrics receives a continuous copy through `remote_write` (D8), so the local Prometheus can be removed without losing data.

### D3. Prometheus runs in Docker Compose, managed by `metrics.sh`
- **Compose stack** (`metrics/compose.yaml`): the `prom/prometheus` service with a pinned 3.x tag, published on `127.0.0.1:9090`, with the named volume `prometheus-data` and `extra_hosts: host.docker.internal:host-gateway` for portability. It mounts the rendered config and the credentials directory from `.metrics/` read-only.
- **Prometheus flags:**
  - `--storage.tsdb.retention.time` and `--storage.tsdb.retention.size`
  - `--web.enable-remote-write-receiver` (for k6)
  - `--web.enable-lifecycle` (so the config can be reloaded without a restart)
- **Optional local VictoriaMetrics:** a `victoriametrics` service under the Compose profile `victoriametrics`, using the pinned `victoriametrics/victoria-metrics` image, published on `127.0.0.1:8428`, with its own volume.
- **`metrics.sh` commands,** written in the strict-bash style of `deploy.sh`:
  - `up [--local-vm]`: render the config (D7), then `docker compose up -d`, then wait for `/-/ready`
  - `reload`: re-render the config and `POST /-/reload`
  - `down`: stop the containers, keeping the volumes
  - `reset`: remove the Prometheus container and only the `prometheus-data` volume, after an interactive confirmation or `--yes`. The local VictoriaMetrics volume survives, because it is the long-term copy. It is deleted only with `reset --include-vm`
  - `forwarding-status`: the check in D8
- *Alternative: in-cluster Prometheus with a kept PVC.* This is what the earlier version of this design chose. It ties the store's lifecycle to the cluster. Rejected at the user's request.
- *Alternative: an in-cluster agent pushing to Docker.* Discovery is simpler, but it puts a workload in the cluster. Rejected in favor of pulling through the API server.

### D4. Find pods through the Kubernetes API and scrape through the API server's pod proxy
One scrape job uses `kubernetes_sd_configs` with `role: pod`, limited to the app namespace and the label selector `app.kubernetes.io/name=concurrent-transactions`.
- **Connection:** `api_server` is `https://host.docker.internal:<port>`. Auth is `authorization.credentials_file`, pointing at the token. TLS uses `ca_file` plus `server_name` set to a name in the API server certificate's SANs (D10).
- **Relabeling:**
  - keep only the container port named `management`
  - set `__address__` to the API server's host and port
  - set `__metrics_path__` to `/api/v1/namespaces/<ns>/pods/<pod>:8090/proxy/actuator/prometheus`
  - use `scheme: https`, with the same authorization and TLS settings as discovery
  - set `instance` from `__meta_kubernetes_pod_name`, and add the `namespace` and `pod` labels
- `scrape_interval: 5s`.
- *Alternative: scrape pod IPs directly.* Docker Desktop doesn't route pod IPs to the host. Rejected.
- *Alternative: scrape through a Service.* Each scrape would hit a random replica and mix their counters. Rejected.
- Pods that are not ready stay in API discovery, so a replica that is failing readiness is still scraped.

### D5. A least-privilege scrape identity in the app chart
Behind `metrics.scraper.enabled` (default `true`), the app chart adds:
- a ServiceAccount `<fullname>-scraper`
- a Role with `pods: get, list, watch` and `pods/proxy: get`, in the release namespace only
- a RoleBinding
- a Secret of type `kubernetes.io/service-account-token` annotated for that ServiceAccount

The Secret gives a token that doesn't expire and is revoked automatically when the release is uninstalled. That fits the requirement that the identity ends with the cluster deploy.
- *Alternative: `kubectl create token`.* The token expires, and long sessions would stop scraping mid-run. Rejected.
- *Alternative: mounting the developer's kubeconfig.* It gives cluster-admin to a container and is ruled out by the spec. Rejected.

### D6. `deploy.sh` writes the credentials, and only the credentials
After `helm upgrade --install` of the app, `deploy.sh` waits until the token Secret's `.data.token` has been filled in, then writes three files into `.metrics/k8s/` with mode 600 and an atomic write (temp file then `mv`):
- `token`
- `ca.crt`
- `api-server`: the kubeconfig's server URL, with `127.0.0.1`/`localhost` rewritten to `host.docker.internal`

Prometheus re-reads `credentials_file` on every request, so a redeploy's new token is used without a restart. `deploy.sh --teardown` leaves the files in place. The token is revoked anyway when the Secret is deleted. `.metrics/` is added to `.gitignore`.
- If `api-server` or `ca.crt` changed, which only happens when the kind cluster itself is recreated, `deploy.sh` prints a hint to run `./metrics.sh reload`. It never calls `metrics.sh` itself, so the two concerns stay separate.

### D7. The Prometheus config is rendered from a template
`metrics/prometheus.yml.tmpl` is rendered by `metrics.sh` into `.metrics/prometheus.yml`. It fills in:
- the API server address from `.metrics/k8s/api-server`
- the namespace (`NAMESPACE`, default `concurrent-transactions`, the same as in `deploy.sh`)
- the TLS server name
- a `remote_write` block, only when `VM_REMOTE_WRITE_URL` is set, or set implicitly by `--local-vm` to `http://victoriametrics:8428/api/v1/write`

Prometheus doesn't expand environment variables in `remote_write` or `kubernetes_sd_configs`, so rendering the config is the simplest option. `metrics.sh up` without `.metrics/k8s/` still starts Prometheus, but with no Kubernetes scrape job, and prints a hint to run `./deploy.sh` first. That way the store can run with no cluster at all.

### D8. Forwarding to VictoriaMetrics and the check before removal
`remote_write` reads from the WAL, so samples Prometheus received by remote write (k6) are forwarded too, and short outages are caught up from the WAL (about 2h by default).

`metrics.sh forwarding-status` queries Prometheus's own metrics. It reports "caught up" when both of these hold:
- `prometheus_remote_storage_samples_pending` is 0
- the gap between `prometheus_remote_storage_highest_timestamp_in_seconds` and `prometheus_remote_storage_queue_highest_sent_timestamp_seconds` is below 2 scrape intervals

The README tells developers to run this check before `metrics.sh reset`. It also says that data collected before forwarding was turned on is not sent (`remote_write` only covers the WAL window).

### D9. k6 pushes to Prometheus on localhost
The README documents `-o experimental-prometheus-rw` with `K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write` and `K6_PROMETHEUS_RW_TREND_STATS`. The existing `SUMMARY_FILE` flow is unchanged.

### D10. Reaching the API server from the container needs a check first
The kind API server certificate is expected to list `localhost`, `127.0.0.1` and `kubernetes` in its SANs, but not `host.docker.internal`. The plan is to connect to `host.docker.internal:<port>` with `tls_config.server_name: localhost`.
- A spike task checks this against the real Docker Desktop kind cluster before the chart and script work depends on it: `curl --resolve` from a container, with the token and CA.
- If it fails, the fallback order is:
  1. try another SAN as `server_name`
  2. attach the container to Docker Desktop's kind network and use the control-plane hostname
  3. last resort, documented as local-only: `insecure_skip_verify`

### D11. Management port 8090 serves health and Prometheus only
`management.server.port: 8090`. The exposed endpoints are `health` and `prometheus`, with the liveness and readiness groups enabled.
- Liveness has no database check, so a Postgres outage doesn't cause restart loops.
- Readiness becomes ready after the context has started, which is after Flyway migrations.
- The Helm probes switch to `httpGet` on the named `management` port.
- The socat proxy forwards only the Service's `http` port, so 8090 is reachable only through the API server's pod proxy.

### D12. Instrumentation sits outside the transaction
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

### D13. Measure lock wait inside the service, and classify database errors by SQLSTATE
- **Lock wait:** `transfer.lock.wait` wraps `accountDao.findByIdsForUpdate` in `TransferService.forTransfer`, with a try/finally so failures are timed too.
- **Database errors:** for an exception whose cause chain contains a `SQLException`, `TransferMetrics` takes the innermost one's `getSQLState()` and increments `transfer.db.errors{sqlstate}`, using `unknown` when there is none. This covers the 409 path (for example `23505`), deadlocks and serialization failures.
- **Meter names** (Micrometer → Prometheus): `transfers` → `transfers_total`, `transfer.duration` → `transfer_duration_seconds`, `transfer.lock.wait` → `transfer_lock_wait_seconds`, `transfer.db.errors` → `transfer_db_errors_total`. `percentiles-histogram` is enabled only for the two timers.

## Risks / Trade-offs

- [The TLS check against `host.docker.internal` may fail with the certificate's SANs] → The spike task in D10 runs first, with an ordered list of fallbacks.
- [Spring Boot 4 split Actuator and Micrometer into new module artifacts, so names from older docs may not resolve] → Confirm the coordinates against the Boot 4.1 reference first, and fail fast in the integration tests if `/actuator/prometheus` is missing.
- [Scraping through the API server proxy adds load and latency to the API server] → 2 targets every 5s is negligible. Scrape timing includes one extra hop, which doesn't affect the metric values.
- [After a cluster teardown, discovery fails and all targets disappear or go down] → This is expected and visible as `up` and SD error metrics. History is unaffected, and scraping resumes after the next `deploy.sh` (spec: credentials follow redeploys).
- [The token sits in a local file] → `.metrics/` is git-ignored and the files have mode 600. The token only grants pod read and proxy access in one namespace, and is revoked on teardown.
- [The pod proxy can reach any port of any pod in the namespace (`pods/proxy`), not just 8090] → Acceptable for a local test namespace. Note it in the README. A tighter scope would need per-pod `resourceNames`, which change on every rollout.
- [The VictoriaMetrics URL can be set after data has already been collected] → The README states that older data is not backfilled. `forwarding-status` only vouches for data that has gone through the WAL.
- [`metrics.sh reset` deletes data] → It needs confirmation or `--yes`, and its prompt suggests `forwarding-status` first.

## Migration Plan

1. Deploy the app changes with `./deploy.sh`. The app rolls out with HTTP probes and the scrape identity, and `.metrics/k8s/` is written.
2. Run `./metrics.sh up`, or `./metrics.sh up --local-vm`. Check that 2 `up` targets named after the pods appear in `localhost:9090`.
3. To roll back: `helm rollback app` restores the TCP probes and removes the scrape identity, and `./metrics.sh down` stops collection. Volumes stay until `./metrics.sh reset`.

## Open Questions

- The exact retention values (for example 15d and 2GB). They are set in the Compose file and can be tuned without changing the specs.
- The Prometheus and VictoriaMetrics image tags to pin. Pick the current stable releases at implementation time.
