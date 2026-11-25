# Shared by smoke.sh and e2e.sh: a separate metrics instance, guards that keep the default instance
# out of reach, cleanup, assertion helpers and the synthetic data generator. Source it; don't run it.
#
# The test instance defaults to METRICS_INSTANCE=ct-metrics-test, METRICS_STORE_PORT=18428,
# METRICS_GRAFANA_PORT=13000 and a temporary copy of the committed dashboards. Setting any of them
# to the default instance's value makes the tests refuse to start.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMITTED_DASHBOARDS_DIR="$REPO_ROOT/metrics/grafana/dashboards"
DEFAULT_PROJECT="concurrent-transactions-metrics"
DEFAULT_VOLUMES="victoriametrics-data grafana-data"

# Set to empty, these select the default instance, which the guard refuses.
export METRICS_INSTANCE="${METRICS_INSTANCE-ct-metrics-test}"
export METRICS_STORE_PORT="${METRICS_STORE_PORT-18428}"
export METRICS_GRAFANA_PORT="${METRICS_GRAFANA_PORT-13000}"
# The tests never bind beyond loopback.
export METRICS_BIND_ADDRESS=127.0.0.1

TEST_STORE_URL="http://localhost:$METRICS_STORE_PORT"
TEST_GRAFANA_URL="http://localhost:$METRICS_GRAFANA_PORT"
TEST_STORE_VOLUME="$METRICS_INSTANCE-victoriametrics-data"
TEST_GRAFANA_VOLUME="$METRICS_INSTANCE-grafana-data"

PASSED=0
FAILED=0
FAILURES=""
BACKGROUND_PIDS=""
# Functions run first by the cleanup trap, for example to delete a test cluster.
CLEANUP_HOOKS=""
TEST_TMP=""
DEFAULT_VOLUMES_BEFORE=""

log() {
  printf '\n== %s\n' "$*"
}

pass() {
  PASSED=$((PASSED + 1))
  printf '  PASS  %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  FAILURES="$FAILURES
  - $1"
  printf '  FAIL  %s\n' "$1"
  shift
  local line
  for line in "$@"; do
    printf '          %s\n' "$line"
  done
}

# check <description> <command...>: passes when the command succeeds.
check() {
  local description="$1"
  shift
  local output status=0
  output="$("$@" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    pass "$description"
  else
    fail "$description" "command: $*" "exit status: $status" "output: $(printf '%s' "$output" | tail -5)"
  fi
}

# expect_eq <description> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected: $2" "actual:   $3"
  fi
}

# expect_ne <description> <unexpected> <actual>
expect_ne() {
  if [ "$2" != "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected anything but: $2" "actual: $3"
  fi
}

# expect_contains <description> <needle> <haystack>
expect_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "expected to contain: $2" "actual: $3" ;;
  esac
}

# expect_not_contains <description> <needle> <haystack>
expect_not_contains() {
  case "$3" in
    *"$2"*) fail "$1" "expected not to contain: $2" "actual: $3" ;;
    *) pass "$1" ;;
  esac
}

# poll <timeout seconds> <command...>: retries every second until the command succeeds.
poll() {
  local timeout="$1" start=$SECONDS
  shift
  until "$@" >/dev/null 2>&1; do
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      return 1
    fi
    sleep 1
  done
}

# check_eventually <description> <timeout seconds> <command...>
check_eventually() {
  local description="$1" timeout="$2"
  shift 2
  if poll "$timeout" "$@"; then
    pass "$description"
  else
    fail "$description" "command: $*" "did not succeed within ${timeout}s"
  fi
}

# Runs ./metrics.sh against the test instance, with no terminal on stdin. Sets OUT (stdout and
# stderr) and RC.
run_metrics() {
  RC=0
  OUT="$("$REPO_ROOT/metrics.sh" "$@" </dev/null 2>&1)" || RC=$?
}

# Prints "exists <creation time>" or "absent" for each default volume.
default_volume_state() {
  local volume created
  for volume in $DEFAULT_VOLUMES; do
    if created="$(docker volume inspect --format '{{.CreatedAt}}' "$volume" 2>/dev/null)"; then
      echo "$volume exists $created"
    else
      echo "$volume absent"
    fi
  done
}

resolve_dir() {
  (cd "$1" 2>/dev/null && pwd -P) || echo "$1"
}

