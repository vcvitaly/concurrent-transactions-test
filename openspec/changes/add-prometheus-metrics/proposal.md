# Proposal

## Why

The project exists to show that transfers stay correct under contention, but a run's only output today is the k6 summary on the client: there is no server-side view of lock waits, idempotent replays, database errors or per-replica behavior while a load test runs. Adding metrics now gives every k6 run a server-side timeline, and the history kept across redeploys lets runs be compared with each other.

## What Changes

- The app exposes metrics in Prometheus format, through Spring Boot Actuator and Micrometer, on a separate management port (8090) that is not reachable through the socat proxy or speedbump.
- The app records metrics specific to transfers:
  - `transfers_total` counter, tagged by outcome (`created`, `replayed`, `insufficient_funds`, `not_found`, `invalid`, `error`). An outcome is recorded only after the transaction has committed or rolled back.
  - `transfer_duration_seconds` timer with a histogram, tagged by outcome.
  - `transfer_lock_wait_seconds` timer for the time spent acquiring the `FOR UPDATE` row locks.
  - `transfer_db_errors_total` counter, tagged by PostgreSQL SQLSTATE (for example deadlock `40P01`, serialization failure `40001`).
  - Tags never include account IDs or idempotency keys.
- Built-in Micrometer metrics (HTTP server, Hikari pool, JVM) are exposed with no extra work.
- The app's startup, readiness and liveness probes switch from TCP checks to the Actuator HTTP health endpoints.
- A new hand-rolled Helm chart `helm/prometheus` deploys a single Prometheus server. It:
  - scrapes every app replica every 5s, finding pods through a headless Service (DNS discovery, no RBAC)
  - stores its data on a persistent volume with time-based retention
  - accepts remote write, so k6 can optionally push its client-side metrics.
- `deploy.sh` installs or upgrades Prometheus. `--teardown` uninstalls it but **keeps the Prometheus volume**, so metrics history survives teardown and is picked up again by the next deploy. Only the database volume is still deleted.
- The README documents port-forwarding the Prometheus UI, a few starter queries, and the optional k6 remote-write output.

## Capabilities

### New Capabilities
- `transfer-metrics`: transfer-specific metrics the service exposes (outcomes, latency, lock wait, database errors), with low-cardinality tags and outcomes recorded after commit.
- `metrics-collection`: collecting, storing and querying metrics in the cluster: a Prometheus deployment that scrapes every replica, keeps history across teardown and redeploys, and accepts remote write from k6.
- `service-health`: HTTP health endpoints that the Kubernetes probes use to decide whether the service has started, is ready and is alive.

### Modified Capabilities
<!-- None: the project has no existing specs. -->

## Impact

- **Dependencies:** `build.gradle` gains the Actuator starter and `micrometer-registry-prometheus`. The exact artifact names must be checked against Spring Boot 4's modular starters.
- **Code:** the `transfer` package (instrumentation outside the `@Transactional` boundary, lock-wait timing around `AccountDao.findByIdsForUpdate`, SQLSTATE classification), and `application.yaml` (management port and exposed endpoints).
- **Helm:** `helm/concurrent-transactions` gains a management port, a headless metrics Service and HTTP probes in `values.yaml` and its templates. A new `helm/prometheus` chart is added.
- **Scripts and docs:** `deploy.sh` (new release, teardown that keeps the volume) and `README.md`.
- **Cluster resources:** one more pod (Prometheus, roughly 100–200 Mi of memory) and one PVC that persists until it is deleted by hand.
- **Out of scope:** Grafana, alerting, and pushing metrics from the app.
