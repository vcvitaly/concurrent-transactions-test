# Spec Delta

## Purpose

Collects the service's metrics with a disposable Prometheus inside the cluster and streams them to a VictoriaMetrics store in Docker outside the cluster. Load-test history then survives cluster teardowns and can be compared across runs.

## ADDED Requirements

### Requirement: In-cluster collector is deployed with the stack
`./deploy.sh` SHALL install or upgrade a single Prometheus collector in the target namespace, and `./deploy.sh --teardown` SHALL remove it. The collector SHALL keep no persistent volume. Its local data is disposable.

#### Scenario: Fresh deploy
- **WHEN** `./deploy.sh` runs against a namespace with no collector
- **THEN** a Prometheus collector is running and ready in that namespace when the script finishes

#### Scenario: Teardown leaves nothing behind
- **WHEN** `./deploy.sh --teardown` finishes
- **THEN** no collector pod, Service or PersistentVolumeClaim remains in the namespace

### Requirement: Every replica is scraped
The collector SHALL scrape each service replica individually, not through the load-balanced Service, and each replica's series SHALL carry a distinct `instance` label. Replicas SHALL be discovered automatically, and other pods in the namespace SHALL NOT be scraped.

#### Scenario: Two replicas
- **WHEN** the service runs with 2 replicas
- **THEN** the collector has 2 scrape targets for the service, and `up` is 1 for each

#### Scenario: Replica stops
- **WHEN** a replica is terminated or stops responding
- **THEN** within two scrape intervals, its target is either gone or reported with `up` 0

#### Scenario: Scaling up
- **WHEN** the replica count is increased
- **THEN** the new replicas are scraped without any change to the collector's configuration

#### Scenario: Other pods are not scraped
- **WHEN** Postgres, speedbump and the TCP proxy run in the same namespace
- **THEN** none of them is a scrape target

### Requirement: Scrape interval suits short load tests
The collector SHALL scrape the service every 5 seconds by default. The interval SHALL be configurable.

#### Scenario: Steady-state cadence
- **WHEN** both replicas have been discovered and healthy for at least one minute
- **THEN** `count_over_time(up{job="concurrent-transactions"}[1m])` in the long-term store is at least 11 for each replica

#### Scenario: Transfer series appear when their event happens
- **WHEN** a test causes a transfer with a given outcome
- **THEN** the matching `transfers_total` series is in the long-term store within two scrape intervals plus the forwarding delay

### Requirement: Long-term store runs outside the cluster
A single VictoriaMetrics store SHALL run as a local Docker container, started, stopped and reset by its own documented commands. `./deploy.sh` and `./deploy.sh --teardown` SHALL NOT start, stop or delete it or its data.

#### Scenario: Start the store
- **WHEN** a developer runs the documented start command
- **THEN** VictoriaMetrics is running in Docker, and its UI and API answer on a localhost port with no port-forward

#### Scenario: Cluster deploy does not touch it
- **WHEN** `./deploy.sh` or `./deploy.sh --teardown` runs while the store is running
- **THEN** the store keeps running with its data unchanged

### Requirement: Collector streams everything to the long-term store
The collector SHALL forward every sample it scrapes to the long-term store by Prometheus remote write. The URL SHALL be configurable and default to the local store as seen from inside the cluster. If the store is unreachable, deploys and scraping SHALL still work.

#### Scenario: Data arrives in the store
- **WHEN** the store is running and a load test runs
- **THEN** the service's series for that run can be queried in the store within a minute

#### Scenario: Store not running
- **WHEN** `./deploy.sh` runs while the store is stopped
- **THEN** the deploy succeeds and the collector scrapes normally

#### Scenario: Short store outage
- **WHEN** the store is unreachable for a few minutes while the collector keeps running, and then recovers
- **THEN** samples scraped during the outage are delivered to the store after it recovers

### Requirement: Teardown drains forwarding on a best-effort basis
Before removing the collector, `./deploy.sh --teardown` SHALL wait for its forwarding queue to drain, with a timeout on each status check and on the whole wait. Teardown SHALL then report pending, failed and dropped sample counts, and warn but continue if the queue hasn't drained. Draining is best effort: it doesn't guarantee delivery.

