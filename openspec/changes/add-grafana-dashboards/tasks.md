# Tasks

## 1. Grafana service and datasource

- [ ] 1.1 Pick a current stable `grafana/grafana` tag and pin it. Add a `grafana` service to `metrics/compose.yaml`, published on `${METRICS_BIND_ADDRESS:-127.0.0.1}:3000:3000`, with a named volume `grafana-data` (`name: grafana-data`) and `restart: unless-stopped`. Verify that `docker compose -f metrics/compose.yaml config` succeeds and shows the port bound to `127.0.0.1` when the variable is unset
- [ ] 1.2 Configure anonymous auth through environment variables: anonymous enabled with org role `Admin`, login form disabled, and no sign-up. Verify that after `docker compose -f metrics/compose.yaml up -d`, `curl -fsS localhost:3000/api/dashboards/home` succeeds with no credentials, and that the UI opens with no login prompt
- [ ] 1.3 Add `metrics/grafana/provisioning/datasources/victoriametrics.yaml`, mounted read-only: type `prometheus`, uid `victoriametrics`, URL `http://victoriametrics:8428`, default, not editable. Verify with an empty `grafana-data` volume that `curl localhost:3000/api/datasources/uid/victoriametrics` returns it, and that querying `up{job="concurrent-transactions"}` and `max(tlast_over_time(up{job="concurrent-transactions"}[10y]))` through `/api/ds/query` matches the store's own `/api/v1/query` result

## 2. `metrics.sh up` and `status`

- [ ] 2.1 Make `up` wait for both `:8428/health` and `:3000/api/health` within the existing timeout, fail with an error that names whichever service is unhealthy (with its last log lines), and print both URLs. Verify with `./metrics.sh up` on a clean start, and with Grafana made unhealthy (for example a bad image tag passed by an override), checking that the error names Grafana
- [ ] 2.2 Extend the non-loopback warning in `up` to say that Grafana is reachable from the network with admin rights and no login. Verify that `env METRICS_BIND_ADDRESS=0.0.0.0 ./metrics.sh up` prints it, and that a default start doesn't
- [ ] 2.3 Make `status` report Grafana's health on its own line, still print the store's state, and exit non-zero if either is unhealthy. Verify with both running, with only Grafana stopped (`docker stop concurrent-transactions-grafana`), and with both stopped
- [ ] 2.4 Update the README's Metrics section: the architecture diagram and bullets include Grafana, the commands table describes `up`, `down` and `status` covering both services, and the Grafana URL and no-login default are documented next to vmui. Verify that the documented commands and URLs work as written

## 3. Reset by volume name

- [ ] 3.1 Change `reset` to run `compose down`, then `docker volume rm victoriametrics-data` (ignoring a missing volume), and print which volumes it deleted and which it kept. Verify that after saving a scratch dashboard in the UI, `./metrics.sh reset --yes` followed by `./metrics.sh up` leaves the store empty (`./metrics.sh status` reports no samples) and the scratch dashboard still present
- [ ] 3.2 Add `--grafana`, which also removes `grafana-data`. Accept `--grafana` and `--yes` in any order and reject anything else with the usage message. The confirmation prompt names every volume that will be deleted. Verify the prompt text, that answering "no" deletes nothing, that `reset --grafana --yes` followed by `up` leaves only provisioned content, and that `reset --bogus` exits 2
- [ ] 3.3 Update the script header comment, `usage`, and the README commands table for `reset` and `reset --grafana`, stating that a plain reset keeps Grafana. Verify that `./metrics.sh --help` and the README match the behaviour

## 4. Dashboards loaded from the repo

- [ ] 4.1 Add `metrics/grafana/provisioning/dashboards/repo.yaml`: a file provider for folder "Repo" with a fixed folder uid, `allowUiUpdates: true`, `updateIntervalSeconds` of 30 or less, reading `metrics/grafana/dashboards/` mounted read-only. Add a placeholder dashboard JSON with a fixed uid. Verify with an empty `grafana-data` volume that it appears in the "Repo" folder
- [ ] 4.2 Verify how loading and UI edits interact: editing and saving the placeholder in the UI succeeds and survives `./metrics.sh down && ./metrics.sh up`, and changing its file while Grafana runs shows the change within a minute, without a restart

## 5. `metrics.sh export-dashboards`

- [ ] 5.1 Add an `export-dashboards` command that fails with an error and writes nothing when Grafana isn't reachable. It looks up the "Repo" folder by its uid, fetches each dashboard there through `/api/dashboards/uid/<uid>`, removes `id` and `version`, and writes `metrics/grafana/dashboards/<uid>.json` with sorted keys and a trailing newline. Verify that running it with Grafana stopped exits non-zero with `git status` clean
- [ ] 5.2 Verify that the output is stable and that edits are exported: running `export-dashboards` twice with no edits leaves `git diff` empty, and after a UI edit it shows exactly that edit. Then `./metrics.sh reset --grafana --yes && ./metrics.sh up` shows the edited dashboard
- [ ] 5.3 Report, without deleting, every committed file whose uid has no dashboard in "Repo". Verify that a scratch dashboard moved into "Repo" gets a new file, a scratch dashboard left outside gets none, and a dashboard deleted from "Repo" in the UI is reported while its file stays
- [ ] 5.4 Document in the README the "Repo" folder versus scratch folders, saving a query as a panel, the export command, and the rule that unexported UI edits to a "Repo" dashboard are overwritten when its file changes, so you export before pulling or switching branches. Add `export-dashboards` to `usage` and the commands table. Verify by following the README to save a query as a panel in "Repo", export it, and find the panel in the committed file

## 6. Starter dashboard

- [ ] 6.1 Build a "Transfers" dashboard in the "Repo" folder with panels for transfer outcomes, lock-wait percentiles and per-replica `up`, using the same queries as the README's Queries section and the `victoriametrics` datasource. Export it and remove the placeholder from task 4.1. Verify that the committed JSON refers to the datasource only by uid `victoriametrics`
- [ ] 6.2 Point the README's Queries section to the dashboard. Verify that after a deploy and a k6 run with the stack up, each panel shows data for the run when the dashboard's time range covers it

## 7. Integration checks

- [ ] 7.1 Verify that the cluster doesn't touch Grafana: with the stack running and a UI-only dashboard saved, run `./deploy.sh` and `./deploy.sh --teardown`, and check that Grafana kept running throughout and both the scratch and "Repo" dashboards are unchanged
- [ ] 7.2 From a fresh clone with no `grafana-data` volume, run `./metrics.sh up` and check that the datasource and the "Transfers" dashboard are present with no clicks, and that `openspec validate add-grafana-dashboards --strict` passes

## Workflow follow-up

- Sync the `metrics-dashboards` and `metrics-collection` specs and archive the change once it has been implemented and reviewed.
