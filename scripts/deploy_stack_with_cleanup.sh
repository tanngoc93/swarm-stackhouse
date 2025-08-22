#!/bin/bash

# deploy_stack_with_cleanup.sh - Deploy or update a Docker Swarm stack and clean up old images.
#
# Environment variables:
#   IMAGE_TAG       - Image tag to deploy (default: latest)
#   IMAGE_REPO      - Repository for the image (required)
#   STACK_NAME      - Name of the stack (required)
#   STACK_FILE      - Path to stack file (required)
#   LOG_FILE        - Output log (default: /var/log/deploy_${STACK_NAME}.log)
#   LOCK_FILE       - PID lock file (default: /tmp/deploy_${STACK_NAME}.pid)
#   CLEANUP_SCRIPT     - Script to run after deployment (default: ../swarm_cleanup.sh)
#   CLEANUP_STACK_FILE - Stack file used by the cleanup script (required)
#   CLEANUP_STACK_NAME - Stack name used by the cleanup script (required)

IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE_REPO="${IMAGE_REPO:-}"
STACK_NAME="${STACK_NAME:-}"
STACK_FILE="${STACK_FILE:-}"
LOG_FILE="${LOG_FILE:-/var/log/deploy_${STACK_NAME}.log}"
LOCK_FILE="${LOCK_FILE:-/tmp/deploy_${STACK_NAME}.pid}"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CLEANUP_SCRIPT="${CLEANUP_SCRIPT:-$SCRIPT_DIR/../swarm_cleanup.sh}"
CLEANUP_STACK_FILE="${CLEANUP_STACK_FILE:-}"
CLEANUP_STACK_NAME="${CLEANUP_STACK_NAME:-}"

if [[ -z "$IMAGE_REPO" || -z "$STACK_NAME" || -z "$STACK_FILE" || -z "$CLEANUP_STACK_FILE" || -z "$CLEANUP_STACK_NAME" ]]; then
  echo "IMAGE_REPO, STACK_NAME, STACK_FILE, CLEANUP_STACK_FILE and CLEANUP_STACK_NAME must be set" >&2
  exit 1
fi

# Kill old deploy process if running
if [[ -f "$LOCK_FILE" ]]; then
  OLD_PID=$(cat "$LOCK_FILE")
  if ps -p "$OLD_PID" > /dev/null 2>&1; then
    echo "⚠️ Killing old deploy process (PID $OLD_PID)..."
    kill "$OLD_PID" || true
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

  log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$STACK_NAME|$IMAGE_TAG] $1"
  }

  START_TIME=$(date +%s)

  log "🚀 Deploying stack: $STACK_NAME"
  log "📦 Using image: $IMAGE_REPO:$IMAGE_TAG"
  log "📄 Stack file: $STACK_FILE"

  IMAGE_NAME="$IMAGE_REPO:$IMAGE_TAG"

  log "📥 Pulling image: $IMAGE_NAME"
  if ! docker pull "$IMAGE_NAME" > /dev/null 2>&1; then
    log "[❌] Failed to pull image: $IMAGE_NAME"
    exit 1
  fi

  if [[ "$IMAGE_TAG" == "latest" ]]; then
    log "🔍 Resolving digest for latest tag..."
    DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE_NAME" 2>/dev/null || true)
    if [[ -z "$DIGEST" ]]; then
      log "[❌] Failed to resolve digest for $IMAGE_NAME"
      exit 1
    fi
    IMAGE_NAME="$DIGEST"
    log "✅ Using digest: $IMAGE_NAME"
  else
    log "✅ Using specific tag: $IMAGE_NAME"
  fi

  NEED_UPDATE_SERVICES=true
  if [[ -z $(docker stack services "$STACK_NAME" --format '{{.Name}}') ]]; then
    log "⚙️ Stack '$STACK_NAME' is missing. Deploying from scratch..."
    if ! IMAGE_NAME="$IMAGE_NAME" docker stack deploy -c "$STACK_FILE" --with-registry-auth "$STACK_NAME" > /dev/null 2>&1; then
      log "[❌] Failed to deploy stack: $STACK_NAME"
      exit 1
    fi
    log "✅ Stack deployed successfully."
    NEED_UPDATE_SERVICES=false
  else
    log "✅ Stack is running. Proceeding to update services..."
  fi

  SERVICES=($(docker stack services "$STACK_NAME" --format '{{.Name}}'))

  if $NEED_UPDATE_SERVICES; then
    for SERVICE in "${SERVICES[@]}"; do
      if ! docker service inspect "$SERVICE" > /dev/null 2>&1; then
        log "[⚠️] Skipping not found service: $SERVICE"
        continue
      fi

      log "🔄 Updating service: $SERVICE"
      if docker service update --image "$IMAGE_NAME" --force "$SERVICE" > /dev/null 2>&1; then
        log "✅ Done updating: $SERVICE"
      else
        log "[❌] Failed to update: $SERVICE"
        exit 1
      fi
    done
    log "✅ All services updated with image: $IMAGE_NAME"
  else
    log "ℹ️ Skipped update — stack was just deployed."
  fi

  DURATION=$(( $(date +%s) - START_TIME ))
  log "🏁 Deploy completed in ${DURATION}s"

  if [[ -x "$CLEANUP_SCRIPT" ]]; then
    log "⏳ Waiting 30s before cleanup..."
    sleep 30
    log "🧹 Running swarm image cleanup..."
    STACK_FILE="$CLEANUP_STACK_FILE" STACK_NAME="$CLEANUP_STACK_NAME" IMAGE_REPO="$IMAGE_REPO" bash "$CLEANUP_SCRIPT" >> "$LOG_FILE" 2>&1
    log "✅ Swarm image cleanup finished..."
  else
    log "[⚠️] Cleanup script not found or not executable: $CLEANUP_SCRIPT"
  fi

) >> "$LOG_FILE" 2>&1 &