# Refuses to start, changing nothing, unless every instance setting differs from the default.
guard_test_instance() {
  local reason=""
  case "$METRICS_INSTANCE" in
    "") reason="METRICS_INSTANCE is empty, which selects the default instance" ;;
    "$DEFAULT_PROJECT" | concurrent-transactions)
      reason="METRICS_INSTANCE=$METRICS_INSTANCE is the default instance's name"
      ;;
  esac
  if [ "$METRICS_STORE_PORT" = 8428 ] || [ -z "$METRICS_STORE_PORT" ]; then
    reason="${reason:+$reason; }METRICS_STORE_PORT=$METRICS_STORE_PORT is the default store port"
  fi
  if [ "$METRICS_GRAFANA_PORT" = 3000 ] || [ -z "$METRICS_GRAFANA_PORT" ]; then
    reason="${reason:+$reason; }METRICS_GRAFANA_PORT=$METRICS_GRAFANA_PORT is the default Grafana port"
  fi
  if [ -n "${METRICS_DASHBOARDS_DIR:-}" ] \
    && [ "$(resolve_dir "$METRICS_DASHBOARDS_DIR")" = "$(resolve_dir "$COMMITTED_DASHBOARDS_DIR")" ]; then
    reason="${reason:+$reason; }METRICS_DASHBOARDS_DIR is the committed dashboards directory"
  fi
  if [ -n "$reason" ]; then
    echo "Refusing to run against the default metrics instance: $reason." >&2
    exit 2
  fi

  local leftovers
  leftovers="$(docker ps -aq --filter "label=com.docker.compose.project=$METRICS_INSTANCE")
$(docker volume ls -q --filter "name=^$METRICS_INSTANCE-")"
  if [ -n "$(echo "$leftovers" | tr -d '[:space:]')" ]; then
    echo "Refusing to start: containers or volumes of the test instance '$METRICS_INSTANCE' already exist." >&2
    echo "Remove them with: METRICS_INSTANCE=$METRICS_INSTANCE docker compose -f metrics/compose.yaml down" \
      "&& docker volume rm $TEST_STORE_VOLUME $TEST_GRAFANA_VOLUME" >&2
    exit 2
  fi
}

# Registers a background process for the cleanup trap to kill.
track_pid() {
  BACKGROUND_PIDS="$BACKGROUND_PIDS $1"
}

cleanup_test_instance() {
  docker compose -f "$REPO_ROOT/metrics/compose.yaml" down --timeout 5 >/dev/null 2>&1 || true
  local volume
  for volume in "$TEST_STORE_VOLUME" "$TEST_GRAFANA_VOLUME"; do
    docker volume rm "$volume" >/dev/null 2>&1 || true
  done
}

finish() {
  local status=$?
  set +e
  trap - EXIT INT TERM
  log "Cleanup"
  local hook pid
  for pid in $BACKGROUND_PIDS; do
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
  for hook in $CLEANUP_HOOKS; do
    "$hook"
  done
  cleanup_test_instance
  [ -z "$TEST_TMP" ] || rm -rf "$TEST_TMP"

  expect_eq "no test containers are left" "" \
    "$(docker ps -aq --filter "label=com.docker.compose.project=$METRICS_INSTANCE")"
  expect_eq "no test volumes are left" "" "$(docker volume ls -q --filter "name=^$METRICS_INSTANCE-")"
  local leftover_pids=""
  for pid in $BACKGROUND_PIDS; do
    if kill -0 "$pid" 2>/dev/null; then
      leftover_pids="$leftover_pids $pid"
    fi
  done
  expect_eq "no background processes are left" "" "$leftover_pids"
  expect_eq "the default instance's volumes are unchanged" "$DEFAULT_VOLUMES_BEFORE" "$(default_volume_state)"

  printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
  if [ "$status" -ne 0 ]; then
    echo "The script stopped early with exit status $status."
  fi
  if [ "$FAILED" -ne 0 ]; then
    printf 'Failed checks:%s\n' "$FAILURES"
  fi
  if [ "$status" -ne 0 ] || [ "$FAILED" -ne 0 ]; then
    exit 1
  fi
  exit 0
}

