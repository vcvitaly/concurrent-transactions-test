#!/usr/bin/env bash
# Manages the long-term metrics store: VictoriaMetrics in Docker, outside the cluster.
# deploy.sh never starts, stops or deletes it, so history survives cluster teardowns.
#
#   ./metrics.sh up              start the store and wait until it is healthy
#   ./metrics.sh down            stop the store, keeping its data
#   ./metrics.sh reset [--yes]   stop the store and permanently delete all its data
#   ./metrics.sh status          show health and the newest scraped sample
#
# The store listens on 127.0.0.1:8428 by default. Set METRICS_BIND_ADDRESS to listen on another
# address; the store has no authentication, so anything that can reach it can read and write it.
# Set METRICS_RETENTION to change the retention period (months, or a value with an h/d/w/y suffix).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

COMPOSE_FILE="metrics/compose.yaml"
VOLUME="victoriametrics-data"
BIND_ADDRESS="${METRICS_BIND_ADDRESS:-127.0.0.1}"
STORE_URL="http://localhost:8428"
HEALTH_TIMEOUT_SECONDS=60
APP_JOB="concurrent-transactions"

usage() {
  echo "Usage: $0 up | down | reset [--yes] | status"
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
  docker compose -f "$COMPOSE_FILE" "$@"
}

is_loopback() {
  case "$1" in
    127.* | localhost | ::1 | "[::1]") return 0 ;;
    *) return 1 ;;
  esac
}

healthy() {
  curl -fsS --max-time 2 "$STORE_URL/health" >/dev/null 2>&1
}

up() {
  if ! is_loopback "$BIND_ADDRESS"; then
    echo "Warning: METRICS_BIND_ADDRESS=$BIND_ADDRESS exposes the store beyond loopback." >&2
    echo "Warning: its write and query API has no authentication and is reachable from the network." >&2
  fi
  compose up -d

  local waited=0
  until healthy; do
    if [ "$waited" -ge "$HEALTH_TIMEOUT_SECONDS" ]; then
      echo "Error: the store did not become healthy within ${HEALTH_TIMEOUT_SECONDS}s." >&2
      compose logs --tail 20 >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "Store is up: $STORE_URL/vmui (listening on $BIND_ADDRESS:8428)"
}

down() {
  compose down
  echo "Store stopped. Its data is kept in the Docker volume $VOLUME."
}

reset() {
  local confirmed="${1:-}"
  if [ "$confirmed" != "--yes" ]; then
    if [ ! -t 0 ]; then
      echo "Error: reset deletes all stored metrics. Run it in a terminal, or pass --yes." >&2
      exit 1
    fi
    local answer
    read -r -p "Permanently delete all stored metrics in volume $VOLUME? [y/N] " answer || answer=""
    case "$answer" in
      y | Y | yes | YES) ;;
      *)
        echo "Reset cancelled."
        exit 1
        ;;
    esac
  fi
  compose down --volumes
  echo "Store stopped and volume $VOLUME deleted."
}

status() {
  require_tools jq
  if ! healthy; then
    echo "Store: not reachable at $STORE_URL"
    exit 1
  fi
  echo "Store: healthy at $STORE_URL"

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

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi

command="$1"
shift

case "$command" in
  up | down | status)
    if [ "$#" -gt 0 ]; then
      usage >&2
      exit 2
    fi
    ;;
  reset)
    if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--yes" ]; }; then
      usage >&2
      exit 2
    fi
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
"$command" "$@"
