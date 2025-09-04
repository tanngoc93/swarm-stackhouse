#!/bin/bash

# deploy_and_cleanup.sh - Deploy or update a Docker Swarm stack and remove old images.
#
# Environment variables:
#   IMAGE_TAG       - Image tag to deploy (default: latest)
#   IMAGE_REPO      - Repository for the image (required)
#   STACK_NAME      - Name of the stack (required)
#   STACK_FILE      - Path to stack file (required)
#   LOG_FILE        - Output log (default: /var/log/deploy_${STACK_NAME}.log)
#   LOCK_FILE       - PID lock file (default: /tmp/deploy_${STACK_NAME}.pid)
#   CLEANUP_SCRIPT     - Script to run after deployment (default: ./scripts/run_swarm_cleanup.sh)
#   CLEANUP_STACK_FILE - Stack file used by the cleanup script (default: ./docker/cleanup-stack.yml)
#   CLEANUP_STACK_NAME - Stack name used by the cleanup script (default: swarm-cleanup)

IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE_REPO="${IMAGE_REPO:-}"
STACK_NAME="${STACK_NAME:-}"
STACK_FILE="${STACK_FILE:-}"
LOG_FILE="${LOG_FILE:-/var/log/deploy_${STACK_NAME}_uniq.log}"
LOCK_FILE="${LOCK_FILE:-/tmp/deploy_${STACK_NAME}_uniq.pid}"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CLEANUP_SCRIPT="${CLEANUP_SCRIPT:-$SCRIPT_DIR/scripts/run_swarm_cleanup.sh}"
CLEANUP_STACK_FILE="${CLEANUP_STACK_FILE:-$SCRIPT_DIR/docker/cleanup-stack.yml}"
CLEANUP_STACK_NAME="${CLEANUP_STACK_NAME:-swarm-cleanup}"

if [[ -z "$IMAGE_REPO" || -z "$STACK_NAME" || -z "$STACK_FILE" ]]; then
  echo "IMAGE_REPO, STACK_NAME and STACK_FILE must be set" >&2
  exit 1
fi

# Kill old deploy process if running
if [[ -f "$LOCK_FILE" ]]; then
  PREV_PID=$(cat "$LOCK_FILE")
  if ps -p "$PREV_PID" > /dev/null 2>&1; then
    echo "⚠️ Killing old deploy process (PID $PREV_PID)..."
    kill "$PREV_PID" || true
    sleep 2
  fi
  rm -f "$LOCK_FILE"
fi

(
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT

  set -euo pipefail

  # Load environment variables from system
  set -a
  source /etc/environment 2>/dev/null || true
  set +a

  log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$STACK_NAME|$IMAGE_TAG] $1"
  }

  START_TS=$(date +%s)

  log_message "🚀 Deploying stack: $STACK_NAME"
  log_message "📦 Using image: $IMAGE_REPO:$IMAGE_TAG"
  log_message "📄 Stack file: $STACK_FILE"

  IMAGE_REF="$IMAGE_REPO:$IMAGE_TAG"

  log_message "📥 Pulling image: $IMAGE_REF"
  if ! docker pull "$IMAGE_REF" > /dev/null 2>&1; then
    log_message "[❌] Failed to pull image: $IMAGE_REF"
    exit 1
  fi

  if [[ "$IMAGE_TAG" == "latest" ]]; then
    log_message "🔍 Resolving digest for latest tag..."
    IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE_REF" 2>/dev/null || true)
    if [[ -z "$IMAGE_DIGEST" ]]; then
      log_message "[❌] Failed to resolve digest for $IMAGE_REF"
      exit 1
    fi
    IMAGE_REF="$IMAGE_DIGEST"
    log_message "✅ Using digest: $IMAGE_REF"
  else
    log_message "✅ Using specific tag: $IMAGE_REF"
  fi

  UPDATE_SERVICES=true
  if [[ -z $(docker stack services "$STACK_NAME" --format '{{.Name}}') ]]; then
    log_message "⚙️ Stack '$STACK_NAME' is missing. Deploying from scratch..."
    if ! IMAGE_NAME="$IMAGE_REF" docker stack deploy -c "$STACK_FILE" --with-registry-auth "$STACK_NAME" > /dev/null 2>&1; then
      log_message "[❌] Failed to deploy stack: $STACK_NAME"
      exit 1
    fi
    log_message "✅ Stack deployed successfully."
    UPDATE_SERVICES=false
  else
    log_message "✅ Stack is running. Proceeding to update services..."
  fi

  STACK_SERVICES=($(docker stack services "$STACK_NAME" --format '{{.Name}}'))

  if $UPDATE_SERVICES; then
    for SERVICE_NAME in "${STACK_SERVICES[@]}"; do
      if ! docker service inspect "$SERVICE_NAME" > /dev/null 2>&1; then
        log_message "[⚠️] Skipping not found service: $SERVICE_NAME"
        continue
      fi

      log_message "🔄 Updating service: $SERVICE_NAME"
      if docker service update --image "$IMAGE_REF" --force "$SERVICE_NAME" > /dev/null 2>&1; then
        log_message "✅ Done updating: $SERVICE_NAME"
      else
        log_message "[❌] Failed to update: $SERVICE_NAME"
        exit 1
      fi
    done
    log_message "✅ All services updated with image: $IMAGE_REF"
  else
    log_message "ℹ️ Skipped update — stack was just deployed."
  fi

  DEPLOY_DURATION=$(( $(date +%s) - START_TS ))
  log_message "🏁 Deploy completed in ${DEPLOY_DURATION}s"

  # Ensure cleanup script is executable
  if [[ -f "$CLEANUP_SCRIPT" && ! -x "$CLEANUP_SCRIPT" ]]; then
    log_message "⏳ Waiting 30s before cleanup..."
    sleep 30
    log_message "🧹 Running swarm image cleanup..."
    STACK_FILE="$CLEANUP_STACK_FILE" STACK_NAME="$CLEANUP_STACK_NAME" IMAGE_REPO="$IMAGE_REPO" bash "$CLEANUP_SCRIPT" >> "$LOG_FILE" 2>&1
    log_message "✅ Swarm image cleanup finished..."
  else
    log_message "[⚠️] Cleanup script not found or not executable: $CLEANUP_SCRIPT"
  fi

) >> "$LOG_FILE" 2>&1 &
