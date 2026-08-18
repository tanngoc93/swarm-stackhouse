#!/usr/bin/env bash
set -euo pipefail

# deploy_and_cleanup.sh - Deploy or update a Docker Swarm stack and remove old images.
#
# Environment variables:
#   IMAGE_TAG        Image tag to deploy (default: latest)
#   IMAGE_REPO       Repository for the image (required)
#   STACK_NAME       Name of the stack (required)
#   STACK_FILE       Path to stack file (required)
#   LOG_FILE         Output log (default: <repo_root>/log/deploy_${STACK_NAME}_uniq.log)
#   LOCK_FILE        PID lock file (default: /tmp/deploy_${STACK_NAME}_uniq.pid)
#   CLEANUP_SCRIPT      Script to run after deployment (default: ./run_swarm_cleanup.sh)
#   CLEANUP_STACK_FILE  Stack file used by the cleanup script (default: ../docker/cleanup-stack.yml)
#   CLEANUP_STACK_NAME  Stack name used by the cleanup script (default: swarm-cleanup)
#   DIGEST_DIR        Directory to store image digest logs (default: ../digests)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$STACK_NAME|$IMAGE_TAG] $1"; }
require() { command -v "$1" >/dev/null 2>&1 || { echo "command not found: $1" >&2; exit 1; }; }

update_one_shot_service() {
  local service_name="$1"
  local image_ref="$2"
  local previous_task_id task_id task_state exit_code task_error

  previous_task_id=$(docker service ps "$service_name" --no-trunc \
    --format '{{.ID}}' | head -n 1)

  # A migration task is expected to exit after completing. Running service
  # update in its default attached mode treats that successful exit as an
  # early termination and returns non-zero, pausing the whole deployment.
  if ! docker service update --detach=true --image "$image_ref" --force "$service_name"; then
    return 1
  fi

  for _ in $(seq 1 120); do
    task_id=$(docker service ps "$service_name" --no-trunc \
      --format '{{.ID}}' | head -n 1)

    if [[ -n "$task_id" && "$task_id" != "$previous_task_id" ]]; then
      task_state=$(docker inspect --format '{{.Status.State}}' "$task_id" 2>/dev/null || true)
      case "$task_state" in
        complete)
          exit_code=$(docker inspect \
            --format '{{if .Status.ContainerStatus}}{{.Status.ContainerStatus.ExitCode}}{{else}}1{{end}}' \
            "$task_id" 2>/dev/null || echo 1)
          if [[ "$exit_code" == "0" ]]; then
            return 0
          fi
          task_error=$(docker inspect --format '{{.Status.Err}}' "$task_id" 2>/dev/null || true)
          log "[❌] One-shot task exited with code $exit_code: $task_error"
          return 1
          ;;
        failed|rejected|orphaned)
          task_error=$(docker inspect --format '{{.Status.Err}}' "$task_id" 2>/dev/null || true)
          log "[❌] One-shot task entered state '$task_state': $task_error"
          return 1
          ;;
      esac
    fi

    sleep 2
  done

  log "[❌] Timed out waiting for one-shot service: $service_name"
  return 1
}

main() {
  IMAGE_TAG="${IMAGE_TAG:-latest}"
  IMAGE_REPO="${IMAGE_REPO:-}"
  STACK_NAME="${STACK_NAME:-}"
  STACK_FILE="${STACK_FILE:-}"
  SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
  LOG_FILE="${LOG_FILE:-$REPO_ROOT/log/deploy_${STACK_NAME}_uniq.log}"
  LOCK_FILE="${LOCK_FILE:-/tmp/deploy_${STACK_NAME}_uniq.pid}"
  CLEANUP_SCRIPT="${CLEANUP_SCRIPT:-$SCRIPT_DIR/run_swarm_cleanup.sh}"
  CLEANUP_STACK_FILE="${CLEANUP_STACK_FILE:-$REPO_ROOT/docker/cleanup-stack.yml}"
  CLEANUP_STACK_NAME="${CLEANUP_STACK_NAME:-swarm-cleanup}"
  DIGEST_DIR="${DIGEST_DIR:-$REPO_ROOT/digests}"

  mkdir -p "$(dirname "$LOG_FILE")"

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

    skip_deploy=false
    existing_services=($(docker stack services "$STACK_NAME" --format '{{.Name}}' 2>/dev/null || true))
    if [[ "$IMAGE_TAG" != "latest" && ${#existing_services[@]} -gt 0 ]]; then
      mismatched_services=()
      for service_name in "${existing_services[@]}"; do
        current_image=$(docker service inspect "$service_name" -f '{{index .Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true)
        current_tag=$(echo "$current_image" | sed -e 's/@.*//' | awk -F':' '{print $NF}')
        if [[ "$current_tag" != "$IMAGE_TAG" ]]; then
          mismatched_services+=("$service_name ($current_tag)")
        fi
      done

      if [[ ${#mismatched_services[@]} -eq 0 ]]; then
        log "♻️ All services already running image tag $IMAGE_TAG. Skipping deploy/update."
        skip_deploy=true
      else
        log "🔎 Services needing deploy (expected $IMAGE_TAG): ${mismatched_services[*]}"
      fi
    fi

    if ! $skip_deploy; then
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

      deploy_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$image_ref" 2>/dev/null | awk -F'@' '{print $2}')
      if [[ -n "$deploy_digest" ]]; then
        mkdir -p "$DIGEST_DIR"
        digest_log="$DIGEST_DIR/${STACK_NAME}_image_digests.log"
        echo "$deploy_digest" >> "$digest_log"
        tail -n 5 "$digest_log" > "$digest_log.tmp" && mv "$digest_log.tmp" "$digest_log"
        log "📝 Recorded digest: $deploy_digest"
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
          restart_condition=$(docker service inspect "$service_name" \
            --format '{{if .Spec.TaskTemplate.RestartPolicy}}{{.Spec.TaskTemplate.RestartPolicy.Condition}}{{end}}')
          if [[ "$restart_condition" == "none" ]]; then
            if update_one_shot_service "$service_name" "$image_ref"; then
              update_result=0
            else
              update_result=$?
            fi
          elif docker service update --image "$image_ref" --force "$service_name"; then
            update_result=0
          else
            update_result=$?
          fi

          if [[ "$update_result" -eq 0 ]]; then
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
    else
      log "🏁 No deployment needed."
    fi

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
  deploy_pid=$!

  # CI and interactive recovery runs can wait for the real deployment result
  # instead of returning successfully while the background job later fails.
  if [[ "${DEPLOY_FOREGROUND:-false}" == "true" ]]; then
    wait "$deploy_pid"
  fi
}

main "$@"
