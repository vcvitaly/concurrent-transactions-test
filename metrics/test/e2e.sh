#!/usr/bin/env bash
# End-to-end test: deploys the stack to a throwaway kind cluster, runs a short k6 load, and checks
# that the run's data reaches the committed Transfers dashboard, and that deploy and teardown leave
# Grafana alone. It creates its own cluster (ct-e2e, with its own kubeconfig) and its own metrics
# instance, and removes them, and the background processes it started, whether it passes or fails.
# It never reads or writes your kubeconfig, never touches another cluster, and never touches the
# default metrics instance. Takes several minutes.
#
#   metrics/test/e2e.sh
#
# Needs Docker, kind, kubectl, helm, k6, curl, jq and awk. E2E_SKELETON=1 stops right after the
# cluster is created, and E2E_INJECT_FAILURE=1 adds a check that always fails there, to see the
# cleanup.

set -euo pipefail

# Its own instance and ports, so it never collides with smoke.sh. lib.sh guards them.
export METRICS_INSTANCE="${METRICS_INSTANCE-ct-metrics-e2e}"
export METRICS_STORE_PORT="${METRICS_STORE_PORT-18438}"
export METRICS_GRAFANA_PORT="${METRICS_GRAFANA_PORT-13010}"

# shellcheck source=metrics/test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

E2E_CLUSTER="ct-e2e"
SPEEDBUMP_LOCAL_PORT=18081
TRANSFERS_PER_SENDER=20
DATA_TIMEOUT=120
export NAMESPACE="concurrent-transactions"
STORE_CONTAINER="$METRICS_INSTANCE-victoriametrics"
REMOTE_WRITE_URL="http://$STORE_CONTAINER:8428/api/v1/write"
TRANSFERS_DASHBOARD="$COMMITTED_DASHBOARDS_DIR/transfers.json"

# The user's kubeconfig, as kubectl would find it, recorded before anything changes.
USER_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
CLUSTER_CREATED=false

kubeconfig_state() {
  local file
  echo "$USER_KUBECONFIG" | tr ':' '\n' | while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ -f "$file" ]; then
      echo "$file $(shasum -a 256 <"$file" | cut -d' ' -f1)"
    else
      echo "$file absent"
    fi
  done
}

user_context() {
  KUBECONFIG="$USER_KUBECONFIG" kubectl config current-context 2>/dev/null || echo "(none)"
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$E2E_CLUSTER"
}

# Runs from the cleanup trap, before the test instance is removed.
cleanup_e2e() {
  if [ "$CLUSTER_CREATED" = true ]; then
    kind delete cluster --name "$E2E_CLUSTER" --kubeconfig "$TEST_TMP/kubeconfig" >/dev/null 2>&1 || true
    check "the test cluster is deleted" test "$(kind get clusters 2>/dev/null | grep -cx "$E2E_CLUSTER")" = 0
  fi
  expect_eq "your kubeconfig is unchanged" "$KUBECONFIG_BEFORE" "$(kubeconfig_state)"
  expect_eq "your current context is unchanged" "$CONTEXT_BEFORE" "$(user_context)"
}

# Prints the collector's remote-write counters, to see why data didn't arrive.
print_remote_write_counters() {
  echo "Collector remote-write counters:"
  kubectl get --raw "/api/v1/namespaces/$NAMESPACE/services/prometheus:9090/proxy/metrics" \
    --request-timeout=5s 2>&1 \
    | grep -E '^prometheus_remote_storage_(samples_(total|failed_total|dropped_total|pending|retried_total)|highest_timestamp_in_seconds|queue_highest_sent_timestamp_seconds)' \
    || echo "  (could not read them)"
}

# check_data <description> <command...>: like check_eventually, and prints the remote-write counters
# on a timeout.
check_data() {
  local description="$1"
  shift
  if poll "$DATA_TIMEOUT" "$@"; then
    pass "$description"
  else
    fail "$description" "command: $*" "did not succeed within ${DATA_TIMEOUT}s"
    [ ! -f "$TEST_TMP/panel-miss" ] || cat "$TEST_TMP/panel-miss"
    print_remote_write_counters
  fi
}

two_replicas_scraped() {
  [ "$(store_value 'count(up{job="concurrent-transactions"} == 1)')" = 2 ]
}

created_at() {
  local value
  value="$(store_value 'sum(transfers_total{outcome="created"})' "$1")"
  echo "${value:-0}"
}

created_increased() {
  local start end
  start="$(created_at "$RUN_START")"
  end="$(created_at "$(date +%s)")"
  awk -v s="$start" -v e="$end" -v n="$((3 * TRANSFERS_PER_SENDER))" 'BEGIN { exit !(e - s >= n) }'
}

k6_metrics_present() {
  [ -n "$(store_value 'count(k6_http_reqs_total)')" ]
}

