#!/usr/bin/env bash
set -euo pipefail

# deploy_and_cleanup.sh - Deploy or update a Docker Swarm stack and remove old images.
#
# Environment variables:
#   IMAGE_TAG        Image tag to deploy (default: latest)
#   IMAGE_REPO       Repository for the image (required)
#   STACK_NAME       Name of the stack (required)
#   STACK_FILE       Path to stack file (required)
#   LOG_FILE         Output log (default: /var/log/deploy_${STACK_NAME}_uniq.log)
#   LOCK_FILE        PID lock file (default: /tmp/deploy_${STACK_NAME}_uniq.pid)
#   CLEANUP_SCRIPT      Script to run after deployment (default: ./scripts/run_swarm_cleanup.sh)
#   CLEANUP_STACK_FILE  Stack file used by the cleanup script (default: ./docker/cleanup-stack.yml)
#   CLEANUP_STACK_NAME  Stack name used by the cleanup script (default: swarm-cleanup)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$STACK_NAME|$IMAGE_TAG] $1"; }
require() { command -v "$1" >/dev/null 2>&1 || { echo "command not found: $1" >&2; exit 1; }; }

main() {
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

  require docker

  if [[ -f "$LOCK_FILE" ]]; then
    prev_pid=$(cat "$LOCK_FILE")
    if ps -p "$prev_pid" >/dev/null 2>&1; then
      echo "⚠️ Killing old deploy process (PID $prev_pid)..."
      kill "$prev_pid" || true
      sleep 2
    fi
    rm -f "$LOCK_FILE"
  fi

  (
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
    set -euo pipefail
    START_TS=$(date +%s)

    set -a
    source /etc/environment 2>/dev/null || true
    set +a

    log "🚀 Deploying stack: $STACK_NAME"
    log "📦 Using image: $IMAGE_REPO:$IMAGE_TAG"
    log "📄 Stack file: $STACK_FILE"

    image_ref="$IMAGE_REPO:$IMAGE_TAG"
    log "📥 Pulling image: $image_ref"
    if ! docker pull "$image_ref" >/dev/null 2>&1; then
      log "[❌] Failed to pull image: $image_ref"
      exit 1
    fi

    if [[ "$IMAGE_TAG" == "latest" ]]; then
      log "🔍 Resolving digest for latest tag..."
      image_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$image_ref" 2>/dev/null || true)
      if [[ -z "$image_digest" ]]; then
        log "[❌] Failed to resolve digest for $image_ref"
        exit 1
      fi
      image_ref="$image_digest"
      log "✅ Using digest: $image_ref"
    else
      log "✅ Using specific tag: $image_ref"
    fi

    update_services=true
    if [[ -z $(docker stack services "$STACK_NAME" --format '{{.Name}}') ]]; then
      log "⚙️ Stack '$STACK_NAME' is missing. Deploying from scratch..."
      if ! IMAGE_NAME="$image_ref" docker stack deploy -c "$STACK_FILE" --with-registry-auth "$STACK_NAME" >/dev/null 2>&1; then
        log "[❌] Failed to deploy stack: $STACK_NAME"
        exit 1
      fi
      log "✅ Stack deployed successfully."
      update_services=false
    else
      log "✅ Stack is running. Proceeding to update services..."
    fi

    stack_services=($(docker stack services "$STACK_NAME" --format '{{.Name}}'))

    if $update_services; then
      for service_name in "${stack_services[@]}"; do
        if ! docker service inspect "$service_name" >/dev/null 2>&1; then
          log "[⚠️] Skipping not found service: $service_name"
          continue
        fi
        log "🔄 Updating service: $service_name"
        if docker service update --image "$image_ref" --force "$service_name" >/dev/null 2>&1; then
          log "✅ Done updating: $service_name"
        else
          log "[❌] Failed to update: $service_name"
          exit 1
        fi
      done
      log "✅ All services updated with image: $image_ref"
    else
      log "ℹ️ Skipped update — stack was just deployed."
    fi

    deploy_duration=$(( $(date +%s) - START_TS ))
    log "🏁 Deploy completed in ${deploy_duration}s"

    if [[ -f "$CLEANUP_SCRIPT" && -x "$CLEANUP_SCRIPT" ]]; then
      log "⏳ Waiting 30s before cleanup..."
      sleep 30
      log "🧹 Running swarm image cleanup..."
      STACK_FILE="$CLEANUP_STACK_FILE" STACK_NAME="$CLEANUP_STACK_NAME" IMAGE_REPO="$IMAGE_REPO" bash "$CLEANUP_SCRIPT" >> "$LOG_FILE" 2>&1
      log "✅ Swarm image cleanup finished..."
    else
      log "[⚠️] Cleanup script not found or not executable: $CLEANUP_SCRIPT"
    fi
  ) >> "$LOG_FILE" 2>&1 &
}

main "$@"
