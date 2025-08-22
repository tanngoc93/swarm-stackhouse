#!/bin/bash
set -e

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
STACK_FILE="$SCRIPT_DIR/../docker/docker-cleaner-stack.yml"
STACK_NAME="cleanup"

echo "🚀 Deploy cleanup stack..."
RUN_AT=$(date +%s) IMAGE_REPO="${IMAGE_REPO}" docker stack deploy -c $STACK_FILE $STACK_NAME

echo "⏳ Waiting for cleanup tasks..."
while true; do
  STATUS=$(docker service ps ${STACK_NAME}_swarm_cleanup \
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
docker stack rm $STACK_NAME
