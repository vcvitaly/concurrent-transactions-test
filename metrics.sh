#!/usr/bin/env bash
# Manages the metrics stack outside the cluster: the long-term store (VictoriaMetrics) and Grafana,
# both in Docker. deploy.sh never starts, stops or deletes them, so history and dashboards survive
# cluster teardowns.
#
#   ./metrics.sh up                          start the store and Grafana, and wait until both are
#                                            healthy
#   ./metrics.sh down                        stop both, keeping their data
#   ./metrics.sh status                      show both services' health and the newest scraped sample
#   ./metrics.sh reset [--grafana] [--yes]   stop both and permanently delete the store's data.
#                                            Grafana's data is kept unless --grafana is given
#   ./metrics.sh export-dashboards           write every dashboard in Grafana's "Repo" folder to
#                                            metrics/grafana/dashboards/<uid>.json
#
# Both listen on 127.0.0.1 by default (the store on 8428, Grafana on 3000). Set METRICS_BIND_ADDRESS
# to listen on another address. Neither has authentication: anything that can reach the store can
# read and write it, and anyone who can reach Grafana is an admin.
# Set METRICS_RETENTION to change the retention period (months, or a value with an h/d/w/y suffix).
#
# For the tests in metrics/test only: METRICS_INSTANCE runs a separate instance (compose project
# name, and prefix for container and volume names), METRICS_STORE_PORT and METRICS_GRAFANA_PORT
# change the host ports, METRICS_DASHBOARDS_DIR changes the dashboards directory, and
# METRICS_GRAFANA_IMAGE changes the Grafana image.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

COMPOSE_FILE="metrics/compose.yaml"
INSTANCE="${METRICS_INSTANCE:-}"
VOLUME_PREFIX="${INSTANCE:+$INSTANCE-}"
STORE_VOLUME="${VOLUME_PREFIX}victoriametrics-data"
GRAFANA_VOLUME="${VOLUME_PREFIX}grafana-data"
BIND_ADDRESS="${METRICS_BIND_ADDRESS:-127.0.0.1}"
STORE_PORT="${METRICS_STORE_PORT:-8428}"
GRAFANA_PORT="${METRICS_GRAFANA_PORT:-3000}"
STORE_URL="http://localhost:$STORE_PORT"
GRAFANA_URL="http://localhost:$GRAFANA_PORT"
DASHBOARDS_DIR="${METRICS_DASHBOARDS_DIR:-metrics/grafana/dashboards}"
REPO_FOLDER_UID="repo"
HEALTH_TIMEOUT_SECONDS=60
APP_JOB="concurrent-transactions"

usage() {
  echo "Usage: $0 up | down | status | reset [--grafana] [--yes] | export-dashboards"
}

require_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Error: $tool is not installed." >&2
      exit 1
    fi
  done
}

compose() {
  # Compose resolves relative paths against metrics/, this script against the repo root.
  METRICS_DASHBOARDS_DIR="$(cd "$DASHBOARDS_DIR" && pwd)" docker compose -f "$COMPOSE_FILE" "$@"
}

is_loopback() {
  case "$1" in
    127.* | localhost | ::1 | "[::1]") return 0 ;;
    *) return 1 ;;
  esac
}

store_healthy() {
  curl -fsS --max-time 2 "$STORE_URL/health" >/dev/null 2>&1
}

grafana_healthy() {
  curl -fsS --max-time 2 "$GRAFANA_URL/api/health" >/dev/null 2>&1
}

# Prints the names of the services that aren't healthy, one per line.
unhealthy_services() {
  store_healthy || echo store
  grafana_healthy || echo Grafana
}

up() {
  if ! is_loopback "$BIND_ADDRESS"; then
    echo "Warning: METRICS_BIND_ADDRESS=$BIND_ADDRESS exposes the store and Grafana beyond loopback." >&2
    echo "Warning: the store's write and query API has no authentication and is reachable from the network." >&2
    echo "Warning: Grafana is reachable from the network with admin rights and no login." >&2
  fi
  mkdir -p "$DASHBOARDS_DIR"

  local started=true
  compose up -d || started=false

  local waited=0 unhealthy
  while unhealthy="$(unhealthy_services)" && [ -n "$unhealthy" ]; do
    if [ "$started" != true ] || [ "$waited" -ge "$HEALTH_TIMEOUT_SECONDS" ]; then
      local service
      for service in $unhealthy; do
        if [ "$started" != true ]; then
          echo "Error: $service is not healthy: docker compose could not start the stack." >&2
        else
          echo "Error: $service did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s." >&2
        fi
        case "$service" in
          store) compose logs --tail 20 victoriametrics >&2 || true ;;
          Grafana) compose logs --tail 20 grafana >&2 || true ;;
        esac
      done
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "Store is up: $STORE_URL/vmui (listening on $BIND_ADDRESS:$STORE_PORT)"
  echo "Grafana is up: $GRAFANA_URL (listening on $BIND_ADDRESS:$GRAFANA_PORT, no login)"
}

down() {
  compose down
  echo "Store and Grafana stopped. Their data is kept in the Docker volumes $STORE_VOLUME and $GRAFANA_VOLUME."
}

# Prints the volumes a reset deletes, one per line. $1 is "true" when Grafana's data is included.
reset_volumes() {
  echo "$STORE_VOLUME"
  if [ "$1" = true ]; then
    echo "$GRAFANA_VOLUME"
  fi
}

join() {
  local IFS=","
  echo "$*" | sed 's/,/, /g'
}

