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
#   CLEANUP_LOCK_FILE    - Shared cleanup lock (default: /tmp/swarm-stackhouse-cleanup.lock)
#   CLEANUP_LOCK_TIMEOUT - Seconds to wait for the cleanup lock (default: 900)

log() { printf '%s\n' "$*"; }
require() { command -v "$1" >/dev/null 2>&1 || { log "command not found: $1"; exit 1; }; }

# Globals used by cleanup trap; populated in main
stack_name=""
service_name=""
default_network_name=""
poll_interval=3
deployed=0

main() {
  require docker

  local script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  local stack_file="${STACK_FILE:-$script_dir/../docker/cleanup-stack.yml}"
  stack_name="${STACK_NAME:-swarm-cleanup}"
  local image_repo="${IMAGE_REPO:-}"
  local wait_timeout=${WAIT_TIMEOUT:-300}
  poll_interval=${POLL_INTERVAL:-3}
  local cleanup_lock_file="${CLEANUP_LOCK_FILE:-/tmp/swarm-stackhouse-cleanup.lock}"
  local cleanup_lock_timeout="${CLEANUP_LOCK_TIMEOUT:-900}"
  service_name="${stack_name}_swarm_cleanup"
  default_network_name="${stack_name}_default"
  deployed=0

  if ! [[ "$wait_timeout" =~ ^[0-9]+$ && "$poll_interval" =~ ^[0-9]+$ && \
          "$cleanup_lock_timeout" =~ ^[1-9][0-9]*$ ]]; then
    log "WAIT_TIMEOUT and POLL_INTERVAL must be integers; CLEANUP_LOCK_TIMEOUT must be a positive integer"
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

  require flock
  exec 201>"$cleanup_lock_file"
  log "🔒 Waiting up to ${cleanup_lock_timeout}s for cleanup lock: $cleanup_lock_file"
  if ! flock -w "$cleanup_lock_timeout" 201; then
    log "❌ Timed out waiting for cleanup lock: $cleanup_lock_file"
    exit 1
  fi
  log "🔒 Acquired cleanup lock"

  cleanup_stack() {
    if [[ "${deployed:-0}" -eq 1 ]]; then
      log "🧹 Removing stack..."
      if ! docker stack rm "$stack_name"; then
        log "[⚠️] Failed to remove stack: $stack_name"
        return
      fi

      # docker stack rm is asynchronous. Keep the cleanup lock until its
      # service and default network are gone so the next cleanup cannot race
      # an object that is still being removed.
      local removal_started
      removal_started="$(date +%s)"
      while docker service inspect "$service_name" >/dev/null 2>&1 || \
            docker network inspect "$default_network_name" >/dev/null 2>&1; do
        if (( $(date +%s) - removal_started >= 120 )); then
          log "[⚠️] Cleanup stack resources still exist after 120s: $stack_name"
          return
        fi
        sleep "$poll_interval"
      done
      log "✅ Cleanup stack removed"
    fi
  }
  trap cleanup_stack EXIT

  log "🚀 Deploy cleanup stack..."
  RUN_TIMESTAMP=$(date +%s) IMAGE_REPO="$image_repo" docker stack deploy -c "$stack_file" "$stack_name"
  deployed=1

  log "⏳ Waiting for cleanup tasks..."
  local start_ts="$(date +%s)"
  while true; do
    mapfile -t task_states < <(
      docker service ps "$service_name" --no-trunc \
        --format '{{.Name}}|{{.CurrentState}}|{{.Error}}' 2>/dev/null |
        awk -F'|' '$1 !~ /^[[:space:]]*\\_/'
    )
    log "States: ${task_states[*]:-<pending>}"

    if [[ ${#task_states[@]} -eq 0 ]]; then
      if (( $(date +%s) - start_ts >= wait_timeout )); then
        log "❌ Cleanup service did not start within ${wait_timeout}s"
        exit 1
      fi
      sleep "$poll_interval"
      continue
    fi

    all_complete=1
    for task_state in "${task_states[@]}"; do
      if [[ "$task_state" == *"Failed"* ]] || [[ "$task_state" == *"Rejected"* ]]; then
        log "❌ Cleanup failed: $task_state"
        docker service ps "$service_name" --no-trunc || true
        exit 1
      fi
      [[ "$task_state" == *"Complete"* ]] || all_complete=0
    done

    if [[ "$all_complete" -eq 1 ]]; then
      log "✅ Cleanup finished"
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
