#!/usr/bin/env bash
# stackhouse_deploy_and_clean.sh
#
# Purpose:
#   - Ensure the public repo "swarm-stackhouse" exists locally (HTTPS clone).
#   - If the remote branch has a newer commit, re-clone a fresh copy (atomic replace).
#   - Run the repo's ./scripts/deploy_and_cleanup.sh with the provided ENV configuration.
#
# Usage:
#   ./stackhouse_deploy_and_clean.sh [TARGET_DIR] [BRANCH]
#
#   TARGET_DIR (optional) : destination directory (default: /tmp/swarm-stackhouse)
#   BRANCH     (optional) : git branch to track (default: main)
#
# Environment variables (with sane defaults):
#   IMAGE_TAG   : image tag to deploy (default: latest)
#   IMAGE_REPO  : image repo (default: myorg/myapp)
#   STACK_NAME  : stack name (default: app_stack)
#   STACK_FILE  : stack file path (default: /root/docker/app-stack.yml)
#   GLOBAL_DEPLOY_LOCK_FILE    : shared deploy lock on this manager
#   GLOBAL_DEPLOY_LOCK_TIMEOUT : seconds to wait for the lock (default: 7200)
#   DEPLOY_QUEUE_BACKGROUND    : enqueue on the manager and return (default: true)
#   DEPLOY_QUEUE_LOG_FILE      : shared queue status log
#
# Notes:
#   - Designed to be idempotent and safe to re-run.
#   - Uses only public HTTPS clone (no SSH or tokens required for public repos).
#   - Keep logic small, testable, and easy to extend.

set -euo pipefail

# -------- Config (defaults) --------
REPO_URL="https://github.com/tanngoc93/swarm-stackhouse.git"
TARGET_DIR="${1:-/tmp/swarm-stackhouse}"
BRANCH="${2:-main}"

# Deployment ENV (can be overridden by caller)
IMAGE_TAG="${IMAGE_TAG:-latest}"
# The following defaults may be overridden by setup.sh when generating
# a customized deployment script.
IMAGE_REPO="${IMAGE_REPO:-myorg/myapp}"
STACK_NAME="${STACK_NAME:-app_stack}"
STACK_FILE="${STACK_FILE:-/root/docker/app-stack.yml}"
GLOBAL_DEPLOY_LOCK_FILE="${GLOBAL_DEPLOY_LOCK_FILE:-/tmp/swarm-stackhouse-deploy.lock}"
GLOBAL_DEPLOY_LOCK_TIMEOUT="${GLOBAL_DEPLOY_LOCK_TIMEOUT:-7200}"
GLOBAL_DEPLOY_LOCK_FD=200
DEPLOY_QUEUE_BACKGROUND="${DEPLOY_QUEUE_BACKGROUND:-true}"
DEPLOY_QUEUE_LOG_FILE="${DEPLOY_QUEUE_LOG_FILE:-/tmp/swarm-stackhouse-deploy-queue.log}"
DEPLOY_QUEUE_WORKER="${DEPLOY_QUEUE_WORKER:-false}"
DEPLOY_REQUEST_ID="${DEPLOY_REQUEST_ID:-}"

# -------- Utilities --------
log() { printf "[%s] %s\n" "$(date '+%F %T')" "$*"; }

abort() {
  log "❌ $*"
  exit 1
}

require() {
  # Ensure a required command exists
  command -v "$1" >/dev/null 2>&1 || abort "'$1' is not installed"
}