panels_have_data() {
  local expr frames now_ms response
  now_ms="$(($(date +%s) * 1000))"
  while IFS= read -r expr; do
    [ -n "$expr" ] || continue
    response="$(grafana_ds_query "$expr" "$((RUN_START * 1000))" "$now_ms")"
    frames="$(nonempty_frames <<<"$response")"
    if [ "${frames:-0}" -eq 0 ]; then
      printf 'No data for: %s\nResponse: %s\n' "$expr" "$(head -c 1500 <<<"$response")" >"$TEST_TMP/panel-miss"
      return 1
    fi
  done <<<"$(jq -r '[.panels[]?, (.panels[]?.panels[]?)] | .[].targets[]?.expr // empty' "$TRANSFERS_DASHBOARD")"
}

all_pods_ready() {
  local app prometheus speedbump
  app="$(kubectl -n "$NAMESPACE" get deployment app-concurrent-transactions \
    -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"
  prometheus="$(kubectl -n "$NAMESPACE" get deployment prometheus \
    -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"
  speedbump="$(kubectl -n "$NAMESPACE" get pod speedbump \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  echo "app $app, prometheus $prometheus, speedbump ready $speedbump"
  [ "$app" = 2/2 ] && [ "$prometheus" = 1/1 ] && [ "$speedbump" = True ]
}

speedbump_answers() {
  curl -fsS --max-time 2 "http://localhost:$SPEEDBUMP_LOCAL_PORT/readyz"
}

# The scratch dashboard and every Repo dashboard, as the API returns them.
dashboard_snapshot() {
  local uid
  for uid in smoke-e2e-scratch $(grafana_api GET "/api/search?folderUIDs=repo&type=dash-db" | jq -r '.[].uid' | sort); do
    echo "$uid $(grafana_api GET "/api/dashboards/uid/$uid" | jq -S -c '.dashboard')"
  done
}

for tool in kind kubectl helm k6 shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: $tool is not installed." >&2
    exit 2
  fi
done
if cluster_exists; then
  echo "Refusing to start: a kind cluster named $E2E_CLUSTER already exists, and this test only uses one it creates." >&2
  exit 2
fi
KUBECONFIG_BEFORE="$(kubeconfig_state)"
CONTEXT_BEFORE="$(user_context)"

start_test_instance_setup
CLEANUP_HOOKS="cleanup_e2e"

log "deploy.sh without kind"
# A PATH with only what deploy.sh needs before it reaches a cluster, and no kind. The empty
# kubeconfig has no context, so a run stops before deploying anything.
mkdir "$TEST_TMP/bin-without-kind"
for tool in bash dirname kubectl helm docker; do
  ln -s "$(command -v "$tool")" "$TEST_TMP/bin-without-kind/$tool"
done
: >"$TEST_TMP/empty-kubeconfig"
RC=0
OUT="$(PATH="$TEST_TMP/bin-without-kind" "$REPO_ROOT/deploy.sh" --help 2>&1)" || RC=$?
expect_eq "deploy.sh --help works without kind" "0 Usage: $REPO_ROOT/deploy.sh [--teardown]" "$RC $OUT"
RC=0
OUT="$(env -u DEPLOY_KIND_CLUSTER PATH="$TEST_TMP/bin-without-kind" KUBECONFIG="$TEST_TMP/empty-kubeconfig" \
  "$REPO_ROOT/deploy.sh" 2>&1)" || RC=$?
expect_eq "without DEPLOY_KIND_CLUSTER, deploy.sh doesn't require kind (it stops at the missing context)" \
  "Error: no current kubectl context is set." "$OUT"
RC=0
OUT="$(PATH="$TEST_TMP/bin-without-kind" KUBECONFIG="$TEST_TMP/empty-kubeconfig" DEPLOY_KIND_CLUSTER="$E2E_CLUSTER" \
  "$REPO_ROOT/deploy.sh" 2>&1)" || RC=$?
expect_eq "with DEPLOY_KIND_CLUSTER, deploy.sh requires kind" "Error: kind is not installed." "$OUT"

log "Test metrics instance"
run_metrics up
expect_eq "the test store and Grafana start" 0 "$RC"
[ "$RC" -eq 0 ] || { echo "$OUT"; exit 1; }

log "Test cluster"
CLUSTER_CREATED=true
kind create cluster --name "$E2E_CLUSTER" --kubeconfig "$TEST_TMP/kubeconfig" >"$TEST_TMP/kind-create.log" 2>&1 \
  || { cat "$TEST_TMP/kind-create.log"; exit 1; }
export KUBECONFIG="$TEST_TMP/kubeconfig"
expect_eq "kubectl uses the test cluster" "kind-$E2E_CLUSTER" "$(kubectl config current-context)"

if [ "${E2E_INJECT_FAILURE:-}" = 1 ]; then
  expect_eq "this check fails on purpose" expected actual
  exit 1
fi
if [ "${E2E_SKELETON:-}" = 1 ]; then
  exit 0
