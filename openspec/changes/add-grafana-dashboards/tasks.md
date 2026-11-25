# Tasks

Every check below is an assertion: groups 1–7 in `metrics/test/smoke.sh`, group 8 in `metrics/test/e2e.sh`. "Verify" means that script passes with the assertion added. No step is manual. Never run `reset` against the default instance, and never point `deploy.sh` at your own cluster, while implementing this change.

## 1. Isolated test instance and smoke test harness

- [x] 1.1 Make `metrics/compose.yaml` and `metrics.sh` read `METRICS_INSTANCE` (compose project name and the prefix for container and volume names), `METRICS_STORE_PORT` (default 8428) and `METRICS_GRAFANA_PORT` (default 3000). When they are unset, names, ports and URLs stay exactly as they are now. Verify that `docker compose -f metrics/compose.yaml config` with no variables set still shows container `concurrent-transactions-victoriametrics`, volume `victoriametrics-data` and port `127.0.0.1:8428`, and that with `METRICS_INSTANCE=ct-metrics-test` and port 18428 every name and port differs
- [x] 1.2 Create `metrics/test/lib.sh` (shared with `e2e.sh`) and `metrics/test/smoke.sh`. Put in the library a guard that refuses to start, changing nothing, if the instance name or either port equals its default. Add a `trap` that runs `compose down` for the test project and removes only the test-named volumes, `check`/`expect_eq` helpers that print expected and actual values on failure, polling helpers with timeouts (no fixed sleeps), a pass/fail summary and a non-zero exit on any failure. Record whether the default `victoriametrics-data` volume exists and its creation time, and assert both are unchanged at the end. Verify that a run with only `./metrics.sh up` and `status` against the test instance passes and leaves no test containers or volumes, that a deliberately failing check exits non-zero and still cleans up, and that setting the instance or a port to a default makes it refuse to run
- [x] 1.3 Add an `awk` generator for about an hour of samples ending at "now" (millisecond timestamps, 5s steps): `up{job="concurrent-transactions"}` for two instances, increasing `transfers_total` counters for each outcome, and cumulative `transfer_lock_query_seconds_bucket`, `_sum` and `_count`. The smoke test posts them to the test store's `/api/v1/import/prometheus`. Verify with assertions on the test store's `/api/v1/query` that `count(up{job="concurrent-transactions"})` is 2, `sum(increase(transfers_total[30m])) > 0`, and that `histogram_quantile(0.95, sum by (le) (rate(transfer_lock_query_seconds_bucket[5m])))` returns a number
- [x] 1.4 Document the smoke test in the README: what it checks, that it needs Docker but no cluster, that it never touches the default instance, and the command to run it. Verify that the documented command runs and passes as written

## 2. Grafana service and datasource

- [x] 2.1 Pick a current stable `grafana/grafana` tag and pin it. Add a `grafana` service to `metrics/compose.yaml`, published on `${METRICS_BIND_ADDRESS:-127.0.0.1}:${METRICS_GRAFANA_PORT:-3000}:3000`, with the instance-prefixed volume (`grafana-data` by default) and `restart: unless-stopped`. Verify with a `compose config` assertion that the default volume name is `grafana-data` and the default bind is `127.0.0.1:3000`, and that the test instance's Grafana answers `/api/health`
- [x] 2.2 Configure anonymous auth through environment variables: anonymous enabled with org role `Admin`, login form disabled, and no sign-up. Verify with assertions that `/api/dashboards/home` returns 200 with no credentials, and that `GET /` isn't redirected to `/login`
- [x] 2.3 Add `metrics/grafana/provisioning/datasources/victoriametrics.yaml`, mounted read-only: type `prometheus`, uid `victoriametrics`, URL `http://victoriametrics:8428`, default, not editable. Verify with assertions that `/api/datasources/uid/victoriametrics` returns it as the default, and that `up{job="concurrent-transactions"}` and `max(tlast_over_time(up{job="concurrent-transactions"}[10y]))` through `/api/ds/query` match the test store's `/api/v1/query` results on the seeded data

## 3. `metrics.sh up` and `status`

