#!/usr/bin/env bash

# Shared blocking lock for every Swarm deployment on this manager.
# The fixed descriptor is inherited by child scripts, allowing a wrapper to
# protect checkout refreshes without deadlocking the deploy implementation.

GLOBAL_DEPLOY_LOCK_FD=200

acquire_global_deploy_lock() {
  local context="${1:-deployment}"
  local lock_file="${GLOBAL_DEPLOY_LOCK_FILE:-/tmp/swarm-stackhouse-deploy.lock}"
  local lock_timeout="${GLOBAL_DEPLOY_LOCK_TIMEOUT:-7200}"

  if [[ "${GLOBAL_DEPLOY_LOCK_HELD:-false}" == "true" && \
        -e "/proc/$$/fd/$GLOBAL_DEPLOY_LOCK_FD" ]]; then
    return 0
  fi

  command -v flock >/dev/null 2>&1 || {
    echo "command not found: flock" >&2
    return 1
  }

  if [[ ! "$lock_timeout" =~ ^[1-9][0-9]*$ ]]; then
    echo "GLOBAL_DEPLOY_LOCK_TIMEOUT must be a positive integer" >&2
    return 1
  fi

  exec 200>"$lock_file"
  printf '[%s] Waiting up to %ss for global deploy lock: %s (%s)\n' \
    "$(date '+%F %T')" "$lock_timeout" "$lock_file" "$context"

  if ! flock -w "$lock_timeout" "$GLOBAL_DEPLOY_LOCK_FD"; then
    echo "Timed out waiting for global deploy lock: $lock_file ($context)" >&2
    return 1
  fi

  export GLOBAL_DEPLOY_LOCK_HELD=true
  printf '[%s] Acquired global deploy lock: %s (%s)\n' \
    "$(date '+%F %T')" "$lock_file" "$context"
}
