#!/usr/bin/env bash
set -euo pipefail

# run_swarm_cleanup.sh - deploy a temporary stack to clean unused images on all nodes.
#
# Environment variables:
#   IMAGE_REPO  - Repository to clean (required)
#   STACK_FILE  - Path to the cleanup stack file (default: ../docker/cleanup-stack.yml)
#   STACK_NAME  - Name of the cleanup stack (default: swarm-cleanup)

log() { printf '%s\n' "$*"; }
require() { command -v "$1" >/dev/null 2>&1 || { log "command not found: $1"; exit 1; }; }

main() {
  require docker

  local script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  local stack_file="${STACK_FILE:-$script_dir/../docker/cleanup-stack.yml}"
  local stack_name="${STACK_NAME:-swarm-cleanup}"
  local image_repo="${IMAGE_REPO:-}"

  if [[ -z "$image_repo" ]]; then
    log "IMAGE_REPO must be set"
    exit 1
  fi

  if [[ ! -f "$stack_file" ]]; then
    log "Stack file not found: $stack_file"
    exit 1
  fi

  log "🚀 Deploy cleanup stack..."
  RUN_TIMESTAMP=$(date +%s) IMAGE_REPO="$image_repo" docker stack deploy -c "$stack_file" "$stack_name"

  log "⏳ Waiting for cleanup tasks..."
  while true; do
    task_state=$(docker service ps "${stack_name}_swarm_cleanup" --no-trunc --format "{{.CurrentState}}" 2>/dev/null | head -n1)
    log "State: $task_state"

    if [[ "$task_state" == *"Complete"* ]] || [[ "$task_state" == *"Shutdown"* ]]; then
      log "✅ Cleanup finished"
      break
    fi

    if [[ "$task_state" == *"Failed"* ]]; then
      log "❌ Cleanup failed"
      break
    fi

    sleep 3
  done

  log "🧹 Removing stack..."
  docker stack rm "$stack_name"
}

main "$@"