- [x] 3.1 Make `up` wait for both the store's `/health` and Grafana's `/api/health` within the existing timeout, fail with an error that names whichever service is unhealthy (with its last log lines), and print both URLs. Verify with assertions on `up`'s output for a healthy start. For the failure path, start with a nonexistent Grafana image tag (overridable for the test only) and assert that `up` exits non-zero and names Grafana
- [x] 3.2 Extend the non-loopback warning in `up` to say that Grafana is reachable from the network with admin rights and no login. Verify with an assertion that a default start of the test instance doesn't print any warning. Check the new wording only in the diff: the smoke test never binds beyond loopback
- [x] 3.3 Make `status` report Grafana's health on its own line, still print the store's state, and exit non-zero if either is unhealthy. Verify with assertions with both running, with only the test Grafana container stopped, and with both stopped
- [x] 3.4 Update the README's Metrics section: the architecture diagram and bullets include Grafana, the commands table describes `up`, `down` and `status` covering both services, and the Grafana URL and no-login default are documented next to vmui. Verify that the documented URLs match the default ports in `compose config`

## 4. Reset by volume name

- [x] 4.1 Change `reset` to run `compose down`, then remove only the store's volume by name (ignoring a missing volume), and print which volumes it deleted and which it kept. Verify with assertions that after a scratch dashboard is saved through the API, `reset --yes` followed by `up` leaves the test store empty and the scratch dashboard still present
- [x] 4.2 Add `--grafana`, which also removes Grafana's volume. Accept `--grafana` and `--yes` in any order and reject anything else with the usage message. One function builds the list of volumes to delete, and both the confirmation prompt and the refusal printed outside a terminal show it. Verify with assertions, without a terminal or pseudo-terminal, that `reset` and `reset --grafana` without `--yes` exit non-zero, name exactly the store's volume, or both volumes, and leave both volumes in place. Also verify that `reset --grafana --yes` followed by `up` leaves only provisioned dashboards, and that `reset --bogus` exits 2
- [x] 4.3 Update the script header comment, `usage`, and the README commands table for `reset` and `reset --grafana`, stating that a plain reset keeps Grafana. Verify with an assertion that `./metrics.sh --help` lists `reset [--grafana] [--yes]`

## 5. Dashboards loaded from the repo

- [x] 5.1 Make Grafana mount `${METRICS_DASHBOARDS_DIR:-metrics/grafana/dashboards}` read-only. Add `metrics/grafana/provisioning/dashboards/repo.yaml`: a file provider for folder "Repo" with a fixed folder uid, `allowUiUpdates: true` and `updateIntervalSeconds` of 30 or less. Add a placeholder dashboard JSON with a fixed uid. The smoke test points `METRICS_DASHBOARDS_DIR` at a temporary copy. Verify with an assertion that, on a fresh test instance, the placeholder is in the "Repo" folder
- [x] 5.2 Verify how loading and API saves interact, with assertions: saving a "Repo" dashboard through `POST /api/dashboards/db` with a changed title succeeds and is served while Grafana runs; after `./metrics.sh down` and `up`, without an export, it is served from its file again; and changing its file in the temporary copy shows up through the API within 60s, without a restart

## 6. `metrics.sh export-dashboards`

- [x] 6.1 Add an `export-dashboards` command that writes to `METRICS_DASHBOARDS_DIR`, and fails with an error, writing nothing, when Grafana isn't reachable. It looks up the "Repo" folder by its uid, fetches each dashboard there through `/api/dashboards/uid/<uid>`, removes `id` and `version`, and writes `<uid>.json` with sorted keys and a trailing newline. Verify with an assertion that, with the test Grafana stopped, it exits non-zero and the temporary copy is unchanged
- [x] 6.2 Verify with assertions that the output is stable and that edits are exported: two exports with no edits leave the temporary copy byte-identical, and after an API save only that dashboard's file changes and contains the edit. Then `reset --grafana --yes` followed by `up` serves the edited version
- [x] 6.3 Report, without deleting, every file whose uid has no dashboard in "Repo". Verify with assertions that a scratch dashboard moved into "Repo" (`folderUid`) gets a new file, one left outside gets none, and one deleted through the API is reported while its file stays
- [x] 6.4 Document in the README the "Repo" folder versus scratch folders, saving a query as a panel, the export command, and the rule that unexported UI edits to a "Repo" dashboard are lost when its file changes or Grafana restarts, so you export before pulling, switching branches or stopping the stack. Add `export-dashboards` to `usage` and the commands table. Verify with an assertion that `./metrics.sh --help` lists `export-dashboards`

