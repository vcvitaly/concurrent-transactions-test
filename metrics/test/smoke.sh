#!/usr/bin/env bash
# Smoke test for the metrics stack (store and Grafana) and metrics.sh, against a separate instance
# that it creates, seeds with synthetic data, and removes, whether it passes or fails. It never
# touches the default instance and never binds beyond loopback. Needs Docker, but no cluster.
#
#   metrics/test/smoke.sh
#
# See lib.sh for the test instance's settings. SMOKE_INJECT_FAILURE=1 adds a check that always
# fails, to see the failure path and its cleanup.

set -euo pipefail

# shellcheck source=metrics/test/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GRAFANA_CONTAINER="$METRICS_INSTANCE-grafana"
TRANSFERS_UID="transfers"
REPO_FOLDER_UID="repo"
PROVISION_TIMEOUT=60

# Prints "<file> <sha>" for every file in a directory, so two listings compare byte for byte.
dir_digest() {
  (cd "$1" && for file in *; do [ -e "$file" ] && echo "$file $(shasum -a 256 <"$file" | cut -d' ' -f1)"; done)
}

dashboard() {
  grafana_api GET "/api/dashboards/uid/$1"
}

dashboard_title() {
  dashboard "$1" | jq -r '.dashboard.title // empty'
}

dashboard_exists() {
  [ "$(grafana_api GET "/api/dashboards/uid/$1" -o /dev/null -w '%{http_code}')" = 200 ]
}

dashboard_has_title() {
  [ "$(dashboard_title "$1")" = "$2" ]
}

# True once the file provider has linked the dashboard to its file.
dashboard_provisioned_from() {
  [ "$(dashboard "$1" | jq -r '.meta.provisionedExternalId // empty')" = "$2" ]
}

repo_uids() {
  grafana_api GET "/api/search?folderUIDs=$REPO_FOLDER_UID&type=dash-db&limit=5000" | jq -r '.[].uid' | sort
}

all_dashboard_uids() {
  grafana_api GET "/api/search?type=dash-db&limit=5000" | jq -r '.[].uid' | sort
}

