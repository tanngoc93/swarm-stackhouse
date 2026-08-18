#!/usr/bin/env bash
set -euo pipefail

# manual_rollback.sh - Roll back services in a Docker Swarm stack to a previously deployed image digest.
#
# Usage:
#   STACK_NAME=my_stack IMAGE_REPO=myorg/myimage ./scripts/manual_rollback.sh
#   STACK_NAME=my_stack IMAGE_REPO=myorg/myimage TARGET_DIGEST=sha256:deadbeef ./scripts/manual_rollback.sh
#
# Environment variables (with defaults):
#   IMAGE_REPO    Image repository (default: myorg/myapp)
#   STACK_NAME    Stack name (default: app_stack)
#   DIGEST_DIR    Directory storing digest logs (default: ../digests)
#   DIGEST_FILE   File storing digests (default: ../digests/app_stack_image_digests.log)
#   TARGET_DIGEST Digest to roll back to (optional; prompts if unset)

# -------- Config (defaults) --------
IMAGE_REPO="${IMAGE_REPO:-myorg/myapp}"
STACK_NAME="${STACK_NAME:-app_stack}"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
DIGEST_DIR="${DIGEST_DIR:-$REPO_ROOT/digests}"
DIGEST_FILE="${DIGEST_FILE:-$DIGEST_DIR/${STACK_NAME}_image_digests.log}"
TARGET_DIGEST="${TARGET_DIGEST:-}"
LOG_TAG="rollback"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$STACK_NAME|$LOG_TAG] $1"; }
require() { command -v "$1" >/dev/null 2>&1 || { echo "command not found: $1" >&2; exit 1; }; }

update_service() {
  local service_name="$1"
  local image_ref="$2"
  local restart_condition previous_task_id task_id task_state exit_code

  restart_condition=$(docker service inspect "$service_name" \
    --format '{{if .Spec.TaskTemplate.RestartPolicy}}{{.Spec.TaskTemplate.RestartPolicy.Condition}}{{end}}')
  if [[ "$restart_condition" != "none" ]]; then
    docker service update --image "$image_ref" --force "$service_name"
    return
  fi

  previous_task_id=$(docker service ps "$service_name" --no-trunc --format '{{.ID}}' | head -n 1)
  docker service update --detach=true --image "$image_ref" --force "$service_name"
  for _ in $(seq 1 120); do
    task_id=$(docker service ps "$service_name" --no-trunc --format '{{.ID}}' | head -n 1)
    if [[ -n "$task_id" && "$task_id" != "$previous_task_id" ]]; then
      task_state=$(docker inspect --format '{{.Status.State}}' "$task_id" 2>/dev/null || true)
      case "$task_state" in
        complete)
          exit_code=$(docker inspect \
            --format '{{if .Status.ContainerStatus}}{{.Status.ContainerStatus.ExitCode}}{{else}}1{{end}}' \
            "$task_id" 2>/dev/null || echo 1)
          [[ "$exit_code" == "0" ]]
          return
          ;;
        failed|rejected|orphaned)
          docker service ps "$service_name" --no-trunc >&2 || true
          return 1
          ;;
      esac
    fi
    sleep 2
  done
  echo "Timed out waiting for one-shot service: $service_name" >&2
  return 1
}

main() {
  if [[ -z "$STACK_NAME" || -z "$IMAGE_REPO" ]]; then
    echo "STACK_NAME and IMAGE_REPO must be set" >&2
    exit 1
  fi

  require docker

  if [[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || true)" != "true" ]]; then
    echo "This command must run on a Docker Swarm manager." >&2
    exit 1
  fi

  if [[ ! -f "$DIGEST_FILE" ]]; then
    {
      echo "Digest log not found: $DIGEST_FILE"
      echo "Run scripts/deploy_and_cleanup.sh to generate it or set DIGEST_FILE to an existing log."
    } >&2
    exit 1
  fi

  mapfile -t DIGESTS < "$DIGEST_FILE"
  if [[ ${#DIGESTS[@]} -eq 0 ]]; then
    echo "No digests available in $DIGEST_FILE" >&2
    exit 1
  fi

  if [[ -z "$TARGET_DIGEST" ]]; then
    echo "Available digests for $STACK_NAME:"
    for i in "${!DIGESTS[@]}"; do
      echo "$((i+1))) ${DIGESTS[$i]}"
    done
    read -p "Select digest number (0 to exit): " sel
    if [[ -z "$sel" || ! "$sel" =~ ^[0-9]+$ ]]; then
      echo "Invalid selection" >&2
      exit 1
    fi
    if [[ "$sel" -eq 0 ]]; then
      echo "Exiting without rollback."
      exit 0
    fi
    idx=$((sel-1))
    if (( idx < 0 || idx >= ${#DIGESTS[@]} )); then
      echo "Selection out of range" >&2
      exit 1
    fi
    TARGET_DIGEST="${DIGESTS[$idx]}"
  fi

  LOG_TAG="$TARGET_DIGEST"
  image_ref="$IMAGE_REPO@$TARGET_DIGEST"

  log "📥 Pulling image: $image_ref"
  if ! docker pull "$image_ref" >/dev/null 2>&1; then
    log "[❌] Failed to pull image: $image_ref"
    exit 1
  fi

  log "🔄 Updating services in stack: $STACK_NAME"
  mapfile -t SERVICES < <(docker stack services "$STACK_NAME" --format '{{.Name}}')
  if [[ ${#SERVICES[@]} -eq 0 ]]; then
    log "[❌] Stack has no services or does not exist: $STACK_NAME"
    exit 1
  fi
  for svc in "${SERVICES[@]}"; do
    service_image=$(docker service inspect "$svc" \
      --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
    if [[ "$service_image" != "$IMAGE_REPO:"* && "$service_image" != "$IMAGE_REPO@"* ]]; then
      log "Skipping service with a different image repository: $svc ($service_image)"
      continue
    fi
    log "Updating service: $svc"
    if update_service "$svc" "$image_ref"; then
      log "✅ Updated: $svc"
    else
      log "[❌] Failed to update: $svc"
      exit 1
    fi
  done

  log "✅ Rollback complete"
}

main "$@"

exit 0
