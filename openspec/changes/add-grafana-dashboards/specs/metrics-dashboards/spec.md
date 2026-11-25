# Spec Delta

## Purpose

Provides Grafana as the place to save queries and dashboards over the long-term metrics store. Dashboards worth keeping are versioned in the repo, and editing stays possible in the UI.

## ADDED Requirements

### Requirement: Grafana runs with the long-term store
A Grafana instance SHALL run in Docker outside the cluster, next to the long-term store. The store's documented start, stop and status commands SHALL also start, stop and report Grafana. `./deploy.sh` and `./deploy.sh --teardown` SHALL NOT start, stop or delete Grafana or its data.

#### Scenario: Start
- **WHEN** a developer runs the documented start command
- **THEN** Grafana answers on a localhost port with no port-forward, and the command prints its URL

#### Scenario: Status
- **WHEN** a developer runs the documented status command
- **THEN** it reports whether Grafana is healthy, separately from the store's health

#### Scenario: Grafana not healthy
- **WHEN** Grafana doesn't become healthy within the start timeout
- **THEN** the start command fails with an error naming Grafana

#### Scenario: Cluster deploy does not touch it
- **WHEN** `./deploy.sh` or `./deploy.sh --teardown` runs while Grafana is running
- **THEN** Grafana keeps running and its dashboards are unchanged

### Requirement: Store is the provisioned datasource
Grafana SHALL be provisioned with the long-term store as its default datasource, using a fixed identifier, with no manual setup. MetricsQL queries that the store accepts SHALL run through it.

#### Scenario: Fresh start
- **WHEN** Grafana starts with an empty data volume
- **THEN** the store is available as the default datasource, and `up{job="concurrent-transactions"}` returns the store's data for a period with stored history

#### Scenario: MetricsQL function
- **WHEN** a panel queries `max(tlast_over_time(up{job="concurrent-transactions"}[10y]))`
- **THEN** it returns the same value as the store's own query API

### Requirement: Committed dashboards are provisioned
Dashboard definitions committed in the repo SHALL be loaded into a dedicated repo folder in Grafana on start, with no manual import.

#### Scenario: Fresh clone
- **WHEN** Grafana starts with an empty data volume
- **THEN** every committed dashboard is present in the repo folder and its panels query the store

#### Scenario: Committed file changes
- **WHEN** a committed dashboard file is changed while Grafana is running
- **THEN** Grafana shows the changed dashboard within a minute, without a restart

### Requirement: Dashboards can be edited and saved in the UI
Dashboards in any folder, including the repo folder, SHALL be editable and savable in the Grafana UI. Dashboards outside the repo folder SHALL be kept only in Grafana's data and SHALL never be written to the repo.

#### Scenario: Edit a committed dashboard
- **WHEN** a developer edits a dashboard in the repo folder and saves it
- **THEN** the save succeeds, and the edit is still there after Grafana restarts, as long as its file hasn't changed

#### Scenario: Scratch dashboard
- **WHEN** a developer creates a dashboard outside the repo folder and exports dashboards
- **THEN** no file is written for it, and it is still there after Grafana restarts

### Requirement: Repo-folder dashboards can be exported to the repo
A documented export command SHALL write every dashboard in the repo folder to its committed definition file, one file per dashboard. The output SHALL be stable, so exporting an unchanged dashboard produces no diff.

#### Scenario: Export an edit
- **WHEN** a developer edits a repo-folder dashboard in the UI and runs the export command
- **THEN** its committed file contains the edit, and after a restart with an empty data volume the dashboard shows the edit

#### Scenario: Promote a scratch dashboard
- **WHEN** a dashboard is moved into the repo folder in the UI and the export command runs
- **THEN** a new committed file is written for it

#### Scenario: No changes
- **WHEN** the export command runs twice with no UI edits in between
- **THEN** the second run leaves every file unchanged

#### Scenario: Dashboard removed from the folder
- **WHEN** a committed file has no matching dashboard in the repo folder and the export command runs
- **THEN** the command reports that file and leaves it in place

#### Scenario: Grafana not running
- **WHEN** the export command runs while Grafana is not reachable
- **THEN** it fails with an error and changes no files

### Requirement: Grafana is local-only unless explicitly exposed
By default, Grafana SHALL listen only on the host's loopback interface and SHALL need no login. Listening on other interfaces SHALL use the same explicit bind-address setting as the store, and the start command's warning SHALL say that Grafana is then reachable with admin rights and no login.

#### Scenario: Default start
- **WHEN** the stack is started with no bind-address setting
- **THEN** Grafana opens on localhost with no login prompt, and its port is not reachable from another machine on the local network

#### Scenario: Explicit exposure
- **WHEN** the stack is started with a non-loopback bind address
- **THEN** the start command warns that Grafana is reachable from the network with admin rights and no login

### Requirement: Grafana's data persists independently of metrics data
Grafana's data SHALL survive cluster teardown and redeploy, restarts of the stack, and a reset of the metrics data. It SHALL be deleted only by the reset command with an explicit option to include Grafana, which asks for confirmation unless told not to.

#### Scenario: Stack restart
- **WHEN** the stack is stopped and started again with the documented commands
- **THEN** dashboards saved only in the UI are still there

#### Scenario: Metrics reset keeps dashboards
- **WHEN** the reset command runs without the Grafana option
- **THEN** dashboards saved only in the UI are still there after the next start

#### Scenario: Full reset
- **WHEN** the reset command runs with the Grafana option and is confirmed
- **THEN** Grafana's data is deleted, and after the next start only the committed dashboards are present

### Requirement: A dashboard for the documented queries is committed
The repo SHALL include a committed dashboard with panels for transfer outcomes, lock-wait percentiles and per-replica `up`, matching the README's example queries.

#### Scenario: After a load test
- **WHEN** a load test has run with the store and Grafana running, and the dashboard's time range covers the run
- **THEN** each of those panels shows data for the run

### Requirement: Grafana usage is documented
The README SHALL document Grafana's URL, the repo folder and how scratch dashboards differ from it, the export command, and that unexported UI edits to a repo-folder dashboard are overwritten when its committed file changes, so dashboards must be exported before pulling or switching branches.

#### Scenario: Following the docs
- **WHEN** a developer follows the README to save a query as a panel and export it
- **THEN** the dashboard's committed file contains that panel
