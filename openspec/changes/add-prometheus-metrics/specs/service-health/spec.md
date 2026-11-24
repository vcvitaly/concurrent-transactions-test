# Spec Delta

## Purpose

Lets Kubernetes tell whether a service replica has started, can take traffic and is still alive, using HTTP health checks instead of only checking that the port is open.

## ADDED Requirements

### Requirement: Liveness endpoint
The service SHALL expose an HTTP liveness endpoint on the management port. It SHALL return 200 while the application is running, and SHALL NOT fail because the database is unreachable.

#### Scenario: Running replica
- **WHEN** the liveness endpoint is requested on a running replica
- **THEN** it responds 200

#### Scenario: Database outage
- **WHEN** the database is unreachable
- **THEN** the liveness endpoint still responds 200, so Kubernetes does not restart the replica in a loop

### Requirement: Readiness endpoint
The service SHALL expose an HTTP readiness endpoint on the management port. It SHALL return 200 only after startup has finished, including database migrations, and a non-2xx status while the replica cannot serve requests.

#### Scenario: During startup
- **WHEN** the readiness endpoint is requested before startup and migrations have finished
- **THEN** it responds with a non-2xx status

#### Scenario: Ready replica
- **WHEN** the replica has started and can serve requests
- **THEN** the readiness endpoint responds 200

### Requirement: Kubernetes probes use the health endpoints
The service's startup and readiness probes SHALL use the readiness endpoint, and its liveness probe SHALL use the liveness endpoint, instead of TCP socket checks.

#### Scenario: Rolling update
- **WHEN** a new version is rolled out
- **THEN** a new pod receives Service traffic only after its readiness endpoint responds 200

### Requirement: Health endpoints are not exposed through the API path
The health endpoints SHALL be served only on the management port, which the TCP proxy and the latency proxy do not forward.

#### Scenario: Request through the proxy
- **WHEN** a client requests the health path through the TCP proxy or speedbump
- **THEN** it does not reach a health endpoint