#### Scenario: Store reachable at teardown
- **WHEN** a load test has just finished and `./deploy.sh --teardown` runs with the store running
- **THEN** teardown reports zero pending, failed and dropped samples, and the last sample of `up{job="concurrent-transactions"}` in the store is within two scrape intervals of when the app was removed

#### Scenario: Store unreachable at teardown
- **WHEN** `./deploy.sh --teardown` runs while the store is stopped
- **THEN** teardown warns that forwarding didn't drain, prints the pending count, and finishes within the drain timeout plus the normal teardown time

#### Scenario: Collector status can't be read
- **WHEN** the collector doesn't answer a status check within its timeout
- **THEN** teardown warns that delivery couldn't be checked and continues

### Requirement: Collector flushes on shutdown
The collector SHALL be given time to flush its forwarding queue when it is stopped, by a termination grace period longer than its shutdown flush deadline.

#### Scenario: Collector removed with samples queued
- **WHEN** the collector is removed while samples are still queued and the store is reachable
- **THEN** the collector sends the queued samples before it exits, unless the flush deadline has passed

### Requirement: Store is local-only unless explicitly exposed
By default, the store SHALL listen only on the host's loopback interface. Listening on other interfaces SHALL need an explicit bind-address setting, and the start command SHALL print a warning when that setting exposes the store beyond loopback.

#### Scenario: Default start
- **WHEN** the store is started with the documented command and no bind-address setting
- **THEN** its port is not reachable from another machine on the local network

#### Scenario: Collector reaches the loopback-bound store
- **WHEN** the store runs with the default binding and the collector is running
- **THEN** remote-written samples from the collector can be read back from the store

#### Scenario: Explicit exposure
- **WHEN** the store is started with a bind address other than loopback
- **THEN** the start command prints a warning that the store's API, which has no authentication, is reachable from the network

### Requirement: History is independent of the cluster
The store's data SHALL survive cluster teardown and redeploy, and restarts of the store itself. The data SHALL be deleted only by an explicit, documented reset command, which asks for confirmation unless told not to.

#### Scenario: Cluster teardown then redeploy
- **WHEN** metrics are collected, `./deploy.sh --teardown` runs, and then `./deploy.sh` runs again
- **THEN** queries for the period before the teardown still return the earlier data

#### Scenario: Cluster is down
- **WHEN** the cluster has been torn down and not redeployed
- **THEN** the store still answers queries for the stored history

#### Scenario: Store restart
- **WHEN** the store is stopped and started again with the documented commands
- **THEN** the earlier data is still returned by queries

#### Scenario: Reset asks first
- **WHEN** the reset command runs without the no-confirmation flag
- **THEN** it asks for confirmation before deleting any data

### Requirement: Bounded retention
The store SHALL delete data older than a configured retention period. The collector's local data SHALL be capped in both time and disk size.

#### Scenario: Old data expires
- **WHEN** data in the store is older than the retention period
- **THEN** it is no longer returned by queries

### Requirement: Live view while the cluster is up
The collector SHALL expose its query UI through a cluster Service, so a run can be watched live with a port-forward even when the store isn't running.

#### Scenario: Port-forward during a run
- **WHEN** a developer runs the documented port-forward command during a load test
- **THEN** the collector's UI opens on localhost and shows the run's service metrics

### Requirement: k6 pushes to the long-term store
The store SHALL accept Prometheus remote-write requests on its localhost port, so k6 can push its client-side metrics with no port-forward. The README SHALL document the k6 options that do this.

#### Scenario: k6 pushes its metrics
- **WHEN** k6 runs with the documented remote-write output and the store is running
- **THEN** k6 metrics from that run can be queried in the store next to the service's metrics

### Requirement: Metrics usage is documented
The README SHALL document the store's start, stop and reset commands, the store and collector UIs, and example queries for transfer outcomes, lock-wait percentiles and per-replica `up`.

#### Scenario: Example queries
- **WHEN** a developer runs the documented example queries in the store after a load test
- **THEN** each query returns data for that run
