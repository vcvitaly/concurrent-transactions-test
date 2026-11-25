# Proposal

## Why

The long-term store keeps load-test history across cluster teardowns, but its only UI is vmui. vmui can't save queries or dashboards, so every analysis starts from scratch. A Grafana instance next to the store would let queries and dashboards be saved, reused across runs and kept in version control.

## What Changes

- Add Grafana as a second service in the metrics stack (`metrics/compose.yaml`), managed only by `metrics.sh`. Like the store, it lives outside the cluster and `deploy.sh` never touches it.
- Provision a VictoriaMetrics datasource with a fixed uid, so committed dashboards keep resolving it.
- Load dashboards from JSON files in the repo into a dedicated "Repo" folder, while still allowing them to be edited and saved in the UI. Dashboards in other folders are scratch work and live only in Grafana's volume.
- Add `./metrics.sh export-dashboards`, which writes every dashboard in the "Repo" folder back to its JSON file.
- Bind Grafana to loopback by default with anonymous access, following the same bind-address rule and warning as the store.
- Make `./metrics.sh up` and `status` cover Grafana's health and print its URL.
- **BREAKING**: `./metrics.sh reset` no longer deletes every volume in the metrics stack. It deletes only the metrics data. The new `./metrics.sh reset --grafana` also deletes Grafana's data.
- Ship a first committed dashboard built from the README's example queries.
- Document Grafana, the export workflow and the "export before pull" rule in the README.

## Capabilities

### New Capabilities
- `metrics-dashboards`: Grafana as the saved-query and dashboard layer over the long-term store. Covers how it is run and exposed, the provisioned datasource, dashboards versioned in the repo, exporting UI edits, and how its data persists.

### Modified Capabilities
- `metrics-collection`: the reset requirement ("History is independent of the cluster") changes so that a reset deletes only the store's data unless other data is explicitly included. Grafana's bind-address warning and docs are specified in `metrics-dashboards`.

## Impact

- `metrics/compose.yaml`: new `grafana` service and `grafana-data` volume.
- New `metrics/grafana/` directory with provisioning config and dashboard JSON.
- `metrics.sh`: `up`, `status` and `reset` change, and a new `export-dashboards` command. It still needs only `docker`, `curl` and `jq`.
- `README.md`: new Grafana section, and changes to the reset docs.
- New container image dependency: `grafana/grafana`, pinned to a specific version.
- No changes to the app, the Helm charts or `deploy.sh`.
