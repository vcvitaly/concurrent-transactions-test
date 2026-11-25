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

For a "Repo" dashboard, the committed file is the durable copy and a UI edit is a working copy until it's exported. That's how Grafana 13.3 behaves, found while implementing: a UI save unlinks the dashboard from its file, the running provider leaves it alone, but on the next start the provider loads the file again and the unexported edit is gone. A changed file replaces it too. Grafana also refuses to delete a dashboard while it's still linked to its file; after a UI save unlinks it, it can be deleted. The rule for users is "export before you pull, switch branches or stop the stack".
- *Alternative: make `metrics.sh down` export automatically.* Rejected: it would write files in the repo without being asked, and `reset` and Docker restarts would still bypass it.
- *Alternative: the UI database only.* No versioning, and dashboards are lost with the volume.
- *Alternative: files only, with UI edits disabled.* This makes iterating painful. Both alternatives were rejected in favour of the hybrid.

### `metrics.sh export-dashboards`
This command uses Grafana's HTTP API (`/api/search?folderUIDs=<repo folder>` and `/api/dashboards/uid/<uid>`) through `curl` and `jq`. It writes each dashboard to `metrics/grafana/dashboards/<uid>.json`, with the volatile `id` and `version` fields removed, and keys sorted so diffs stay stable. A dashboard moved into "Repo" in the UI is exported like any other, which is how scratch work gets promoted. Files whose dashboard no longer exists in the folder are reported, not deleted, so deleting a file stays an explicit git action. The folder is looked up by a fixed folder uid set in the provider config, not by its title.

### Anonymous admin, loopback bind
Grafana is published on `${METRICS_BIND_ADDRESS:-127.0.0.1}:3000`. Anonymous auth is enabled with the `Admin` org role and the login form is disabled. Under the loopback default this matches the store's trust model. `metrics.sh up` already warns about non-loopback binds; the warning is extended to name Grafana and say that anyone who can reach it has admin rights.
- *Alternative: a separate `GRAFANA_BIND_ADDRESS`.* Rejected for now: one setting keeps the exposure decision in one place.

### Reset deletes volumes by name
`reset` runs `compose down`, then `docker volume rm victoriametrics-data`. `reset --grafana` also removes `grafana-data`. Both ask for confirmation, naming the volumes they will delete, unless `--yes` is given, and the flags can be combined. Removing volumes by name instead of with `--volumes` means a volume added to the project later is never deleted by accident. One function builds the list of volumes to delete, and both the prompt and the non-interactive refusal print that list ("would delete victoriametrics-data, grafana-data; run it in a terminal, or pass --yes"). That lets the smoke test check what reset would delete, without a terminal and without deleting anything.

### Health and status
`up` waits for both `:8428/health` and `:3000/api/health` within the existing timeout, then prints both URLs. `status` reports Grafana's health on its own line. If Grafana is down, `status` reports it and exits non-zero, after still printing the store's state.

### Isolated test instance for a committed smoke test
`metrics/test/smoke.sh` checks the whole stack against a separate instance that it creates and deletes. It drives the real `metrics.sh` (`up`, `status`, `reset`, `reset --grafana`, `export-dashboards`) and checks results through the store's and Grafana's HTTP APIs, so no step is manual. To make this possible, `compose.yaml` and `metrics.sh` read a few environment variables. When they are unset, every name, port and path is exactly what it is today. In particular, the existing `victoriametrics-data` volume keeps its name.
- `METRICS_INSTANCE`: when set, used as the compose project name and as a prefix for container and volume names.
- `METRICS_STORE_PORT` (default 8428) and `METRICS_GRAFANA_PORT` (default 3000): the host ports, also used by `metrics.sh` for its health and API URLs.
- `METRICS_DASHBOARDS_DIR` (default `metrics/grafana/dashboards`): what Grafana mounts and what `export-dashboards` writes to.
- `METRICS_GRAFANA_IMAGE` (default the pinned image): lets the test start with a nonexistent tag to check how `up` reports an unhealthy Grafana.

The test uses its own instance name, the ports 18428 and 13000, and a temporary copy of the committed dashboards. A `trap` stops the test instance and removes only its volumes, even when an assertion fails. A guard refuses to start unless the instance name, both ports and the dashboards directory all differ from the defaults. That guard is what stops a test `reset` from reaching real data.

Synthetic data comes from an `awk` generator. It writes about an hour of Prometheus text-format samples, with millisecond timestamps ending at "now", and posts them to the test store's `/api/v1/import/prometheus`. The samples are:
- `up` for two replicas
- `transfers_total` counters for each outcome, increasing steadily
- cumulative `transfer_lock_query_seconds_bucket` histograms

