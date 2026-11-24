# Spec Delta

## Purpose

Collects, stores and serves the service's metrics from a Prometheus server that runs outside the Kubernetes cluster. Its lifecycle is independent of the cluster, it scrapes every replica through the Kubernetes API, and it can forward data to VictoriaMetrics for long-term storage.

## ADDED Requirements

### Requirement: Metrics server runs outside the cluster
A single Prometheus server SHALL run as a local Docker container, started and stopped by its own documented commands. `./deploy.sh` and `./deploy.sh --teardown` SHALL NOT start, stop or delete it or its data.

#### Scenario: Start the metrics server
- **WHEN** a developer runs the documented start command
- **THEN** Prometheus is running in Docker and its UI and API answer on a localhost port, with no port-forward

#### Scenario: Cluster deploy does not touch it
- **WHEN** `./deploy.sh` or `./deploy.sh --teardown` runs while the metrics server is running
- **THEN** the metrics server keeps running with its data unchanged

### Requirement: Every replica is scraped through the Kubernetes API
The metrics server SHALL discover the service's pods through the Kubernetes API and scrape each pod's management port through the API server's pod proxy, not through a Service. Each replica's series SHALL carry its pod name as `instance`.

#### Scenario: Two replicas
- **WHEN** the service runs with 2 replicas
- **THEN** the metrics server has 2 scrape targets for the service, `up` is 1 for each, and their `instance` labels are the two pod names

#### Scenario: Replica stops
- **WHEN** a replica is terminated or stops responding
- **THEN** within two scrape intervals, its target is either gone or reported with `up` 0

#### Scenario: Scaling up
- **WHEN** the replica count is increased
- **THEN** the new replicas are scraped without any change to the metrics server's configuration

#### Scenario: Only the service's pods are scraped
- **WHEN** other pods (Postgres, speedbump, the TCP proxy) run in the same namespace
- **THEN** they are not scrape targets

### Requirement: Scraping uses a least-privilege cluster identity
The cluster SHALL provide a dedicated identity for scraping, allowed only to list and watch pods and to use the pod proxy in the service's namespace. The metrics server SHALL use that identity, not the developer's kubeconfig credentials.

#### Scenario: Scrape identity's permissions
- **WHEN** the scrape identity's permissions are checked
- **THEN** it can list and watch pods and get `pods/proxy` in the service's namespace, and is denied anything else, such as reading Secrets or acting in other namespaces

#### Scenario: Developer credentials are not used
- **WHEN** the metrics server's configuration and mounted files are inspected
- **THEN** they contain no credentials from the developer's kubeconfig

### Requirement: Scrape credentials follow cluster redeploys
`./deploy.sh` SHALL write the scrape identity's current credentials to a local, git-ignored location that the metrics server reads. A running metrics server SHALL pick up new credentials without being restarted.

#### Scenario: Redeploy issues new credentials
- **WHEN** the cluster is torn down and redeployed while the metrics server keeps running
- **THEN** scraping resumes within a minute of the deploy finishing, without restarting the metrics server

#### Scenario: Credentials are not committed
- **WHEN** `git status` runs after a deploy
- **THEN** the credentials file does not appear as an untracked or modified file

### Requirement: Scrape interval suits short load tests
The metrics server SHALL scrape the service at most every 5 seconds.

#### Scenario: One-minute load test
- **WHEN** a k6 run lasts one minute
- **THEN** at least 12 samples per replica are stored for each service metric during the run

### Requirement: History is independent of the cluster
The metrics server's data SHALL survive cluster teardown and redeploy, and restarts of the metrics server itself. The data SHALL be deleted only by an explicit, documented command.

#### Scenario: Cluster teardown then redeploy
- **WHEN** metrics are collected, `./deploy.sh --teardown` runs, and then `./deploy.sh` runs again
- **THEN** queries for the period before the teardown return the earlier data

#### Scenario: Cluster is down
- **WHEN** the cluster has been torn down and not redeployed
- **THEN** the metrics server still answers queries for the stored history

#### Scenario: Metrics server restart
- **WHEN** the metrics server is stopped and started again with the documented commands
- **THEN** the earlier data is still returned by queries

### Requirement: Bounded local retention
The metrics server SHALL delete local data older than a configured retention period, or beyond a configured size, so local disk use is bounded.

#### Scenario: Old data expires locally
- **WHEN** local data is older than the retention period
- **THEN** the metrics server no longer returns it, though long-term storage may still have it

### Requirement: Forwarding to VictoriaMetrics for long-term storage
When a VictoriaMetrics remote-write URL is configured, the metrics server SHALL forward every sample it ingests (scraped or received by remote write) to that URL. When no URL is configured, everything else in this spec SHALL still work.

#### Scenario: Long-term storage configured
- **WHEN** a VictoriaMetrics URL is configured and a load test runs
- **THEN** the same service and k6 series for that run can be queried in VictoriaMetrics

#### Scenario: Long-term storage not configured
- **WHEN** no VictoriaMetrics URL is configured
- **THEN** the metrics server starts, scrapes and serves queries normally

#### Scenario: Short VictoriaMetrics outage
- **WHEN** VictoriaMetrics is unreachable for a few minutes and then recovers
- **THEN** samples ingested during the outage are delivered to VictoriaMetrics after it recovers

### Requirement: The metrics server can be removed without losing data
Before the metrics server and its data are removed, a developer SHALL be able to confirm that forwarding to VictoriaMetrics has caught up. The README SHALL document that check and the removal command.

#### Scenario: Remove after forwarding caught up
- **WHEN** the documented check shows that forwarding has caught up, and the metrics server and its data are removed
- **THEN** every series it had forwarded can still be queried in VictoriaMetrics

#### Scenario: Data from before forwarding was configured
- **WHEN** VictoriaMetrics was configured after some data had already been collected
- **THEN** the README states that older local data is not backfilled automatically

### Requirement: Accepts load-test metrics by remote write
The metrics server SHALL accept Prometheus remote-write requests on its localhost port, so k6 can push its client-side metrics into the same store with no port-forward. The README SHALL document the k6 options that do this.

#### Scenario: k6 pushes its metrics
- **WHEN** k6 runs with the documented remote-write output
- **THEN** k6 metrics from that run can be queried next to the service's metrics

### Requirement: Query UI and example queries are documented
The README SHALL document how to start, stop and reset the metrics server, the URL of its UI, and example queries for transfer outcomes, lock-wait percentiles and per-replica `up`.

#### Scenario: Example queries
- **WHEN** a developer runs the documented example queries after a load test
- **THEN** each query returns data for that run
