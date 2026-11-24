# Proposal

## Why

The project exists to show that transfers stay correct under contention, but a run's only output today is the k6 summary on the client: there is no server-side view of lock waits, idempotent replays, database errors or per-replica behavior while a load test runs. Adding metrics now gives every k6 run a server-side timeline. Keeping the metrics store outside the cluster means history survives cluster teardowns and can be compared across runs. It can also be forwarded to long-term storage before the local store is removed.

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
- **Prometheus runs in Docker, outside the cluster.** A new `metrics.sh` script and its Docker Compose stack manage it. Its lifecycle is separate from `deploy.sh`, and its data lives in a Docker volume that only an explicit reset removes. It:
  - discovers app pods through the Kubernetes API and scrapes each one every 5s through the API server's pod proxy, with the pod name as `instance`
  - accepts remote write, so k6 can push its client-side metrics to `localhost` with no port-forward
  - optionally forwards everything it ingests to VictoriaMetrics by remote write, for long-term storage. The README documents how to check that forwarding has caught up before Prometheus is removed.
- The app chart adds a scrape identity: a ServiceAccount whose Role only lets it list and watch pods and use the pod proxy in the app's namespace, plus a token Secret for it.
- After each install, `deploy.sh` writes that identity's token, the cluster CA and the API server address to a git-ignored local directory that Prometheus reads. `deploy.sh` never starts, stops or deletes Prometheus or its data.
- The README documents the metrics commands, example queries, the optional k6 remote-write output, the VictoriaMetrics forwarding setup and the safe-removal check.

## Capabilities

### New Capabilities
- `transfer-metrics`: transfer-specific metrics the service exposes (outcomes, latency, lock wait, database errors), with low-cardinality tags and outcomes recorded after commit.
- `metrics-collection`: collecting, storing and querying metrics from a Prometheus server outside the cluster. It scrapes every replica through the Kubernetes API with a least-privilege identity, keeps history independently of the cluster, accepts remote write from k6, and optionally forwards to VictoriaMetrics.
- `service-health`: HTTP health endpoints that the Kubernetes probes use to decide whether the service has started, is ready and is alive.

### Modified Capabilities
<!-- None: the project has no existing specs. -->

## Impact

- **Dependencies:** `build.gradle` gains the Actuator starter and `micrometer-registry-prometheus`. The exact artifact names must be checked against Spring Boot 4's modular starters.
- **Code:** the `transfer` package (instrumentation outside the `@Transactional` boundary, lock-wait timing around `AccountDao.findByIdsForUpdate`, SQLSTATE classification), and `application.yaml` (management port and exposed endpoints).
- **Helm:** `helm/concurrent-transactions` gains a management port, HTTP probes, and the scrape identity (ServiceAccount, Role, RoleBinding, token Secret). No metrics workload runs in the cluster.
- **New local tooling:** `metrics.sh`, a `metrics/` directory (Compose file and Prometheus config template), and a git-ignored `.metrics/` directory for the generated config and credentials.
- **Scripts and docs:** `deploy.sh` (writes the scrape credentials), `.gitignore` and `README.md`.
- **Local resources:** one Prometheus container (plus an optional local VictoriaMetrics container) and their Docker volumes. They persist until reset explicitly.
- **Out of scope:**
  - Grafana and alerting
  - pushing metrics from the app
  - scraping the Docker Compose app in `docker-compose.yaml`
  - backfilling data collected before forwarding to VictoriaMetrics was turned on
