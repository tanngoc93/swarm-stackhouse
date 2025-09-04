#!/usr/bin/env bash
set -euo pipefail

# manual_rollback.sh - Roll back services in a Docker Swarm stack to a previously deployed image digest.
#
# Usage:
#   STACK_NAME=my_stack IMAGE_REPO=myorg/myimage ./scripts/manual_rollback.sh
#   STACK_NAME=my_stack IMAGE_REPO=myorg/myimage TARGET_DIGEST=sha256:deadbeef ./scripts/manual_rollback.sh
#
# Environment variables:
#   STACK_NAME     Name of the stack (required)
#   IMAGE_REPO     Repository for the image (required)
#   DIGEST_FILE    File storing digests (default: scripts/${STACK_NAME}_image_digests.log)
#   TARGET_DIGEST  Digest to roll back to (optional; prompts if unset)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$STACK_NAME|$LOG_TAG] $1"; }
require() { command -v "$1" >/dev/null 2>&1 || { echo "command not found: $1" >&2; exit 1; }; }

main() {
  STACK_NAME="${STACK_NAME:-}"
  IMAGE_REPO="${IMAGE_REPO:-}"
  TARGET_DIGEST="${TARGET_DIGEST:-}"
  SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  DIGEST_FILE="${DIGEST_FILE:-$SCRIPT_DIR/${STACK_NAME}_image_digests.log}"
  LOG_TAG="rollback"

  if [[ -z "$STACK_NAME" || -z "$IMAGE_REPO" ]]; then
    echo "STACK_NAME and IMAGE_REPO must be set" >&2
    exit 1
  fi

  require docker

  if [[ ! -f "$DIGEST_FILE" ]]; then
    echo "Digest log not found: $DIGEST_FILE" >&2
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
    read -p "Select digest number: " sel
    if [[ -z "$sel" || ! "$sel" =~ ^[0-9]+$ ]]; then
      echo "Invalid selection" >&2
      exit 1
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
  for svc in "${SERVICES[@]}"; do
    log "Updating service: $svc"
    if docker service update --image "$image_ref" --force "$svc" >/dev/null 2>&1; then
      log "✅ Updated: $svc"
    else
      log "[❌] Failed to update: $svc"
      exit 1
    fi
  done

  log "✅ Rollback complete"
}

main "$@"
