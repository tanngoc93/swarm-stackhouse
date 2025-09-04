#!/usr/bin/env bash
set -euo pipefail

# cleanup_docker_images.sh - remove unused Docker images for a given repository
#
# Usage:
#   IMAGE_REPO=myorg/myimage ./scripts/cleanup_docker_images.sh
#
# Environment variables:
#   IMAGE_REPO      Target repository (required)
#   DRY_RUN=1       Preview deletions without removing anything
#   RM_TIMEOUT=20s  Timeout for docker rmi/untag commands

# === CONFIG (overridable) ===
IMAGE_REPO="${IMAGE_REPO:-}"
DRY_RUN="${DRY_RUN:-0}"
RM_TIMEOUT="${RM_TIMEOUT:-20s}"

if [[ -z "$IMAGE_REPO" ]]; then
  echo "Error: IMAGE_REPO is required. Set IMAGE_REPO environment variable." >&2
  exit 1
fi

# === State & logging ===
DELETED_IMAGE_COUNT=0
log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

print_cleanup_summary() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_message "✅ DRY RUN complete. Images that would have been deleted: ${DELETED_IMAGE_COUNT}"
  else
    log_message "✅ Cleanup complete. Total images deleted: ${DELETED_IMAGE_COUNT}"
  fi
}
trap print_cleanup_summary EXIT

# Run a command with timeout if available; otherwise run directly
execute_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$RM_TIMEOUT" "$@"
  else
    "$@"
  fi
}

# Return first tag for an image ID (for nicer logs)
get_primary_tag() {
  docker inspect --format='{{index .RepoTags 0}}' "$1" 2>/dev/null || echo "<untagged>"
}

# Helper: check if a local image ID is referenced by any Swarm service (by digest)
image_used_by_service() {
  local img_id="$1"
  mapfile -t DIGESTS < <(
    docker inspect --format='{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' "$img_id" 2>/dev/null |
      awk -F'@' 'NF==2{print $2}'
  )
  for d in "${DIGESTS[@]:-}"; do
    for u in "${USED_SERVICE_DIGESTS[@]:-}"; do
      [[ "$d" == "$u" ]] && return 0
    done
  done
  return 1
}

# Helper: delete all tags of this image that belong to the repo, then delete by ID
remove_image_and_tags() {
  local img_id="$1"
  local removed_any=0
  local deleted_by_id=0

  mapfile -t REPO_REFS < <(
    docker inspect --format='{{range .RepoTags}}{{.}}{{"\n"}}{{end}}{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' "$img_id" 2>/dev/null |
      grep -E "^${IMAGE_REPO}(:|@)" || true
  )

  for ref in "${REPO_REFS[@]}"; do
    [[ -z "$ref" || "$ref" == "$IMAGE_REPO:<none>" ]] && continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log_message "🧪 [DRY RUN] Would untag: $ref"
      removed_any=1
    else
      if OUT=$(execute_with_timeout docker rmi "$ref" 2>&1); then
        log_message "🏷️  Untagged: $ref"
        removed_any=1
      else
        log_message "[⚠️] Failed to untag $ref — $OUT"
      fi
    fi
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_message "🧪 [DRY RUN] Would delete by ID: $img_id"
  else
    if OUT=$(execute_with_timeout docker rmi -f "$img_id" 2>&1); then
      log_message "🗑  Deleted image by ID: $img_id"
      deleted_by_id=1
    else
      log_message "[ℹ️] Could not delete by ID (may still be referenced elsewhere): $img_id — $OUT"
    fi
  fi

  if [[ "$removed_any" -eq 1 || "$deleted_by_id" -eq 1 ]]; then
    return 0
  else
    return 1
  fi
}

main() {
  log_message "🧹 Starting image cleanup for repo: $IMAGE_REPO"

  if ! docker info >/dev/null 2>&1; then
    log_message "[❌] Docker daemon not reachable."
    exit 1
  fi

  if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -qi '^active$'; then
    SWARM_ACTIVE=1
    SWARM_MANAGER=$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [[ "$SWARM_MANAGER" == "true" ]]; then
      log_message "ℹ️ Swarm mode: active (manager)"
    else
      log_message "ℹ️ Swarm mode: active (worker)"
    fi
  else
    SWARM_ACTIVE=0
    SWARM_MANAGER="false"
    log_message "ℹ️ Swarm mode: inactive (service digest check will be empty)"
  fi

  log_message "🧯 Removing exited containers (if any)..."
  docker ps -aq -f status=exited | xargs -r docker rm >/dev/null 2>&1 || true

  log_message "🧯 Removing non-running containers for repo: $IMAGE_REPO"
  mapfile -t STALE_CONTAINERS < <(
    docker ps -a \
      --filter "ancestor=$IMAGE_REPO" \
      --filter "status=created" \
      --filter "status=exited" \
      --filter "status=dead" \
      --filter "status=paused" \
      --format '{{.ID}}'
  )
  if ((${#STALE_CONTAINERS[@]})); then
    printf '%s\n' "${STALE_CONTAINERS[@]}" | xargs -r docker rm -f >/dev/null 2>&1 || true
    log_message "🧯 Removed ${#STALE_CONTAINERS[@]} non-running container(s) for $IMAGE_REPO"
  else
    log_message "ℹ️ No non-running containers for $IMAGE_REPO"
  fi

  log_message "🧽 Removing dangling images (if any)..."
  docker images -f dangling=true -q | xargs -r docker rmi -f >/dev/null 2>&1 || true

  USED_SERVICE_DIGESTS=()
  if [[ "$SWARM_ACTIVE" -eq 1 && "$SWARM_MANAGER" == "true" ]]; then
    mapfile -t USED_SERVICE_DIGESTS < <(
      docker service ls --format '{{.ID}}' 2>/dev/null |
      xargs -r -n1 docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null |
      awk -F'@' 'NF==2{print $2}' |
      sort -u
    )
    log_message "🔎 Found ${#USED_SERVICE_DIGESTS[@]} service image digest(s) in use."
  else
    log_message "🔎 Skipping service digest collection (not a manager)."
  fi

  log_message "🧾 Scanning local images for repo: $IMAGE_REPO"
  mapfile -t IMAGE_ID_LIST < <(docker images "$IMAGE_REPO" --format '{{.ID}}' | sort -u)
  log_message "🧾 Found ${#IMAGE_ID_LIST[@]} image ID(s) for repo: $IMAGE_REPO"

  set +e
  for IMG_ID in "${IMAGE_ID_LIST[@]:-}"; do
    PRIMARY_TAG="$(get_primary_tag "$IMG_ID")"
    RUNNING_CONTAINER_ID=$(docker ps --filter "ancestor=$IMG_ID" --format '{{.ID}}' | head -n1) || RUNNING_CONTAINER_ID=""
    if [[ -n "$RUNNING_CONTAINER_ID" ]]; then
      log_message "🔒 In use by RUNNING container: $PRIMARY_TAG ($IMG_ID)"
      continue
    fi

    if [[ "$SWARM_ACTIVE" -eq 1 && "$SWARM_MANAGER" == "true" ]]; then
      if image_used_by_service "$IMG_ID"; then
        log_message "🔒 In use by Swarm service digest: $PRIMARY_TAG ($IMG_ID)"
        continue
      fi
    fi

    log_message "➡️  Cleaning image: $PRIMARY_TAG ($IMG_ID)"
    if remove_image_and_tags "$IMG_ID"; then
      ((DELETED_IMAGE_COUNT++))
    else
      log_message "[⚠️] Skipped/failed: $PRIMARY_TAG ($IMG_ID)"
    fi
  done
  set -e
}

main "$@"
