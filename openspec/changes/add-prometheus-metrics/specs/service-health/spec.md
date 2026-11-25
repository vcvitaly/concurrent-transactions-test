# Spec Delta

## Purpose

Lets Kubernetes tell whether a service replica has started, can take traffic and is still alive, using HTTP health checks on the same listener that serves the API, instead of only checking that the port is open.

## ADDED Requirements

### Requirement: Liveness reflects the application only
The service SHALL expose a liveness status that returns 200 while the application is running. It SHALL NOT depend on the database or any other external system.

#### Scenario: Running replica
- **WHEN** the liveness status is requested on a running replica
- **THEN** it responds 200

#### Scenario: Database outage
- **WHEN** the database is unreachable
- **THEN** the liveness status still responds 200, so Kubernetes does not restart the replica in a loop

### Requirement: Readiness reflects the application lifecycle
The service SHALL expose a readiness status that returns 200 only after startup has finished, including database migrations, and a non-2xx status before that and while the replica is shutting down. Readiness SHALL NOT depend on the database. A database outage SHALL show up as failed requests, not as replicas being removed from the Service.

#### Scenario: During startup
- **WHEN** the readiness status is requested before startup and migrations have finished
- **THEN** it responds with a non-2xx status

#### Scenario: Ready replica
- **WHEN** the replica has started
- **THEN** the readiness status responds 200

#### Scenario: Shutting down
- **WHEN** the replica has received a termination signal and is shutting down
- **THEN** the readiness status responds with a non-2xx status

#### Scenario: Database outage
- **WHEN** the database becomes unreachable while the replica is running
- **THEN** the readiness status still responds 200, and transfer requests fail with server errors instead of being refused at the connection

### Requirement: Probes check the API listener
The service SHALL serve the liveness and readiness statuses on the API port, so the probes exercise the listener that serves API traffic. The startup and readiness probes SHALL use the readiness status, and the liveness probe SHALL use the liveness status, instead of TCP socket checks.

#### Scenario: Rolling update
- **WHEN** a new version is rolled out
- **THEN** a new pod receives Service traffic only after the readiness status on its API port responds 200

#### Scenario: API listener not serving
- **WHEN** the API port does not accept HTTP requests while the management port still does
- **THEN** the readiness probe fails

### Requirement: Only bare probe statuses on the API port
On the API port, the service SHALL expose only the liveness and readiness statuses, with no component details. Detailed health information and metrics SHALL be served only on the management port.

#### Scenario: Request through the proxy
- **WHEN** a client requests the liveness or readiness path through the TCP proxy or speedbump
- **THEN** the response contains only an overall status, with no component details

#### Scenario: Detailed health stays private
- **WHEN** a client requests the detailed health or metrics path on the API port
- **THEN** no health details or metrics are returned
