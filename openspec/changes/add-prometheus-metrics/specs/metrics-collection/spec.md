# Spec Delta

## Purpose

Collects, stores and serves the service's metrics inside the cluster, so every replica can be queried during and after a load test and history can be compared across deploys.

## ADDED Requirements

### Requirement: Metrics server is deployed with the stack
The deploy script SHALL install or upgrade a single Prometheus server in the target namespace, alongside the database and the service.

#### Scenario: Fresh deploy
- **WHEN** `./deploy.sh` runs against a namespace with no metrics server
- **THEN** a Prometheus server is running and ready in that namespace when the script finishes

#### Scenario: Repeated deploy
- **WHEN** `./deploy.sh` runs again with the metrics server already installed
- **THEN** the metrics server is upgraded in place and its stored metrics are kept

### Requirement: Every replica is scraped
The metrics server SHALL scrape each service replica individually, not through the load-balanced Service, and each replica's series SHALL carry a distinct `instance` label. Replicas SHALL be discovered automatically as they start and stop.

#### Scenario: Two replicas
- **WHEN** the service runs with 2 replicas
- **THEN** the metrics server has 2 healthy scrape targets for the service, and `up` is 1 for each

#### Scenario: Replica stops
- **WHEN** a replica is terminated or stops responding
- **THEN** within two scrape intervals, its target is no longer reported as up

#### Scenario: Scaling up
- **WHEN** the replica count is increased
- **THEN** the new replicas are scraped without any change to the metrics server's configuration

### Requirement: Scrape interval suits short load tests
The metrics server SHALL scrape the service at most every 5 seconds.

#### Scenario: One-minute load test
- **WHEN** a k6 run lasts one minute
- **THEN** at least 12 samples per replica are stored for each service metric during the run

### Requirement: History survives teardown
`./deploy.sh --teardown` SHALL remove the metrics server but keep its stored data. The next `./deploy.sh` SHALL serve the earlier data again. The database volume is still deleted.

#### Scenario: Teardown then redeploy
- **WHEN** metrics are collected, `./deploy.sh --teardown` runs, and then `./deploy.sh` runs again
- **THEN** queries for the period before the teardown return the earlier data

#### Scenario: Teardown output
- **WHEN** `./deploy.sh --teardown` finishes
- **THEN** its output says that the metrics volume was kept and names it, so it can be deleted by hand

### Requirement: Bounded retention
The metrics server SHALL delete data older than a configured retention period, so the volume does not grow without limit.

#### Scenario: Old data expires
- **WHEN** data is older than the retention period
- **THEN** it is no longer returned by queries

### Requirement: Metrics UI is reachable by port-forward
The metrics server SHALL expose its query UI and API through a cluster Service, and the README SHALL document the port-forward command and example queries for transfer outcomes and lock-wait percentiles.

#### Scenario: Port-forward
- **WHEN** a developer runs the documented port-forward command
- **THEN** the query UI opens on localhost and the example queries return data for a recent run

### Requirement: Accepts load-test metrics by remote write
The metrics server SHALL accept Prometheus remote-write requests, so k6 can push its client-side metrics into the same store. The README SHALL document the k6 options that do this.

#### Scenario: k6 pushes its metrics
- **WHEN** k6 runs with the documented remote-write output through the port-forward
- **THEN** k6 metrics from that run can be queried next to the service's metrics
