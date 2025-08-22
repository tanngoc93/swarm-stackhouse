#!/bin/bash
set -euo pipefail

# Environment variables:
#   IMAGE_REPO - Repository to clean (required)
#   STACK_FILE - Path to the cleanup stack file (default: ../docker/docker-cleaner-stack.yml)
#   STACK_NAME - Name of the cleanup stack (default: swarm-cleanup)

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
STACK_FILE="${STACK_FILE:-$SCRIPT_DIR/../docker/docker-cleaner-stack.yml}"
STACK_NAME="${STACK_NAME:-swarm-cleanup}"
IMAGE_REPO="${IMAGE_REPO:-}"

if [[ -z "$IMAGE_REPO" ]]; then
  echo "IMAGE_REPO must be set" >&2
  exit 1
fi

if [[ ! -f "$STACK_FILE" ]]; then
  echo "Stack file not found: $STACK_FILE" >&2
  exit 1
fi

echo "🚀 Deploy cleanup stack..."
RUN_AT=$(date +%s) IMAGE_REPO="$IMAGE_REPO" docker stack deploy -c "$STACK_FILE" "$STACK_NAME"

echo "⏳ Waiting for cleanup tasks..."
while true; do
  STATUS=$(docker service ps "${STACK_NAME}_swarm_cleanup" \
    --no-trunc --format "{{.CurrentState}}" 2>/dev/null | head -n1)

  echo "State: $STATUS"

  if [[ "$STATUS" == *"Complete"* ]] || [[ "$STATUS" == *"Shutdown"* ]]; then
    echo "✅ Cleanup finished"
    break
  fi

  if [[ "$STATUS" == *"Failed"* ]]; then
    echo "❌ Cleanup failed"
    break
  fi

  sleep 3
done

echo "🧹 Removing stack..."
docker stack rm "$STACK_NAME"
