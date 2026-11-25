#!/usr/bin/env bash
# Deploys Postgres, the service and the Prometheus collector to the current kubectl context, or
# removes them.
#
#   ./deploy.sh              build the images, install or upgrade Postgres, the app and Prometheus,
#                            then start speedbump
#   ./deploy.sh --teardown   remove speedbump and the app, wait for Prometheus to forward what it
#                            scraped, uninstall Prometheus and Postgres, and permanently delete the
#                            database volume
#
# Set NAMESPACE to override the target namespace. Set METRICS_REMOTE_WRITE_URL to forward metrics
# somewhere other than the local store (see metrics.sh). This script never touches that store.
# Set DEPLOY_KIND_CLUSTER to the name of the kind cluster the current context points at, to load the
# locally built images into it (kind is required only then). Docker Desktop's Kubernetes doesn't
# need it, because it shares Docker's image store.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

NAMESPACE="${NAMESPACE:-concurrent-transactions}"
TIMEOUT="5m"
POSTGRES_RELEASE="postgres"
APP_RELEASE="app"
PROMETHEUS_RELEASE="prometheus"
PROMETHEUS_SERVICE="prometheus"
PROMETHEUS_CONFIG_MAP="${PROMETHEUS_SERVICE}-config"
METRICS_DNS_NAME="${APP_RELEASE}-concurrent-transactions-metrics"
DRAIN_TIMEOUT_SECONDS=60
DRAIN_POLL_SECONDS=2
DATABASE_URL="jdbc:postgresql://${POSTGRES_RELEASE}:5432/concurrent_transactions"
DATABASE_SECRET="${POSTGRES_RELEASE}-credentials"
DATABASE_VOLUME_CLAIM="data-${POSTGRES_RELEASE}-0"
IMAGE_REPOSITORY="concurrent-transactions-test"
PROXY_DEPLOYMENT="${APP_RELEASE}-concurrent-transactions-proxy"
PROXY_SERVICE="app-proxy"
SPEEDBUMP_POD="speedbump"
SPEEDBUMP_IMAGE="speedbump:v1.1.0"
SPEEDBUMP_LATENCY="20ms"
SPEEDBUMP_PORT="8081"
KIND_CLUSTER="${DEPLOY_KIND_CLUSTER:-}"