acquire_global_deploy_lock() {
  require flock

  if [[ "${GLOBAL_DEPLOY_LOCK_HELD:-false}" == "true" && \
        "/proc/$BASHPID/fd/$GLOBAL_DEPLOY_LOCK_FD" -ef "$GLOBAL_DEPLOY_LOCK_FILE" ]] &&
     flock -n "$GLOBAL_DEPLOY_LOCK_FD"; then
    return 0
  fi

  [[ "$GLOBAL_DEPLOY_LOCK_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || \
    abort "GLOBAL_DEPLOY_LOCK_TIMEOUT must be a positive integer"

  unset GLOBAL_DEPLOY_LOCK_HELD
  exec 200>>"$GLOBAL_DEPLOY_LOCK_FILE"
  log "🔒 Waiting up to ${GLOBAL_DEPLOY_LOCK_TIMEOUT}s for global deploy lock: $GLOBAL_DEPLOY_LOCK_FILE"
  flock -w "$GLOBAL_DEPLOY_LOCK_TIMEOUT" "$GLOBAL_DEPLOY_LOCK_FD" || \
    abort "Timed out waiting for global deploy lock: $GLOBAL_DEPLOY_LOCK_FILE"

  export GLOBAL_DEPLOY_LOCK_HELD=true
  log "🔒 Acquired global deploy lock for stack: $STACK_NAME"
}

queue_log() {
  printf '[%s] [request=%s] [stack=%s|tag=%s] %s\n' \
    "$(date '+%F %T')" "$DEPLOY_REQUEST_ID" "$STACK_NAME" "$IMAGE_TAG" "$*"
}

resolve_script_path() {
  local script_dir script_name
  script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  script_name="$(basename "${BASH_SOURCE[0]}")"
  printf '%s/%s\n' "$script_dir" "$script_name"
}

enqueue_deployment() {
  local script_path queue_dir worker_pid

  case "$DEPLOY_QUEUE_BACKGROUND" in
    true|false) ;;
    *) abort "DEPLOY_QUEUE_BACKGROUND must be true or false" ;;
  esac

  DEPLOY_REQUEST_ID="${DEPLOY_REQUEST_ID:-$(date '+%Y%m%dT%H%M%S')-$$}"
  script_path="$(resolve_script_path)"
  queue_dir="$(dirname "$DEPLOY_QUEUE_LOG_FILE")"
  mkdir -p "$queue_dir"

  nohup env \
    DEPLOY_QUEUE_WORKER=true \
    DEPLOY_REQUEST_ID="$DEPLOY_REQUEST_ID" \
    DEPLOY_QUEUE_LOG_FILE="$DEPLOY_QUEUE_LOG_FILE" \
    "$script_path" "$@" \
    </dev/null >>"$DEPLOY_QUEUE_LOG_FILE" 2>&1 &
  worker_pid=$!

  queue_log "QUEUED worker_pid=$worker_pid" >> "$DEPLOY_QUEUE_LOG_FILE"
  log "✅ Deployment queued on the Swarm manager (request: $DEPLOY_REQUEST_ID, worker PID: $worker_pid)."
  log "📝 Queue log: $DEPLOY_QUEUE_LOG_FILE"
}

worker_exit_log() {
  local status=$?
  if [[ "$status" -eq 0 ]]; then
    queue_log "COMPLETED"
  else
    queue_log "FAILED exit_code=$status"
  fi
}

get_remote_head() {
  # Return the commit hash of the remote branch (empty on failure)
  git ls-remote --heads "$REPO_URL" "$BRANCH" 2>/dev/null | awk '{print $1}'
}

get_local_head() {
  # Return local HEAD hash (empty if not a valid repo)
  [[ -d "$TARGET_DIR/.git" ]] || { echo ""; return; }
  git -C "$TARGET_DIR" rev-parse HEAD 2>/dev/null || echo ""
}

ensure_executable_if_exists() {
  # Make a file executable if it exists (no error if missing)
  local path="$1"
  if [[ -f "$path" ]]; then
    chmod +x "$path" || true
    log "🔧 Ensured executable: $path"
  fi
}

refresh_repo() {
  if [[ -d "$TARGET_DIR/.git" ]]; then
    log "🔄 Existing git repo found, fetching latest changes..."
    (
      cd "$TARGET_DIR"
      git fetch origin "$BRANCH" --depth=1
      git reset --hard "origin/$BRANCH"
    )
    # Ensure scripts are executable
    ensure_executable_if_exists "$TARGET_DIR/scripts/run_swarm_cleanup.sh"
    ensure_executable_if_exists "$TARGET_DIR/scripts/deploy_and_cleanup.sh"
    ensure_executable_if_exists "$TARGET_DIR/scripts/manual_rollback.sh"

    # Ensure digests directory always exists
    mkdir -p "$TARGET_DIR/digests"
    log "📂 Ensured digests directory exists."
    log "🏁 Repo refreshed at: $TARGET_DIR"
  else
    log "⚠️ $TARGET_DIR is missing or not a git repo. Cloning fresh..."
    local tmpdir
    tmpdir="$(mktemp -d)"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$tmpdir/repo"

    # Ensure scripts are executable
    ensure_executable_if_exists "$tmpdir/repo/scripts/run_swarm_cleanup.sh"
    ensure_executable_if_exists "$tmpdir/repo/scripts/deploy_and_cleanup.sh"
    ensure_executable_if_exists "$tmpdir/repo/scripts/manual_rollback.sh"

    # Preserve digests if exists
    if [[ -d "$TARGET_DIR/digests" ]]; then
      cp -r "$TARGET_DIR/digests" "$tmpdir/repo/" 2>/dev/null || true
      log "🗃️ Preserved existing digests directory."
    fi

    # Replace old repo
    mkdir -p "$(dirname "$TARGET_DIR")"
    [[ -e "$TARGET_DIR" ]] && rm -rf "$TARGET_DIR"
    mv "$tmpdir/repo" "$TARGET_DIR"
    rmdir "$tmpdir" 2>/dev/null || true

    # Ensure digests directory always exists
    mkdir -p "$TARGET_DIR/digests"
    log "📂 Ensured digests directory exists."
    log "🏁 Repo cloned fresh at: $TARGET_DIR"
  fi
}