file_uids() {
  jq -r '.uid' "$METRICS_DASHBOARDS_DIR"/*.json | sort
}

committed_uids() {
  jq -r '.uid' "$COMMITTED_DASHBOARDS_DIR"/*.json | sort
}

# Every target expression in a dashboard file, one per line, including panels nested in rows.
panel_exprs() {
  jq -r '[.panels[]?, (.panels[]?.panels[]?)] | .[].targets[]?.expr // empty' "$1"
}

volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

store_has_seeded_data() {
  [ "$(store_value 'count(up{job="concurrent-transactions"})')" = 2 ]
}

start_test_instance_setup shasum

log "Static checks"
"$REPO_ROOT/metrics.sh" --help >"$TEST_TMP/help" 2>&1 || true
expect_contains "--help lists reset [--grafana] [--yes]" "reset [--grafana] [--yes]" "$(cat "$TEST_TMP/help")"
expect_contains "--help lists export-dashboards" "export-dashboards" "$(cat "$TEST_TMP/help")"
run_metrics reset --bogus
expect_eq "reset --bogus exits 2" 2 "$RC"

default_config="$(cd "$REPO_ROOT" && env -u METRICS_INSTANCE -u METRICS_STORE_PORT -u METRICS_GRAFANA_PORT \
  -u METRICS_DASHBOARDS_DIR -u METRICS_BIND_ADDRESS -u METRICS_GRAFANA_IMAGE \
  docker compose -f metrics/compose.yaml config --format json)"
test_config="$(cd "$REPO_ROOT" && docker compose -f metrics/compose.yaml config --format json)"
config_summary() {
  jq -r '"project \(.name)",
    (.services | to_entries[] | .key as $service
      | "\($service) container \(.value.container_name)",
        (.value.ports[] | "\($service) port \(.host_ip):\(.published)")),
    (.volumes | to_entries[] | "volume \(.key) \(.value.name)")' | sort
}
expect_eq "the default compose config keeps today's names and ports" \
  "$(printf '%s\n' \
    "grafana container concurrent-transactions-grafana" \
    "grafana port 127.0.0.1:3000" \
    "project concurrent-transactions-metrics" \
    "victoriametrics container concurrent-transactions-victoriametrics" \
    "victoriametrics port 127.0.0.1:8428" \
    "volume grafana-data grafana-data" \
    "volume victoriametrics-data victoriametrics-data" | sort)" \
  "$(config_summary <<<"$default_config")"
expect_eq "the default compose config mounts the committed dashboards" \
  "$COMMITTED_DASHBOARDS_DIR" \
  "$(jq -r '.services.grafana.volumes[] | select(.target == "/etc/grafana/repo-dashboards") | .source' <<<"$default_config")"
expect_eq "the default restart policy is unless-stopped for both services" "unless-stopped unless-stopped" \
  "$(jq -r '[.services[].restart] | join(" ")' <<<"$default_config")"
shared_names="$(comm -12 <(config_summary <<<"$default_config") <(config_summary <<<"$test_config"))"
expect_eq "the test instance shares no name or port with the default" "" "$shared_names"
readme="$(cat "$REPO_ROOT/README.md")"
expect_contains "the README's vmui URL matches the default store port" \
  "http://localhost:$(jq -r '.services.victoriametrics.ports[0].published' <<<"$default_config")/vmui" "$readme"
expect_contains "the README's Grafana URL matches the default Grafana port" \
  "http://localhost:$(jq -r '.services.grafana.ports[0].published' <<<"$default_config")" "$readme"
expect_contains "the README links to the committed Transfers dashboard" "/d/$TRANSFERS_UID" "$readme"

for file in "$COMMITTED_DASHBOARDS_DIR"/*.json; do
  expect_eq "$(basename "$file") refers to datasources only by uid victoriametrics" "victoriametrics" \
    "$(jq -r '[.. | objects | select(has("datasource")) | .datasource
               | if type == "object" then (.uid // "missing uid") else "name: \(.)" end]
              | unique | join(",")' "$file")"
  expect_eq "$(basename "$file") is named after its uid" "$(basename "$file" .json)" "$(jq -r '.uid' "$file")"
done

log "Before start"
run_metrics status
expect_ne "status exits non-zero with both services stopped" 0 "$RC"
expect_contains "status reports the store down" "Store: not reachable" "$OUT"
expect_contains "status reports Grafana down" "Grafana: not reachable" "$OUT"
before="$(dir_digest "$METRICS_DASHBOARDS_DIR")"
run_metrics export-dashboards
expect_ne "export-dashboards fails when Grafana isn't running" 0 "$RC"
expect_eq "a failed export changes no files" "$before" "$(dir_digest "$METRICS_DASHBOARDS_DIR")"

log "Start"
run_metrics up
expect_eq "up exits 0" 0 "$RC"
expect_contains "up prints the vmui URL" "$TEST_STORE_URL/vmui" "$OUT"
expect_contains "up prints the Grafana URL" "Grafana is up: $TEST_GRAFANA_URL" "$OUT"
expect_not_contains "a loopback start prints no warning" "Warning" "$OUT"
run_metrics status
expect_eq "status exits 0 with both services healthy" 0 "$RC"
expect_contains "status reports the store healthy" "Store: healthy at $TEST_STORE_URL" "$OUT"
expect_contains "status reports Grafana healthy on its own line" "Grafana: healthy at $TEST_GRAFANA_URL" "$OUT"

log "Synthetic data"
check "the samples are imported" seed_store
check_eventually "count(up{job=\"concurrent-transactions\"}) is 2" 30 store_has_seeded_data
increase="$(store_value 'sum(increase(transfers_total[30m]))')"
check "sum(increase(transfers_total[30m])) > 0 (got '$increase')" awk -v v="$increase" 'BEGIN { exit !(v + 0 > 0) }'
p95="$(store_value 'histogram_quantile(0.95, sum by (le) (rate(transfer_lock_query_seconds_bucket[5m])))')"
check "the lock-query p95 is a number (got '$p95')" awk -v v="$p95" 'BEGIN { exit !(v ~ /^[0-9.eE+-]+$/) }'

log "Grafana access and datasource"
check "Grafana answers /api/health" curl -fsS --max-time 5 "$TEST_GRAFANA_URL/api/health"
expect_eq "anonymous requests get the org Admin role (/api/org/users)" 200 \
  "$(curl -s -o /dev/null -w '%{http_code}' "$TEST_GRAFANA_URL/api/org/users")"
expect_eq "GET / is not redirected to /login" "200 " \
  "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$TEST_GRAFANA_URL/")"
expect_eq "the provisioned datasource is the default, read-only, and points at the store" \
  "prometheus true true http://victoriametrics:8428" \
  "$(grafana_api GET /api/datasources/uid/victoriametrics | jq -r '"\(.type) \(.isDefault) \(.readOnly) \(.url)"')"

query='up{job="concurrent-transactions"}'
expect_eq "$query through Grafana matches the store" \
  "$(store_query "$query" | jq -c '[.[] | {instance: .metric.instance, value: (.value[1] | tonumber)}] | sort')" \
  "$(grafana_ds_instant "$query" | jq -c '[.results.A.frames[]
      | {instance: .schema.fields[1].labels.instance, value: .data.values[1][0]}] | sort')"
query='max(tlast_over_time(up{job="concurrent-transactions"}[10y]))'
expect_eq "$query through Grafana matches the store" \
  "$(store_value "$query" | jq -c 'tonumber')" \
  "$(grafana_ds_instant "$query" | jq -c '.results.A.frames[0].data.values[1][0]')"

log "Provisioned dashboards"
expect_eq "every committed dashboard is in the Repo folder" "$(committed_uids)" "$(repo_uids)"
now_ms="$(($(date +%s) * 1000))"
for file in "$COMMITTED_DASHBOARDS_DIR"/*.json; do
  exprs="$(panel_exprs "$file")"
  expect_ne "$(basename "$file") has panel queries" "" "$exprs"
  while IFS= read -r expr; do
    [ -n "$expr" ] || continue
    frames="$(grafana_ds_query "$expr" $((now_ms - 3600000)) "$now_ms" | nonempty_frames)"
    check "$(basename "$file"): '$expr' returns data (frames: $frames)" test "${frames:-0}" -gt 0
  done <<<"$exprs"
done

log "Export is stable"
run_metrics export-dashboards
expect_eq "the first export exits 0" 0 "$RC"
expect_eq "exporting unedited dashboards reproduces the committed files" \
  "$(dir_digest "$COMMITTED_DASHBOARDS_DIR")" "$(dir_digest "$METRICS_DASHBOARDS_DIR")"
before="$(dir_digest "$METRICS_DASHBOARDS_DIR")"
run_metrics export-dashboards
expect_eq "a second export with no edits changes no files" "$before" "$(dir_digest "$METRICS_DASHBOARDS_DIR")"

log "UI saves and file changes"
original="$(dashboard "$TRANSFERS_UID" | jq '.dashboard')"
result="$(save_dashboard "$(jq '.title = "Saved through the API"' <<<"$original")" "$REPO_FOLDER_UID")"
expect_eq "saving a Repo dashboard with a changed title succeeds" success "$(jq -r '.status' <<<"$result")"
expect_eq "the saved title is served" "Saved through the API" "$(dashboard_title "$TRANSFERS_UID")"
check_eventually "the scratch dashboard for the restart check is saved" 10 \
  save_dashboard '{"uid": "smoke-restart-scratch", "title": "Smoke restart scratch", "panels": []}'
run_metrics down
expect_eq "down exits 0" 0 "$RC"
run_metrics up
expect_eq "up exits 0 again" 0 "$RC"
file_title="$(jq -r '.title' "$METRICS_DASHBOARDS_DIR/$TRANSFERS_UID.json")"
check_eventually "after a restart without an export, the Repo dashboard is served from its file" \
  "$PROVISION_TIMEOUT" dashboard_has_title "$TRANSFERS_UID" "$file_title"
check "a scratch dashboard outside Repo survives the restart" dashboard_exists smoke-restart-scratch
file="$METRICS_DASHBOARDS_DIR/$TRANSFERS_UID.json"
jq -S '.title = "Changed in the file"' "$file" >"$TEST_TMP/changed.json"
mv "$TEST_TMP/changed.json" "$file"
check_eventually "a changed file is served within 60s, without a restart" 60 \
  dashboard_has_title "$TRANSFERS_UID" "Changed in the file"

log "Exporting edits"
before_other="$(dir_digest "$METRICS_DASHBOARDS_DIR" | grep -v "^$TRANSFERS_UID.json " || true)"
edited="$(dashboard "$TRANSFERS_UID" | jq '.dashboard | .description = "Edited by the smoke test"')"
expect_eq "an edit to a Repo dashboard is saved" success \
  "$(save_dashboard "$edited" "$REPO_FOLDER_UID" | jq -r '.status')"
run_metrics export-dashboards
expect_eq "export exits 0" 0 "$RC"
expect_eq "the edited dashboard's file contains the edit" "Edited by the smoke test" \
  "$(jq -r '.description' "$file")"
expect_eq "no other file changed" "$before_other" \
  "$(dir_digest "$METRICS_DASHBOARDS_DIR" | grep -v "^$TRANSFERS_UID.json " || true)"
expect_eq "the exported file has no id or version" "false false" "$(jq -r '"\(has("id")) \(has("version"))"' "$file")"
expect_eq "the exported file has sorted keys and a trailing newline" "$(jq -S . "$file")" "$(cat "$file")"
check "the exported file ends with a newline" test "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" = '\n'

log "Promoting and removing dashboards"
scratch='{"uid": "smoke-scratch", "title": "Smoke scratch", "panels": []}'
promoted='{"uid": "smoke-promoted", "title": "Smoke promoted", "panels": []}'
expect_eq "a scratch dashboard is saved outside Repo" success "$(save_dashboard "$scratch" | jq -r '.status')"
expect_eq "a second scratch dashboard is saved outside Repo" success "$(save_dashboard "$promoted" | jq -r '.status')"
expect_eq "the second one is moved into Repo" success \
  "$(save_dashboard "$(dashboard smoke-promoted | jq '.dashboard')" "$REPO_FOLDER_UID" | jq -r '.status')"
run_metrics export-dashboards
check "a dashboard moved into Repo gets a file" test -f "$METRICS_DASHBOARDS_DIR/smoke-promoted.json"
check "a dashboard outside Repo gets no file" test ! -e "$METRICS_DASHBOARDS_DIR/smoke-scratch.json"
# Grafana refuses to delete a dashboard while it's linked to its file, and a UI save unlinks it, so
# the dashboard is edited first, as in the UI. Deleted before the file provider links it, it would
# be loaded again from the new file.
check_eventually "the promoted dashboard is linked to its new file" "$PROVISION_TIMEOUT" \
  dashboard_provisioned_from smoke-promoted smoke-promoted.json
expect_eq "the promoted dashboard is edited" success \
  "$(save_dashboard "$(dashboard smoke-promoted | jq '.dashboard | .title = "Smoke promoted, edited"')" \
    "$REPO_FOLDER_UID" | jq -r '.status')"
expect_eq "the promoted dashboard is deleted through the API" 200 \
  "$(grafana_api DELETE /api/dashboards/uid/smoke-promoted -o /dev/null -w '%{http_code}')"
check "the deleted dashboard is gone" test "$(repo_uids | grep -cx smoke-promoted)" = 0
run_metrics export-dashboards
expect_contains "export reports a file with no dashboard in Repo" \
  "Not in the Repo folder: $METRICS_DASHBOARDS_DIR/smoke-promoted.json" "$OUT"
check "the reported file is left in place" test -f "$METRICS_DASHBOARDS_DIR/smoke-promoted.json"

log "Grafana stopped"
check "the test Grafana container stops" docker stop "$GRAFANA_CONTAINER"
run_metrics status
expect_ne "status exits non-zero with Grafana stopped" 0 "$RC"
expect_contains "status still reports the store healthy" "Store: healthy at $TEST_STORE_URL" "$OUT"
expect_contains "status reports Grafana down" "Grafana: not reachable at $TEST_GRAFANA_URL" "$OUT"
before="$(dir_digest "$METRICS_DASHBOARDS_DIR")"
run_metrics export-dashboards
expect_ne "export-dashboards exits non-zero with Grafana stopped" 0 "$RC"
expect_eq "the dashboards directory is unchanged" "$before" "$(dir_digest "$METRICS_DASHBOARDS_DIR")"
run_metrics up
expect_eq "up starts Grafana again" 0 "$RC"

log "Reset without confirmation"
run_metrics reset
expect_ne "reset without --yes outside a terminal exits non-zero" 0 "$RC"
expect_contains "it names the store's volume" "would delete $TEST_STORE_VOLUME;" "$OUT"
run_metrics reset --grafana
expect_ne "reset --grafana without --yes outside a terminal exits non-zero" 0 "$RC"
expect_contains "it names both volumes" "would delete $TEST_STORE_VOLUME, $TEST_GRAFANA_VOLUME;" "$OUT"
check "the store's volume is still there" volume_exists "$TEST_STORE_VOLUME"
check "Grafana's volume is still there" volume_exists "$TEST_GRAFANA_VOLUME"
check "the store still has its data" store_has_seeded_data

log "Reset keeps Grafana"
run_metrics reset --yes
expect_eq "reset --yes exits 0" 0 "$RC"
expect_contains "it says which volume it deleted" "Deleted volumes: $TEST_STORE_VOLUME." "$OUT"
expect_contains "it says which volume it kept" "Kept volumes: $TEST_GRAFANA_VOLUME." "$OUT"
run_metrics up
expect_eq "up after reset exits 0" 0 "$RC"
expect_eq "the store is empty" "[]" "$(store_query 'up{job="concurrent-transactions"}[10y]')"
check "the scratch dashboard is still there" dashboard_exists smoke-scratch

log "Reset including Grafana"
run_metrics reset --yes --grafana
expect_eq "reset --yes --grafana (flags in any order) exits 0" 0 "$RC"
expect_contains "it says it deleted both volumes" "Deleted volumes: $TEST_STORE_VOLUME, $TEST_GRAFANA_VOLUME." "$OUT"
run_metrics up
expect_eq "up after a full reset exits 0" 0 "$RC"
check_eventually "only provisioned dashboards are present" "$PROVISION_TIMEOUT" \
  test "$(all_dashboard_uids)" = "$(file_uids)"
expect_eq "the exported edit is served" "Edited by the smoke test" \
  "$(dashboard "$TRANSFERS_UID" | jq -r '.dashboard.description')"

log "Grafana not healthy"
run_metrics down
expect_eq "down exits 0" 0 "$RC"
RC=0
OUT="$(METRICS_GRAFANA_IMAGE=grafana/grafana:0.0.0-does-not-exist "$REPO_ROOT/metrics.sh" up </dev/null 2>&1)" || RC=$?
expect_ne "up with a broken Grafana image exits non-zero" 0 "$RC"
expect_contains "up names Grafana as unhealthy" "Error: Grafana is not healthy" "$OUT"

if [ "${SMOKE_INJECT_FAILURE:-}" = 1 ]; then
  log "Injected failure"
  expect_eq "this check fails on purpose" expected actual
fi