Steps that are UI actions in normal use run through Grafana's API in the test: saving (`POST /api/dashboards/db`), moving a dashboard to another folder (`folderUid`) and deleting one.

The script is run by hand. There is no CI, and it needs Docker. Setting up the test instance, the guards, the cleanup, the generator and the assertion helpers live in `metrics/test/lib.sh`, which `e2e.sh` (below) shares. Two rules are absolute for both scripts: they never bind anything beyond loopback, and they never need a pseudo-terminal. So the smoke test doesn't cover:
- what needs a cluster: a real k6 run, and `deploy.sh` leaving the stack alone. `e2e.sh` covers both;
- the non-loopback exposure warning (checking it would mean binding to all interfaces);
- answering the interactive reset prompt (checking it would need a pseudo-terminal). This is existing code that the change doesn't touch. The refusal checked through the non-interactive path covers what matters.
- *Alternative: a compose override file.* Rejected: Compose adds override ports to the list instead of replacing them, and `metrics.sh` would still target the default ports and volumes.
- *Alternative: a throwaway script.* Rejected: the hooks would be left with nothing using them, and later changes, such as a Grafana upgrade, would go back to manual checks against real data.

### End-to-end test on a throwaway kind cluster
`metrics/test/e2e.sh` checks what the smoke test can't: data from a real deploy and k6 run reaching the dashboard, and `deploy.sh` leaving the metrics stack alone. It doesn't depend on Docker Desktop's Kubernetes or on the user's kubeconfig:
1. Start a test metrics instance, as the smoke test does, with its own instance name and ports.
2. `kind create cluster --name ct-e2e --kubeconfig <tmp>/kubeconfig`. Every later `kubectl`, `helm` and `deploy.sh` call runs with `KUBECONFIG` set to that file.
3. Run `./deploy.sh` with `DEPLOY_KIND_CLUSTER=ct-e2e` and `METRICS_REMOTE_WRITE_URL` pointing at the test store (see the remote-write decision below).
4. Start `kubectl port-forward pod/speedbump` on a test port (18081) in the background, then run a short k6 load: `TRANSFERS_PER_SENDER` set small, a summary file in the temporary directory, and remote write to the test store.
5. Assert that each "Transfers" panel query returns data inside the run's time window, coming from real scrapes (two `instance` values on `up`, and `transfers_total{outcome="created"}` increased).
6. Save a scratch dashboard, run `./deploy.sh --teardown`, and assert that Grafana stayed healthy throughout (polled in the background) and that both the scratch and "Repo" dashboards are unchanged.

