# Design

## Context

The metrics stack outside the cluster is one compose project (`metrics/compose.yaml`, project name `concurrent-transactions-metrics`), driven only by `metrics.sh`. It runs VictoriaMetrics on `${METRICS_BIND_ADDRESS:-127.0.0.1}:8428` with no authentication, and keeps its data in the named volume `victoriametrics-data`. `metrics.sh reset` runs `compose down --volumes`, which deletes every volume in the project. Adding a second volume would make reset delete it too, so reset has to change along with this work. `metrics.sh` already depends on `docker`, `curl` and `jq`.

See `proposal.md` for motivation.

## Goals / Non-Goals

**Goals:**
- A fresh clone and `./metrics.sh up` give a working Grafana with the datasource and the committed dashboards, with no clicks needed.
- Editing in the UI stays frictionless, and promoting work to git takes one command.
- Grafana's lifecycle is independent of both the cluster and the metrics data.

**Non-Goals:**
- Alerting, users and teams, or authentication beyond the loopback default.
- Running Grafana in the cluster or in `deploy.sh`.
- Syncing the other way automatically. Files are loaded at startup and on file change; the database is exported on demand.
- A separate store for "saved queries". A query is saved as a panel on a dashboard.

## Decisions

### Grafana runs in the existing metrics compose project
Grafana is added as a `grafana` service in `metrics/compose.yaml`, with a named volume `grafana-data`. It reaches the store at `http://victoriametrics:8428` over the compose network.
- *Alternative: a separate compose file or project.* This would isolate `down --volumes`, but it would mean two projects for `metrics.sh` to coordinate, and Grafana is useless without the store. Rejected; reset is fixed directly instead (see below).
- *Alternative: running it in the cluster.* Rejected: dashboards would disappear with every teardown, which is the opposite of the goal.

### Built-in Prometheus datasource, with a fixed uid
The datasource is provisioned from `metrics/grafana/provisioning/datasources/` with type `prometheus`, uid `victoriametrics`, and set as the default. VictoriaMetrics evaluates MetricsQL server-side, so functions such as `tlast_over_time` work through this type too. Exported dashboard JSON refers to the datasource by uid, so a fixed uid keeps committed dashboards portable.
- *Alternative: the VictoriaMetrics datasource plugin.* It adds MetricsQL-aware editing, but needs a plugin installed at container start. It can be added later without changing dashboards, as long as the uid is kept.

### Hybrid dashboard storage, with the "Repo" folder as the boundary
A file provider in `metrics/grafana/provisioning/dashboards/` loads `metrics/grafana/dashboards/*.json`, mounted read-only, into a folder named "Repo". It sets `allowUiUpdates: true` and a short `updateIntervalSeconds`. UI saves go to the database in `grafana-data`. Dashboards in any other folder are scratch work and never exported.
- *Alternative: the UI database only.* No versioning, and dashboards are lost with the volume.
- *Alternative: files only, with UI edits disabled.* This makes iterating painful. Both alternatives were rejected in favour of the hybrid.

### `metrics.sh export-dashboards`
This command uses Grafana's HTTP API (`/api/search?folderUIDs=<repo folder>` and `/api/dashboards/uid/<uid>`) through `curl` and `jq`. It writes each dashboard to `metrics/grafana/dashboards/<uid>.json`, with the volatile `id` and `version` fields removed, and keys sorted so diffs stay stable. A dashboard moved into "Repo" in the UI is exported like any other, which is how scratch work gets promoted. Files whose dashboard no longer exists in the folder are reported, not deleted, so deleting a file stays an explicit git action. The folder is looked up by a fixed folder uid set in the provider config, not by its title.

### Anonymous admin, loopback bind
Grafana is published on `${METRICS_BIND_ADDRESS:-127.0.0.1}:3000`. Anonymous auth is enabled with the `Admin` org role and the login form is disabled. Under the loopback default this matches the store's trust model. `metrics.sh up` already warns about non-loopback binds; the warning is extended to name Grafana and say that anyone who can reach it has admin rights.
- *Alternative: a separate `GRAFANA_BIND_ADDRESS`.* Rejected for now: one setting keeps the exposure decision in one place.

### Reset deletes volumes by name
`reset` runs `compose down`, then `docker volume rm victoriametrics-data`. `reset --grafana` also removes `grafana-data`. Both ask for confirmation, naming the volumes they will delete, unless `--yes` is given, and the flags can be combined. Removing volumes by name instead of with `--volumes` means a volume added to the project later is never deleted by accident.

### Health and status
`up` waits for both `:8428/health` and `:3000/api/health` within the existing timeout, then prints both URLs. `status` reports Grafana's health on its own line. If Grafana is down, `status` reports it and exits non-zero, after still printing the store's state.

### Version pinning
The Grafana image is pinned to an exact version, like the VictoriaMetrics image. The tag is chosen when the change is implemented.

## Risks / Trade-offs

- **[Unexported UI edits to a "Repo" dashboard are overwritten when its file changes]**, for example after `git pull` or a branch switch. → The README documents "export before you pull". `export-dashboards` is cheap to run. As a further option, the command could warn when a dashboard's database version is newer than its file; that is a nice-to-have, not part of the spec.
- **[Anonymous admin becomes reachable on the network if the bind address is changed]** → The existing warning on `up` is extended to Grafana. The default stays loopback.
- **[The `reset` behaviour change surprises someone who expects a full wipe]** → `reset` prints which volumes it deleted and which it kept. The README documents `--grafana`.
- **[Grafana's state outside "Repo" (scratch dashboards, starred Explore history, preferences) is only as durable as the volume]** → This is by design. It survives `down`, `up` and a plain `reset`, but not `reset --grafana`.
- **[Dashboard JSON schema changes when Grafana is upgraded]** → The image is pinned. An upgrade is followed by an export, so committed files move to the new schema in one reviewable diff.

## Migration Plan

Nothing to migrate: Grafana starts empty apart from what is provisioned. Existing `victoriametrics-data` is untouched. To roll back, revert the change and run `docker volume rm grafana-data` if you want the volume gone.