## 7. Starter dashboard

- [x] 7.1 Build a "Transfers" dashboard in "Repo" with panels for transfer outcomes, lock-wait percentiles and per-replica `up`, using the README's Queries section and the `victoriametrics` datasource. Commit it and remove the placeholder. Verify with assertions that the committed JSON refers to the datasource only by uid `victoriametrics`, and that every panel's query, run through `/api/ds/query` on the seeded test instance, returns non-empty frames
- [x] 7.2 Point the README's Queries section to the dashboard. Verify with an assertion that the README links to the committed dashboard's uid

## 8. kind deploy and end-to-end test

- [x] 8.1 Spike: with a throwaway kind cluster and a test store, find out which remote-write route works from a pod. The preferred route attaches the test store container to the `kind` Docker network and uses its container name. The fallback is `host.docker.internal:<test store port>`. Verify by `curl`ing the store's `/health` from a one-off pod and remote-writing one sample that the test store returns. Record the chosen route and the evidence in `design.md`, and delete the spike cluster
- [x] 8.2 Add `DEPLOY_KIND_CLUSTER` to `deploy.sh`: when it's set, require `kind` and run `kind load docker-image --name <cluster>` for the app image and the speedbump image after they're built and before the Helm installs that use them. When it's unset, nothing changes. Update the script header and the README's How to run section. Verify with an assertion in `e2e.sh` that the deploy into the test cluster finishes with the app, speedbump and Prometheus pods ready. Also check with a `PATH` that has no `kind` that `deploy.sh --help` and a run without the variable don't require kind
- [x] 8.3 Create `metrics/test/e2e.sh` on top of `lib.sh`. It refuses to start if a kind cluster named `ct-e2e` exists, records the checksum of the user's kubeconfig and their current context, starts a test metrics instance and Grafana, and runs `kind create cluster --name ct-e2e --kubeconfig <tmp>/kubeconfig`, exporting `KUBECONFIG` to that file. A `trap` kills the background processes the script started, deletes `ct-e2e` and cleans up the test instance. Verify that a skeleton run (create cluster, then exit) passes and leaves no cluster, containers, volumes or processes; that an injected failure exits non-zero and cleans up the same way; that a pre-existing `ct-e2e` makes it refuse to run; and that the kubeconfig checksum and current context are unchanged afterwards
- [x] 8.4 Deploy with `DEPLOY_KIND_CLUSTER=ct-e2e` and `METRICS_REMOTE_WRITE_URL` set to the route from 8.1, asserting the URL doesn't target host port 8428. Start `kubectl port-forward pod/speedbump 18081:8081` in the background, wait until it answers, then run k6 with `BASE_URL=http://localhost:18081`, a small `TRANSFERS_PER_SENDER`, a summary file in the temporary directory, and remote write to the test store. Verify with assertions that, within a timeout:
  - `count(up{job="concurrent-transactions"})` in the test store is 2, from real scrapes;
  - `transfers_total{outcome="created"}` increased over the run window;
  - every "Transfers" panel query returns non-empty frames through Grafana's `/api/ds/query` for the run window;
  - `k6_http_reqs_total` is present.

  On a timeout, print the collector's remote-write counters
- [x] 8.5 Save a scratch dashboard through the API, poll Grafana's `/api/health` in the background, and run `./deploy.sh --teardown`. Verify with assertions that the poll never failed, and that the scratch dashboard and every "Repo" dashboard are byte-identical, through the API, before and after
- [x] 8.6 Document `e2e.sh` in the README: what it checks, the tools it needs (Docker, `kind`, `kubectl`, `helm`, `k6`), the expected run time, and that it never touches your kubeconfig, clusters or default metrics instance. Verify that the documented command runs and passes as written

## 9. Integration checks

- [x] 9.1 From a fresh clone, run `smoke.sh` and `e2e.sh` and check that both pass with nothing left behind. Run `./metrics.sh up` on the default instance and check that the datasource and the "Transfers" dashboard are present with no clicks. Check that `openspec validate add-grafana-dashboards --strict` passes

## Workflow follow-up

- Sync the `metrics-dashboards` and `metrics-collection` specs and archive the change once it has been implemented and reviewed.