# Guards, records the default instance's state, copies the committed dashboards to a temporary
# directory, and installs the cleanup trap. Call before changing anything.
start_test_instance_setup() {
  local tool
  for tool in docker curl jq awk "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Error: $tool is not installed." >&2
      exit 2
    fi
  done
  guard_test_instance
  DEFAULT_VOLUMES_BEFORE="$(default_volume_state)"
  TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/$METRICS_INSTANCE.XXXXXX")"
  TEST_TMP="$(cd "$TEST_TMP" && pwd -P)"
  trap finish EXIT
  trap 'exit 130' INT TERM
  export METRICS_DASHBOARDS_DIR="${METRICS_DASHBOARDS_DIR:-$TEST_TMP/dashboards}"
  mkdir -p "$METRICS_DASHBOARDS_DIR"
  cp "$COMMITTED_DASHBOARDS_DIR"/*.json "$METRICS_DASHBOARDS_DIR"/
  echo "Test instance: $METRICS_INSTANCE (store $TEST_STORE_URL, Grafana $TEST_GRAFANA_URL)"
  echo "Dashboards: $METRICS_DASHBOARDS_DIR"
}

# store_query <query> [time]: prints the store's /api/v1/query result array.
store_query() {
  curl -fsS --max-time 10 "$TEST_STORE_URL/api/v1/query" --data-urlencode "query=$1" \
    ${2:+-d "time=$2"} | jq -c '.data.result'
}

# store_value <query> [time]: prints the first result's value, or nothing.
store_value() {
  store_query "$@" | jq -r '.[0].value[1] // empty'
}

grafana_api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --max-time 10 -X "$method" -H 'Content-Type: application/json' "$TEST_GRAFANA_URL$path" "$@"
}

# grafana_ds_query <expr> <from ms> <to ms>: runs a range query through Grafana's datasource and
# prints the response.
grafana_ds_query() {
  jq -n --arg expr "$1" --arg from "$2" --arg to "$3" '{
    from: $from, to: $to,
    queries: [{refId: "A", datasource: {type: "prometheus", uid: "victoriametrics"},
               expr: $expr, range: true, instant: false, intervalMs: 15000, maxDataPoints: 500}]
  }' | grafana_api POST /api/ds/query -d @-
}

# grafana_ds_instant <expr>: runs an instant query through Grafana and prints the response.
grafana_ds_instant() {
  local now
  now="$(($(date +%s) * 1000))"
  jq -n --arg expr "$1" --arg now "$now" '{
    from: $now, to: $now,
    queries: [{refId: "A", datasource: {type: "prometheus", uid: "victoriametrics"},
               expr: $expr, range: false, instant: true}]
  }' | grafana_api POST /api/ds/query -d @-
}

# Number of frames with at least one value in a /api/ds/query response.
nonempty_frames() {
  jq '[.results[]?.frames[]? | select((.data.values // []) | length > 1 and (.[1] | length) > 0)] | length'
}

# save_dashboard <dashboard json> [folder uid]: saves through the API, as the UI does.
save_dashboard() {
  jq -n --argjson dashboard "$1" --arg folder "${2:-}" \
    '{dashboard: $dashboard, overwrite: true} + (if $folder == "" then {} else {folderUid: $folder} end)' \
    | grafana_api POST /api/dashboards/db -d @-
}

# Writes about an hour of synthetic samples ending now, in Prometheus text format with millisecond
# timestamps, one sample every 5s, for two replicas.
generate_samples() {
  awk -v now="$(date +%s)" '
    BEGIN {
      steps = 720
      split("created replayed insufficient_funds not_found invalid error", outcomes, " ")
      rates["created"] = 20; rates["replayed"] = 2; rates["insufficient_funds"] = 1
      rates["not_found"] = 1; rates["invalid"] = 1; rates["error"] = 1
      nb = split("0.001 0.005 0.01 0.05 0.1 0.5 1 +Inf", les, " ")
      # Of the 20 observations per step, how many land in each bucket (non-cumulative).
      split("6 5 4 2 2 1 0 0", per_step, " ")
      for (i = 1; i <= 2; i++) {
        instance = "10.0.0." i ":8090"
        for (s = 0; s < steps; s++) {
          ts = (now - (steps - 1 - s) * 5) * 1000
          labels = "job=\"concurrent-transactions\",instance=\"" instance "\""
          printf "up{%s} 1 %d\n", labels, ts
          for (o = 1; o <= 6; o++) {
            name = outcomes[o]
            total[i, name] += rates[name]
            printf "transfers_total{%s,outcome=\"%s\"} %d %d\n", labels, name, total[i, name], ts
          }
          for (b = 1; b <= nb; b++) {
            bucket[i, b] += per_step[b]
          }
          running = 0
          for (b = 1; b <= nb; b++) {
            running += bucket[i, b]
            printf "transfer_lock_query_seconds_bucket{%s,le=\"%s\"} %d %d\n", labels, les[b], running, ts
          }
          count[i] += 20
          sum[i] += 20 * 0.012
          printf "transfer_lock_query_seconds_count{%s} %d %d\n", labels, count[i], ts
          printf "transfer_lock_query_seconds_sum{%s} %.4f %d\n", labels, sum[i], ts
        }
      }
    }'
}

seed_store() {
  generate_samples | curl -fsS --max-time 30 --data-binary @- "$TEST_STORE_URL/api/v1/import/prometheus"
}
