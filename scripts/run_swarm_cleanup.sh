#!/usr/bin/env bash
set -euo pipefail

# run_swarm_cleanup.sh - deploy a temporary stack to clean unused images on all nodes.
#
# Environment variables:
#   IMAGE_REPO     - Repository to clean (required)
#   STACK_FILE     - Path to the cleanup stack file (default: ../docker/cleanup-stack.yml)
#   STACK_NAME     - Name of the cleanup stack (default: swarm-cleanup)
#   WAIT_TIMEOUT   - Seconds to wait for cleanup task completion (default: 300)
#   POLL_INTERVAL  - Seconds between task state checks (default: 3)

log() { printf '%s\n' "$*"; }
require() { command -v "$1" >/dev/null 2>&1 || { log "command not found: $1"; exit 1; }; }

# Globals used by cleanup trap; populated in main
stack_name=""
deployed=0

main() {
  require docker

  local script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  local stack_file="${STACK_FILE:-$script_dir/../docker/cleanup-stack.yml}"
  stack_name="${STACK_NAME:-swarm-cleanup}"
  local image_repo="${IMAGE_REPO:-}"
  local wait_timeout=${WAIT_TIMEOUT:-300}
  local poll_interval=${POLL_INTERVAL:-3}
  local service_name="${stack_name}_swarm_cleanup"
  deployed=0

  if ! [[ "$wait_timeout" =~ ^[0-9]+$ && "$poll_interval" =~ ^[0-9]+$ ]]; then
    log "WAIT_TIMEOUT and POLL_INTERVAL must be integers"
    exit 1
  fi

  if [[ -z "$image_repo" ]]; then
    log "IMAGE_REPO must be set"
    exit 1
  fi

  if [[ ! -f "$stack_file" ]]; then
    log "Stack file not found: $stack_file"
    exit 1
  fi

  cleanup_stack() {
    if [[ "${deployed:-0}" -eq 1 ]]; then
      log "🧹 Removing stack..."
      docker stack rm "$stack_name" || log "[⚠️] Failed to remove stack: $stack_name"
    fi
  }
  trap cleanup_stack EXIT

  log "🚀 Deploy cleanup stack..."
  RUN_TIMESTAMP=$(date +%s) IMAGE_REPO="$image_repo" docker stack deploy -c "$stack_file" "$stack_name"
  deployed=1

  log "⏳ Waiting for cleanup tasks..."
  local start_ts="$(date +%s)"
  while true; do
    task_state=$(docker service ps "$service_name" --no-trunc --format "{{.CurrentState}}" 2>/dev/null | head -n1)
    log "State: ${task_state:-<pending>}"

    if [[ -z "$task_state" ]]; then
      if (( $(date +%s) - start_ts >= wait_timeout )); then
        log "❌ Cleanup service did not start within ${wait_timeout}s"
        exit 1
      fi
      sleep "$poll_interval"
      continue
    fi

    if [[ "$task_state" == *"Complete"* ]] || [[ "$task_state" == *"Shutdown"* ]]; then
      log "✅ Cleanup finished"
      break
    fi

    if [[ "$task_state" == *"Failed"* ]]; then
      log "❌ Cleanup failed"
      break
    fi

    if (( $(date +%s) - start_ts >= wait_timeout )); then
      log "❌ Cleanup did not finish within ${wait_timeout}s"
      exit 1
    fi

    sleep "$poll_interval"
  done
}

main "$@"
