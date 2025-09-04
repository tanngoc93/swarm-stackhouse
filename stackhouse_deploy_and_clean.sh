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
  # Clone into a temp dir, then atomically replace TARGET_DIR
  local tmpdir
  tmpdir="$(mktemp -d)"
  log "⬇️  Cloning $REPO_URL (branch: $BRANCH) into a temporary directory..."
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$tmpdir/repo"
  log "✅ Clone completed."

  # Make commonly used scripts executable (idempotent)
  ensure_executable_if_exists "$tmpdir/repo/scripts/run_swarm_cleanup.sh"
  ensure_executable_if_exists "$tmpdir/repo/scripts/deploy_and_cleanup.sh"
  ensure_executable_if_exists "$tmpdir/repo/scripts/manual_rollback.sh"

  # Preserve existing digest logs (if any)
  if [[ -d "$TARGET_DIR/digests" ]]; then
    cp -r "$TARGET_DIR/digests" "$tmpdir/repo/" 2>/dev/null || true
    log "🗃️  Preserved existing digests directory."
  fi

  # Atomic replace of the target directory
  mkdir -p "$(dirname "$TARGET_DIR")"
  if [[ -e "$TARGET_DIR" ]]; then
    log "♻️ Replacing existing directory: $TARGET_DIR"
    rm -rf "$TARGET_DIR"
  fi
  mv "$tmpdir/repo" "$TARGET_DIR"
  rmdir "$tmpdir" 2>/dev/null || true

  # Ensure digests directory always exists (new or preserved)
  mkdir -p "$TARGET_DIR/digests"
  log "📂 Ensured digests directory exists."

  log "🏁 Repo ready at: $TARGET_DIR"
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
  "$deploy_script"
}

# -------- Main flow --------
main() {
  require git

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

main "$@"
