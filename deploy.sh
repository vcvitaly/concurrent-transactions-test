#!/usr/bin/env bash
# Deploys Postgres and the service to the current kubectl context, or removes them.
#
#   ./deploy.sh              build the app image, then install or upgrade both charts
#   ./deploy.sh --teardown   uninstall both charts, keeping the database volume
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
IMAGE_REPOSITORY="concurrent-transactions-test"

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

  echo "Deployment complete."
}

teardown() {
  echo "Tearing down from context '$1', namespace '$NAMESPACE'"

  # The app goes first so it is not left running without its database.
  helm uninstall "$APP_RELEASE" --namespace "$NAMESPACE" --ignore-not-found --wait --timeout "$TIMEOUT"
  helm uninstall "$POSTGRES_RELEASE" --namespace "$NAMESPACE" --ignore-not-found --wait --timeout "$TIMEOUT"

  echo "Teardown complete. The database volume and namespace were kept."
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
