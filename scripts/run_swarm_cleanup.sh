#!/bin/bash
set -euo pipefail

# run_swarm_cleanup.sh - deploy a temporary stack to clean unused images on all nodes.
#
# Environment variables:
#   IMAGE_REPO - Repository to clean (required)
#   STACK_FILE - Path to the cleanup stack file (default: ../docker/cleanup-stack.yml)
#   STACK_NAME - Name of the cleanup stack (default: swarm-cleanup)

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
STACK_FILE="${STACK_FILE:-$SCRIPT_DIR/../docker/cleanup-stack.yml}"
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
RUN_TIMESTAMP=$(date +%s) IMAGE_REPO="$IMAGE_REPO" docker stack deploy -c "$STACK_FILE" "$STACK_NAME"

echo "⏳ Waiting for cleanup tasks..."
while true; do
  TASK_STATE=$(docker service ps "${STACK_NAME}_swarm_cleanup" \
    --no-trunc --format "{{.CurrentState}}" 2>/dev/null | head -n1)

  echo "State: $TASK_STATE"

  if [[ "$TASK_STATE" == *"Complete"* ]] || [[ "$TASK_STATE" == *"Shutdown"* ]]; then
    echo "✅ Cleanup finished"
    break
  fi

  if [[ "$TASK_STATE" == *"Failed"* ]]; then
    echo "❌ Cleanup failed"
    break
  fi

  sleep 3
done

echo "🧹 Removing stack..."
docker stack rm "$STACK_NAME"
