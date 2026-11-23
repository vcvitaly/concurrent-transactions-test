#!/usr/bin/env bash
# Deploys Postgres and the service to the current kubectl context, or removes them.
#
#   ./deploy.sh              build the images, install or upgrade both charts, then start speedbump
#   ./deploy.sh --teardown   remove speedbump, uninstall both charts and permanently delete the
#                            database volume
#
# Set NAMESPACE to override the target namespace.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

NAMESPACE="${NAMESPACE:-concurrent-transactions}"
TIMEOUT="5m"
POSTGRES_RELEASE="postgres"
APP_RELEASE="app"
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

stop_speedbump() {
  kubectl -n "$NAMESPACE" delete pod "$SPEEDBUMP_POD" --ignore-not-found --timeout "$TIMEOUT"
  kubectl -n "$NAMESPACE" delete service "$PROXY_SERVICE" --ignore-not-found --timeout "$TIMEOUT"
}

deploy() {
  echo "Deploying to context '$1', namespace '$NAMESPACE'"

  build_image
  echo "Built image $IMAGE_REPOSITORY:$IMAGE_TAG"

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

  start_speedbump

  echo "Deployment complete. See README.md to port-forward speedbump to localhost:$SPEEDBUMP_PORT."
}

teardown() {
  echo "Tearing down from context '$1', namespace '$NAMESPACE'"

  stop_speedbump
  # The app goes first so it is not left running without its database.
  helm uninstall "$APP_RELEASE" --namespace "$NAMESPACE" --ignore-not-found --wait --timeout "$TIMEOUT"
  helm uninstall "$POSTGRES_RELEASE" --namespace "$NAMESPACE" --ignore-not-found --wait --timeout "$TIMEOUT"
  # StatefulSet volumes outlive the Helm release, so the claim is removed explicitly.
  kubectl delete pvc "$DATABASE_VOLUME_CLAIM" --namespace "$NAMESPACE" --ignore-not-found --timeout "$TIMEOUT"

  echo "Teardown complete. The database volume was deleted and the namespace was kept."
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
fi
context="$(current_context)"
"$action" "$context"