A `trap` stops the port-forward, runs `kind delete cluster --name ct-e2e`, and cleans up the test instance. Guards: refuse to start if a kind cluster named `ct-e2e` already exists (never delete one the script didn't create), and the same metrics-instance guard as the smoke test. The script never reads or writes the user's kubeconfig; it checks the file's checksum before and after, and confirms the user's current context is unchanged. It takes several minutes, so it's a separate, opt-in script, and `smoke.sh` stays fast.
- *Alternative: Testcontainers with k3s.* Rejected: it would need a JVM test, run through Gradle, to drive bash scripts, and loading images into k3s means piping `docker save` into `ctr` by hand. kind is shell-native and already installed.
- *Alternative: Docker Desktop's Kubernetes.* Rejected: it's tied to one machine's setup, and it shares the user's real cluster and kubeconfig.
- *Alternative: folding it into `smoke.sh`.* Rejected: it would make every smoke run take minutes.

### `deploy.sh` loads local images into a kind cluster on request
`deploy.sh` builds `concurrent-transactions-test:build-<hash>` and `speedbump:v1.1.0` locally and deploys them with `IfNotPresent`. That works on Docker Desktop's Kubernetes only because it shares Docker's image store. When `DEPLOY_KIND_CLUSTER=<name>` is set, `deploy.sh` runs `kind load docker-image --name <name>` for both images after building them, and requires `kind` only in that case. When it's unset, nothing changes. This is documented as a supported way to deploy to kind, not only a test hook.
- *Alternative: detecting kind from a `kind-` context name.* Rejected: it's a guess, and the variable is explicit.
- *Alternative: a local registry.* Rejected: it's more moving parts for the same result.

### Remote write from kind pods to the test store
The chart's default `host.docker.internal:8428` is the *real* store's port, so `e2e.sh` always overrides it. The preferred route is to attach the test store's container to kind's `kind` Docker network and use `http://<test-store-container>:8428/api/v1/write`. That works on any Docker engine if pods can resolve container names through CoreDNS and the node's Docker DNS. The fallback is `http://host.docker.internal:<test store port>/api/v1/write`, which works on Docker Desktop. The first e2e task is a spike that proves one of these; the design records the outcome. Either way, the URL never points at port 8428 on the host, and `e2e.sh` asserts that.

**Spike outcome (2026-11-25): the preferred route works, and `e2e.sh` uses it.** Setup: Docker Desktop 29.9.3 (linux/arm64), kind v0.33.0 with node `v1.37.0`, a throwaway cluster `ct-spike` with its own kubeconfig, and a spike store `ct-spike-victoriametrics` on host port 28428, attached with `docker network connect kind ct-spike-victoriametrics`. Evidence:
- From a one-off `curlimages/curl` pod (cluster DNS `10.96.0.10`), `curl http://ct-spike-victoriametrics:8428/health` returned `OK`. The fallback, `http://host.docker.internal:28428/health`, also returned `OK`.
- A one-off `prom/prometheus:v3.16.0` pod scraping itself (`job="spike"`) with `remote_write` to `http://ct-spike-victoriametrics:8428/api/v1/write` delivered its samples: the spike store returned `up{job="spike", instance="localhost:9090"} 1` 36s after the pod was created (including its startup).
- The spike cluster, store, volumes and kubeconfig were deleted afterwards; the user's kubeconfig checksum was unchanged.

So `e2e.sh` attaches the test store's container to the `kind` network and sets `METRICS_REMOTE_WRITE_URL=http://<test store container>:8428/api/v1/write`. Port 8428 there is the container port on the `kind` network, not a host port, so the real store on the host is never targeted.

### Version pinning
The Grafana image is pinned to an exact version, like the VictoriaMetrics image. The tag is chosen when the change is implemented.

## Risks / Trade-offs

- **[Unexported UI edits to a "Repo" dashboard are lost when its file changes or Grafana restarts]**, for example after `git pull`, a branch switch or `./metrics.sh down` and `up`. → The README documents "export before you pull, switch branches or stop the stack". `export-dashboards` is cheap to run. As a further option, the command could warn when a dashboard's database version is newer than its file; that is a nice-to-have, not part of the spec.
- **[Anonymous admin becomes reachable on the network if the bind address is changed]** → The existing warning on `up` is extended to Grafana. The default stays loopback.
- **[The `reset` behaviour change surprises someone who expects a full wipe]** → `reset` prints which volumes it deleted and which it kept. The README documents `--grafana`.
- **[Grafana's state outside "Repo" (scratch dashboards, starred Explore history, preferences) is only as durable as the volume]** → This is by design. It survives `down`, `up` and a plain `reset`, but not `reset --grafana`.
- **[Dashboard JSON schema changes when Grafana is upgraded]** → The image is pinned. An upgrade is followed by a smoke test run and an export, so committed files move to the new schema in one reviewable diff.
- **[The smoke test destroys real data if it targets the default instance]**, because it runs `reset --grafana --yes`. → The guard refuses to run unless every instance setting differs from the default. Cleanup removes volumes by their test names only, never with `down --volumes` against a project name it didn't create. The test also checks that the default `victoriametrics-data` volume still exists, with the same creation time as before the run.
- **[The exposure warning's Grafana wording isn't checked automatically]** → Accepted, so the test never binds beyond loopback. It's a one-line message next to the existing store warning, and the change is reviewed in the diff.
- **[The smoke test breaks when Grafana's API responses change]** → It's expected and caught at upgrade time, which is when it's useful. Assertions check only the fields they need.
- **[The e2e test sends data to, or tears down, something real]** → It never reads or writes the user's kubeconfig (checksum checked before and after). It uses only a cluster it created, and refuses to start if `ct-e2e` already exists. The remote-write URL is asserted not to target host port 8428. The metrics-instance guard is shared with the smoke test.
- **[Pods can't reach the test store]** → A spike settles this before anything else is built, with a documented fallback. A stuck run fails on a timeout with the collector's remote-write counters printed, instead of hanging.
- **[The e2e test is slow and needs Docker resources]** (several minutes; a kind node plus the metrics stack) → It's opt-in and separate from `smoke.sh`, uses a short k6 load, and the README states the expected run time.
- **[Port-forward or k6 processes outlive a failed run]** → The `trap` kills the background PIDs it started before deleting the cluster.

## Migration Plan

Nothing to migrate: Grafana starts empty apart from what is provisioned. Existing `victoriametrics-data` is untouched. To roll back, revert the change and run `docker volume rm grafana-data` if you want the volume gone.