usage() {
  echo "Usage: $0 [--teardown]"
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

current_context() {
  local context
  if ! context="$(kubectl config current-context 2>/dev/null)" || [ -z "$context" ]; then
    echo "Error: no current kubectl context is set." >&2
    exit 1
  fi
  echo "$context"
}

# Makes a locally built image available to the kind cluster, if one is set. Its nodes don't share
# Docker's image store, and the charts use IfNotPresent.
load_into_kind() {
  if [ -n "$KIND_CLUSTER" ]; then
    kind load docker-image --name "$KIND_CLUSTER" "$1" >&2
  fi
}

# Tags the image by content, so changed code always rolls out and unchanged code does not.
build_image() {
  local image_id
  # Provenance metadata has a timestamp that would change the image ID on every build.
  docker build --provenance=false -t "$IMAGE_REPOSITORY:local" . >&2
  image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE_REPOSITORY:local")"
  image_id="${image_id#sha256:}"
  IMAGE_TAG="build-${image_id:0:12}"
  docker tag "$IMAGE_REPOSITORY:local" "$IMAGE_REPOSITORY:$IMAGE_TAG"
}

# Built locally for the cluster's architecture, because the published image is amd64-only.
build_speedbump_image() {
  docker build -t "$SPEEDBUMP_IMAGE" - >&2 <<'EOF'
FROM golang:1.17.11-alpine3.16 AS builder
ADD https://github.com/kffl/speedbump.git#v1.1.0 /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -o /speedbump .

FROM scratch
COPY --from=builder /speedbump /speedbump
USER 65534:65534
ENTRYPOINT ["/speedbump"]
EOF
}

# Recreated on every deploy, because a pod's image and arguments cannot be updated in place.
start_speedbump() {
  build_speedbump_image
  load_into_kind "$SPEEDBUMP_IMAGE"

  kubectl -n "$NAMESPACE" expose deployment "$PROXY_DEPLOYMENT" \
    --name "$PROXY_SERVICE" \
    --port 8080 \
    --dry-run=client \
    -o yaml | kubectl -n "$NAMESPACE" apply -f -

  kubectl -n "$NAMESPACE" delete pod "$SPEEDBUMP_POD" --ignore-not-found --timeout "$TIMEOUT"
  kubectl -n "$NAMESPACE" run "$SPEEDBUMP_POD" \
    --image="$SPEEDBUMP_IMAGE" \
    --image-pull-policy=IfNotPresent \
    --port="$SPEEDBUMP_PORT" \
    -- --port="$SPEEDBUMP_PORT" --latency="$SPEEDBUMP_LATENCY" "$PROXY_SERVICE:8080"
  kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$SPEEDBUMP_POD" --timeout=60s
}

install_prometheus() {
  local args=(
    --namespace "$NAMESPACE"
    --set-string "scrape.dnsName=$METRICS_DNS_NAME"
  )
  if [ -n "${METRICS_REMOTE_WRITE_URL:-}" ]; then
    args+=(--set-string "remoteWrite.url=$METRICS_REMOTE_WRITE_URL")
  fi
  helm upgrade --install "$PROMETHEUS_RELEASE" helm/prometheus "${args[@]}" --wait --timeout "$TIMEOUT"
}

# Converts a Prometheus duration such as 5s, 1m or 1m30s to whole seconds.
duration_seconds() {
  local value="$1" total=0 number unit
  while [[ "$value" =~ ^([0-9]+)(ms|s|m|h)(.*)$ ]]; do
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    case "$unit" in
      ms) ;;
      s) total=$((total + number)) ;;
      m) total=$((total + number * 60)) ;;
      h) total=$((total + number * 3600)) ;;
    esac
  done
  echo "$total"
}

