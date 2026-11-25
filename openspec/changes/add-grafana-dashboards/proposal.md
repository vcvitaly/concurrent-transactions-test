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
- Add a committed smoke test, `metrics/test/smoke.sh`, that checks the metrics stack and Grafana against a separate instance it creates and removes, seeded with synthetic data. It never touches the default instance's data, never binds beyond loopback, and needs Docker but no cluster. To support it, `metrics.sh` and the compose file read optional settings for the instance name, ports, dashboards directory and Grafana image. When they're unset, behaviour is unchanged.
- When `reset` runs outside a terminal without `--yes`, its refusal now names the volumes it would have deleted.
- Add a committed end-to-end test, `metrics/test/e2e.sh`. It creates a throwaway kind cluster, deploys the stack, runs a short k6 load, checks that the run's data reaches the committed dashboard and that deploy and teardown leave Grafana alone, then removes everything. It never uses the user's kubeconfig, existing clusters or default metrics instance, so no step in this change needs Docker Desktop's Kubernetes or manual checking.
- `deploy.sh` gains a supported, documented option to deploy to a kind cluster: when a kind cluster name is set, it loads its locally built images into that cluster. When it's unset, nothing changes.
- Document Grafana, the export workflow and the "export before pull" rule in the README.

## Capabilities

### New Capabilities
- `metrics-dashboards`: Grafana as the saved-query and dashboard layer over the long-term store. Covers how it is run and exposed, the provisioned datasource, dashboards versioned in the repo, exporting UI edits, how its data persists, and the stack's isolated smoke and end-to-end tests.

### Modified Capabilities
- `metrics-collection`: the reset requirement ("History is independent of the cluster") changes so that a reset deletes only the store's data unless other data is explicitly included, and a refusal outside a terminal names what would have been deleted. A new requirement covers deploying the stack to a kind cluster. Grafana's bind-address warning and docs are specified in `metrics-dashboards`.

## Impact

- `metrics/compose.yaml`: new `grafana` service and `grafana-data` volume.
- New `metrics/grafana/` directory with provisioning config and dashboard JSON.
- `metrics.sh`: `up`, `status` and `reset` change, there's a new `export-dashboards` command, and it reads the optional instance settings. It still needs only `docker`, `curl` and `jq`.
- New `metrics/test/lib.sh`, shared by `metrics/test/smoke.sh` and `metrics/test/e2e.sh`. Both are run by hand. The smoke test needs Docker and the same tools as `metrics.sh`, plus `awk`. The end-to-end test also needs `kind`, `kubectl`, `helm` and `k6`, and takes several minutes.
- `deploy.sh`: an optional kind cluster setting that loads its locally built images into that cluster. It requires `kind` only when that setting is used.
- `README.md`: new Grafana, smoke test and end-to-end test sections, the kind deploy option, and changes to the reset docs.
- New container image dependency: `grafana/grafana`, pinned to a specific version.
- No changes to the app or the Helm charts.
