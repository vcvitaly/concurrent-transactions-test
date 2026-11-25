# Proposal

## Why

The project exists to show that transfers stay correct under contention, but a run's only output today is the k6 summary on the client: there is no server-side view of lock waits, idempotent replays, database errors or per-replica behavior while a load test runs. Adding metrics now gives every k6 run a server-side timeline. Keeping the metrics store outside the cluster means history survives cluster teardowns and runs can be compared over time.

## What Changes

- The app exposes metrics in Prometheus format, through Spring Boot Actuator and Micrometer, on a separate management port (8090) that is not reachable through the socat proxy or speedbump.
- The app records metrics specific to transfers:
  - `transfers_total` counter, tagged by outcome (`created`, `replayed`, `insufficient_funds`, `not_found`, `invalid`, `error`), for requests that reach transfer processing. An outcome is recorded only after the transaction has committed or rolled back.
  - `transfer_duration_seconds` timer with a histogram, tagged by outcome, covering transfer processing including the commit.
  - `transfer_lock_query_seconds` timer for the `SELECT ... FOR UPDATE` lock query, including any wait for row locks.
  - `transfer_db_errors_total` counter, tagged by PostgreSQL SQLSTATE (for example deadlock `40P01`, serialization failure `40001`).
  - Tags never include account IDs or idempotency keys.
- Built-in Micrometer metrics (HTTP server, Hikari pool, JVM) are exposed with no extra work.
- The app's startup, readiness and liveness probes switch from TCP checks to bare `/livez` and `/readyz` statuses on the API port, so they exercise the API listener. Readiness reflects the app's lifecycle and doesn't depend on Postgres. Detailed health stays on the management port.
- **A disposable Prometheus runs in the cluster** (new hand-rolled `helm/prometheus` chart). It scrapes every app replica every 5s through a headless Service (DNS discovery, no RBAC), keeps only short-lived local data on an `emptyDir`, and streams everything by `remote_write` to the long-term store. Its UI can be reached by port-forward to watch a run live.
- **VictoriaMetrics runs in Docker, outside the cluster,** as the long-term store. A new `metrics.sh` script and its Compose file manage it, separately from `deploy.sh`. Its data lives in a Docker volume that only an explicit reset deletes. k6 can push its client-side metrics to it at `localhost:8428`.
- The store listens only on `127.0.0.1` by default. Exposing it beyond loopback needs an explicit `METRICS_BIND_ADDRESS` and prints a warning.
- `deploy.sh` installs Prometheus. Before removing it on `--teardown`, it drains forwarding on a best-effort basis and reports pending, failed and dropped samples. Prometheus also gets enough grace period to flush on shutdown. `deploy.sh` never touches the VictoriaMetrics store.
- The README documents the store lifecycle, both UIs, example queries and the optional k6 remote-write output.

## Capabilities

### New Capabilities
- `transfer-metrics`: transfer-specific metrics the service exposes (outcomes, processing time, lock-query time, database errors), with low-cardinality tags and outcomes recorded after commit.
- `metrics-collection`: a disposable in-cluster Prometheus that scrapes every replica and streams to a loopback-only VictoriaMetrics store outside the cluster. The store keeps history independently of the cluster and accepts k6 remote write. Forwarding is drained on a best-effort basis before teardown.
- `service-health`: liveness and lifecycle-based readiness statuses on the API port that the Kubernetes probes use, with detailed health kept on the management port.

### Modified Capabilities
<!-- None: the project has no existing specs. -->

## Impact

- **Dependencies:** `build.gradle` gains the Actuator starter and `micrometer-registry-prometheus`. The exact artifact names must be checked against Spring Boot 4's modular starters.
- **Code:** the `transfer` package (instrumentation outside the `@Transactional` boundary, lock-query timing around `AccountDao.findByIdsForUpdate`, SQLSTATE classification), and `application.yaml` (management port, exposed endpoints, probe paths on the API port, graceful shutdown).
- **Helm:** `helm/concurrent-transactions` gains a management port, HTTP probes and a headless metrics Service. A new `helm/prometheus` chart is added. No RBAC and no persistent volume.
- **New local tooling:** `metrics.sh` and `metrics/compose.yaml` (VictoriaMetrics single-node).
- **Scripts and docs:** `deploy.sh` (Prometheus install, teardown with a best-effort forwarding drain) and `README.md`.
- **Networking:** pods reach the store at `http://host.docker.internal:8428`. This was checked from a pod in the Docker Desktop kind cluster.
- **Out of scope:**
  - Grafana and alerting
  - pushing metrics from the app
  - scraping the Docker Compose app in `docker-compose.yaml`
  - backfilling data that was scraped while the store was down for longer than the collector's buffer