# Prints "pending lag failed dropped" from Prometheus's own /metrics text, read through the API
# server's service proxy, so no exec or port-forward is needed. Fails if it can't be read.
remote_write_status() {
  local metrics
  metrics="$(kubectl get --raw \
    "/api/v1/namespaces/$NAMESPACE/services/$PROMETHEUS_SERVICE:9090/proxy/metrics" \
    --request-timeout=5s 2>/dev/null)" || return 1
  awk '
    /^prometheus_remote_storage_samples_pending[{ ]/ { pending += $NF; seen = 1 }
    /^prometheus_remote_storage_highest_timestamp_in_seconds[{ ]/ { if ($NF > highest) highest = $NF }
    /^prometheus_remote_storage_queue_highest_sent_timestamp_seconds[{ ]/ { if ($NF > sent) sent = $NF }
    /^prometheus_remote_storage_samples_failed_total[{ ]/ { failed += $NF }
    /^prometheus_remote_storage_samples_dropped_total[{ ]/ { dropped += $NF }
    END {
      if (!seen) exit 1
      printf "%d %d %d %d\n", pending, highest - sent, failed, dropped
    }
  ' <<<"$metrics"
}

# Best effort: waits for Prometheus to forward what it has scraped before it is removed. Queue
# gauges don't cover samples the store rejected or samples still unread in the WAL, so this can't
# prove delivery. Prometheus also flushes on shutdown, within its termination grace period.
drain_forwarding() {
  local config
  if ! config="$(kubectl -n "$NAMESPACE" get configmap "$PROMETHEUS_CONFIG_MAP" \
    -o jsonpath='{.data.prometheus\.yml}' 2>/dev/null)"; then
    echo "Prometheus is not installed; skipping the forwarding drain."
    return
  fi
  if ! grep -q '^remote_write:' <<<"$config"; then
    echo "Remote write is disabled; skipping the forwarding drain."
    return
  fi

  local interval max_lag
  interval="$(duration_seconds "$(awk '/scrape_interval:/ { print $2; exit }' <<<"$config")")"
  max_lag=$((2 * (interval > 0 ? interval : 5)))

  echo "Waiting up to ${DRAIN_TIMEOUT_SECONDS}s for Prometheus to forward its samples..."
  local start=$SECONDS status="" pending lag failed dropped drained=false
  while [ $((SECONDS - start)) -lt "$DRAIN_TIMEOUT_SECONDS" ]; do
    if status="$(remote_write_status)"; then
      read -r pending lag failed dropped <<<"$status"
      if [ "$pending" -eq 0 ] && [ "$lag" -lt "$max_lag" ]; then
        drained=true
        break
      fi
    fi
    sleep "$DRAIN_POLL_SECONDS"
  done

  if [ -z "$status" ]; then
    echo "Warning: could not read Prometheus's forwarding status; delivery to the store was not checked." >&2
    return
  fi
  read -r pending lag failed dropped <<<"$status"
  echo "Forwarding: ${pending} pending, ${failed} failed, ${dropped} dropped samples (sent lag ${lag}s)."
  if [ "$drained" != true ]; then
    echo "Warning: forwarding did not drain within ${DRAIN_TIMEOUT_SECONDS}s; ${pending} samples are pending." \
      "Is the store running (./metrics.sh status)?" >&2
  fi
  if [ "$failed" -ne 0 ] || [ "$dropped" -ne 0 ]; then
    echo "Warning: some samples were not delivered (${failed} failed, ${dropped} dropped)." >&2
  fi
}

stop_speedbump() {
  kubectl -n "$NAMESPACE" delete pod "$SPEEDBUMP_POD" --ignore-not-found --timeout "$TIMEOUT"
  kubectl -n "$NAMESPACE" delete service "$PROXY_SERVICE" --ignore-not-found --timeout "$TIMEOUT"
}

deploy() {
  echo "Deploying to context '$1', namespace '$NAMESPACE'"

  build_image
  echo "Built image $IMAGE_REPOSITORY:$IMAGE_TAG"
  load_into_kind "$IMAGE_REPOSITORY:$IMAGE_TAG"

  helm upgrade --install "$POSTGRES_RELEASE" helm/postgres \
    --namespace "$NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout "$TIMEOUT"

  helm upgrade --install "$APP_RELEASE" helm/concurrent-transactions \
    --namespace "$NAMESPACE" \
    --set-string "image.repository=$IMAGE_REPOSITORY" \
    --set-string "image.tag=$IMAGE_TAG" \
    --set-string "database.url=$DATABASE_URL" \
    --set-string "database.existingSecret=$DATABASE_SECRET" \
    --wait \
    --timeout "$TIMEOUT"

  install_prometheus

  start_speedbump

  echo "Deployment complete. See README.md to port-forward speedbump to localhost:$SPEEDBUMP_PORT."
}

teardown() {
  echo "Tearing down from context '$1', namespace '$NAMESPACE'"

  stop_speedbump
  # The app goes first so it is not left running without its database, and so the last scrapes
  # happen before Prometheus forwards them.
  helm uninstall "$APP_RELEASE" --namespace "$NAMESPACE" --ignore-not-found --wait --timeout "$TIMEOUT"
  drain_forwarding
  helm uninstall "$PROMETHEUS_RELEASE" --namespace "$NAMESPACE" --ignore-not-found --wait --timeout "$TIMEOUT"
  helm uninstall "$POSTGRES_RELEASE" --namespace "$NAMESPACE" --ignore-not-found --wait --timeout "$TIMEOUT"
  # StatefulSet volumes outlive the Helm release, so the claim is removed explicitly.
  kubectl delete pvc "$DATABASE_VOLUME_CLAIM" --namespace "$NAMESPACE" --ignore-not-found --timeout "$TIMEOUT"

  echo "Teardown complete. The database volume was deleted and the namespace was kept." \
    "The metrics store outside the cluster was not touched."
}

case "${1:-}" in
  "")
    action=deploy
    ;;
  --teardown)
    action=teardown
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

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

require_tools helm kubectl
if [ "$action" = deploy ]; then
  require_tools docker
  if [ -n "$KIND_CLUSTER" ]; then
    require_tools kind
  fi
fi
context="$(current_context)"
"$action" "$context"