fi

log "Deploy"
check "the test store joins the kind network" docker network connect kind "$STORE_CONTAINER"
case "$REMOTE_WRITE_URL" in
  *://localhost:8428* | *://127.*:8428* | *://host.docker.internal:8428* | *://\[::1\]:8428*)
    fail "the remote-write URL doesn't target host port 8428" "url: $REMOTE_WRITE_URL"
    exit 1
    ;;
  *) pass "the remote-write URL doesn't target host port 8428 ($REMOTE_WRITE_URL)" ;;
esac
echo "Deploying; the log is in $TEST_TMP/deploy.log"
RC=0
DEPLOY_KIND_CLUSTER="$E2E_CLUSTER" METRICS_REMOTE_WRITE_URL="$REMOTE_WRITE_URL" \
  "$REPO_ROOT/deploy.sh" >"$TEST_TMP/deploy.log" 2>&1 || RC=$?
expect_eq "deploy.sh exits 0" 0 "$RC"
[ "$RC" -eq 0 ] || { tail -40 "$TEST_TMP/deploy.log"; exit 1; }
check "the app, speedbump and Prometheus pods are ready" all_pods_ready

log "Load run"
kubectl -n "$NAMESPACE" port-forward pod/speedbump "$SPEEDBUMP_LOCAL_PORT:8081" >"$TEST_TMP/port-forward.log" 2>&1 &
track_pid $!
check_eventually "speedbump answers through the port-forward" 30 speedbump_answers
# run_k6 <name>: a short load through speedbump, with remote write to the test store.
run_k6() {
  RC=0
  K6_PROMETHEUS_RW_SERVER_URL="$TEST_STORE_URL/api/v1/write" \
    k6 run -o experimental-prometheus-rw --no-connection-reuse \
    -e "BASE_URL=http://localhost:$SPEEDBUMP_LOCAL_PORT" \
    -e "TRANSFERS_PER_SENDER=$TRANSFERS_PER_SENDER" \
    -e "SUMMARY_FILE=$TEST_TMP/$1-summary.json" \
    "$REPO_ROOT/k6/concurrent-transfers.js" >"$TEST_TMP/$1-k6.log" 2>&1 || RC=$?
  expect_eq "the $1 k6 run exits 0" 0 "$RC"
  [ "$RC" -eq 0 ] || tail -30 "$TEST_TMP/$1-k6.log"
  check "the $1 k6 run wrote its summary" test -s "$TEST_TMP/$1-summary.json"
}
lock_histogram_stored() {
  [ -n "$(store_value 'count(transfer_lock_query_seconds_bucket)')" ]
}
# A run this short fits in one scrape interval. The app creates its histogram series on the first
# transfer, so a single run's increase would be in the series' first sample, which rate() can't
# see. A warm-up run creates the series first, as earlier runs do in normal use.
run_k6 warm-up
check_data "the warm-up run's lock-query histogram reaches the store" lock_histogram_stored
RUN_START="$(date +%s)"
run_k6 measured

log "Run data in the store and Grafana"
check_data "count(up{job=\"concurrent-transactions\"}) is 2, from real scrapes" two_replicas_scraped
check_data "transfers_total{outcome=\"created\"} increased by $((3 * TRANSFERS_PER_SENDER)) over the measured run" created_increased
check_data "every Transfers panel query returns data for the run through Grafana" panels_have_data
check_data "k6_http_reqs_total is present" k6_metrics_present

log "Teardown leaves Grafana alone"
expect_eq "a scratch dashboard is saved" success \
  "$(save_dashboard '{"uid": "smoke-e2e-scratch", "title": "E2E scratch", "panels": []}' | jq -r '.status')"
snapshot_before="$(dashboard_snapshot)"
(
  while :; do
    if curl -fsS --max-time 2 "$TEST_GRAFANA_URL/api/health" >/dev/null 2>&1; then
      echo ok >>"$TEST_TMP/health-polls"
    else
      echo "failed at $(date +%s)" >>"$TEST_TMP/health-polls"
    fi
    sleep 1
  done
) &
poller=$!
track_pid "$poller"
RC=0
"$REPO_ROOT/deploy.sh" --teardown >"$TEST_TMP/teardown.log" 2>&1 || RC=$?
kill "$poller" 2>/dev/null || true
wait "$poller" 2>/dev/null || true
expect_eq "deploy.sh --teardown exits 0" 0 "$RC"
[ "$RC" -eq 0 ] || tail -30 "$TEST_TMP/teardown.log"
check "Grafana's health was polled during teardown" test "$(grep -c ok "$TEST_TMP/health-polls")" -gt 0
expect_eq "Grafana stayed healthy throughout" "" "$(grep -v '^ok$' "$TEST_TMP/health-polls" || true)"
expect_eq "the scratch and Repo dashboards are unchanged" "$snapshot_before" "$(dashboard_snapshot)"