reset() {
  local include_grafana=false confirmed=false arg
  for arg in "$@"; do
    case "$arg" in
      --grafana) include_grafana=true ;;
      --yes) confirmed=true ;;
    esac
  done

  local volumes
  # shellcheck disable=SC2046 # Volume names have no spaces.
  volumes="$(join $(reset_volumes "$include_grafana"))"
  if [ "$confirmed" != true ]; then
    if [ ! -t 0 ]; then
      echo "Error: reset would delete $volumes; run it in a terminal, or pass --yes." >&2
      exit 1
    fi
    local answer
    read -r -p "Permanently delete the Docker volumes $volumes? [y/N] " answer || answer=""
    case "$answer" in
      y | Y | yes | YES) ;;
      *)
        echo "Reset cancelled."
        exit 1
        ;;
    esac
  fi

  compose down
  local volume deleted="" missing="" kept=""
  for volume in $(reset_volumes "$include_grafana"); do
    if docker volume inspect "$volume" >/dev/null 2>&1; then
      docker volume rm "$volume" >/dev/null
      deleted="$deleted $volume"
    else
      missing="$missing $volume"
    fi
  done
  for volume in "$STORE_VOLUME" "$GRAFANA_VOLUME"; do
    if ! reset_volumes "$include_grafana" | grep -qx "$volume"; then
      kept="$kept $volume"
    fi
  done
  # shellcheck disable=SC2086 # Word splitting of the lists is intended.
  {
    echo "Stack stopped."
    [ -z "$deleted" ] || echo "Deleted volumes: $(join $deleted)."
    [ -z "$missing" ] || echo "Already absent: $(join $missing)."
    [ -z "$kept" ] || echo "Kept volumes: $(join $kept)."
  }
}

status() {
  local healthy=true
  if store_healthy; then
    echo "Store: healthy at $STORE_URL"
    print_newest_sample
  else
    echo "Store: not reachable at $STORE_URL"
    healthy=false
  fi
  if grafana_healthy; then
    echo "Grafana: healthy at $GRAFANA_URL"
  else
    echo "Grafana: not reachable at $GRAFANA_URL"
    healthy=false
  fi
  [ "$healthy" = true ]
}

print_newest_sample() {
  require_tools jq
  # tlast_over_time is MetricsQL: the timestamp of the newest sample in the window.
  local query="max(tlast_over_time(up{job=\"$APP_JOB\"}[10y]))"
  local newest
  newest="$(curl -fsS --max-time 10 "$STORE_URL/api/v1/query" --data-urlencode "query=$query" \
    | jq -r '.data.result[0].value[1] // empty')"
  if [ -z "$newest" ]; then
    echo "Newest up{job=\"$APP_JOB\"} sample: none"
    return
  fi
  local seconds="${newest%.*}"
  local formatted
  formatted="$(date -u -r "$seconds" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$seconds" '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Newest up{job=\"$APP_JOB\"} sample: $formatted ($(($(date +%s) - seconds))s ago)"
}

grafana_get() {
  curl -fsS --max-time 10 "$GRAFANA_URL$1"
}

# Fetches every dashboard first and writes only if all of them were read, so a failure changes no
# files. Files are rewritten only when their content changed.
export_dashboards() {
  require_tools jq
  if ! grafana_healthy; then
    echo "Error: Grafana is not reachable at $GRAFANA_URL. Start it with ./metrics.sh up." >&2
    exit 1
  fi
  if ! grafana_get "/api/folders/$REPO_FOLDER_UID" >/dev/null; then
    echo "Error: Grafana has no folder with uid '$REPO_FOLDER_UID'." >&2
    exit 1
  fi

  local staging
  staging="$(mktemp -d)"
  # shellcheck disable=SC2064 # Expand now: staging is local.
  trap "rm -rf '$staging'" EXIT

  local uids uid
  uids="$(grafana_get "/api/search?folderUIDs=$REPO_FOLDER_UID&type=dash-db&limit=5000" | jq -r '.[].uid')"
  for uid in $uids; do
    case "$uid" in
      */* | .* | "")
        echo "Error: dashboard uid '$uid' can't be used as a file name." >&2
        exit 1
        ;;
    esac
    grafana_get "/api/dashboards/uid/$uid" | jq -S '.dashboard | del(.id, .version)' >"$staging/$uid.json"
  done

  mkdir -p "$DASHBOARDS_DIR"
  local exported=0 changed=0 file
  for uid in $uids; do
    exported=$((exported + 1))
    if ! cmp -s "$staging/$uid.json" "$DASHBOARDS_DIR/$uid.json"; then
      cp "$staging/$uid.json" "$DASHBOARDS_DIR/$uid.json"
      changed=$((changed + 1))
      echo "Wrote $DASHBOARDS_DIR/$uid.json"
    fi
  done
  echo "Exported $exported dashboards from the Repo folder to $DASHBOARDS_DIR ($changed changed)."

  for file in "$DASHBOARDS_DIR"/*.json; do
    [ -e "$file" ] || continue
    uid="$(jq -r '.uid // empty' "$file" 2>/dev/null || true)"
    if [ -z "$uid" ] || ! grep -qxF -- "$uid" <<<"$uids"; then
      echo "Not in the Repo folder: $file (uid '${uid:-none}'). Left in place; delete it with git if it should go."
    fi
  done
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi

command="$1"
shift

case "$command" in
  up | down | status | export-dashboards)
    if [ "$#" -gt 0 ]; then
      usage >&2
      exit 2
    fi
    ;;
  reset)
    for arg in "$@"; do
      case "$arg" in
        --grafana | --yes) ;;
        *)
          usage >&2
          exit 2
          ;;
      esac
    done
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

require_tools docker curl
case "$command" in
  export-dashboards) export_dashboards ;;
  *) "$command" "$@" ;;
esac