run_deploy() {
  # Execute scripts/deploy_and_cleanup.sh with the configured ENV
  local deploy_script="$TARGET_DIR/scripts/deploy_and_cleanup.sh"
  [[ -x "$deploy_script" ]] || abort "$deploy_script not found or not executable"

  log "🚀 Running scripts/deploy_and_cleanup.sh with ENV:"
  log "    IMAGE_TAG  = $IMAGE_TAG"
  log "    IMAGE_REPO = $IMAGE_REPO"
  log "    STACK_NAME = $STACK_NAME"
  log "    STACK_FILE = $STACK_FILE"

  IMAGE_TAG="$IMAGE_TAG" \
  IMAGE_REPO="$IMAGE_REPO" \
  STACK_NAME="$STACK_NAME" \
  STACK_FILE="$STACK_FILE" \
  DEPLOY_BACKGROUND=false \
  "$deploy_script"
}

# -------- Main flow --------
main() {
  require git
  require flock
  queue_log "WAITING for global deploy lock"
  acquire_global_deploy_lock
  queue_log "STARTED"

  # 1) Resolve remote HEAD
  local remote_head
  remote_head="$(get_remote_head)"
  [[ -n "$remote_head" ]] || abort "Unable to resolve remote head for $REPO_URL (branch: $BRANCH)"

  # 2) Clone or refresh if outdated
  if [[ ! -d "$TARGET_DIR/.git" ]]; then
    log "ℹ️  Local repo not found at $TARGET_DIR. Cloning fresh..."
    refresh_repo
  else
    local local_head
    local_head="$(get_local_head)"
    if [[ -z "$local_head" ]]; then
      log "⚠️  $TARGET_DIR exists but is not a valid git repo. Cloning fresh..."
      refresh_repo
    elif [[ "$local_head" != "$remote_head" ]]; then
      log "🆕 Remote is newer:"
      log "    local : $local_head"
      log "    remote: $remote_head"
      log "➡️  Re-cloning a fresh copy..."
      refresh_repo
    else
      log "✅ Repo is up to date."
      # Still ensure scripts are executable (idempotent)
      ensure_executable_if_exists "$TARGET_DIR/scripts/run_swarm_cleanup.sh"
      ensure_executable_if_exists "$TARGET_DIR/scripts/deploy_and_cleanup.sh"
      ensure_executable_if_exists "$TARGET_DIR/scripts/manual_rollback.sh"
      # Ensure digests directory always exists when repo is up-to-date
      mkdir -p "$TARGET_DIR/digests"
      log "📂 Ensured digests directory exists."
    fi
  fi

  # 3) Run deployment
  run_deploy
}

case "$DEPLOY_QUEUE_BACKGROUND" in
  true|false) ;;
  *) abort "DEPLOY_QUEUE_BACKGROUND must be true or false" ;;
esac
case "$DEPLOY_QUEUE_WORKER" in
  true|false) ;;
  *) abort "DEPLOY_QUEUE_WORKER must be true or false" ;;
esac
DEPLOY_REQUEST_ID="${DEPLOY_REQUEST_ID:-$(date '+%Y%m%dT%H%M%S')-$$}"

if [[ "$DEPLOY_QUEUE_BACKGROUND" == "true" && "$DEPLOY_QUEUE_WORKER" != "true" ]]; then
  require nohup
  enqueue_deployment "$@"
else
  if [[ "$DEPLOY_QUEUE_WORKER" == "true" ]]; then
    trap worker_exit_log EXIT
  fi
  main "$@"
fi
