#!/bin/bash
set -euo pipefail

# docker_image_cleanup.sh - remove unused Docker images for a given repository
#
# Usage:
#   IMAGE_REPO=myorg/myimage ./scripts/docker_image_cleanup.sh
#
# Environment variables:
#   IMAGE_REPO      Target repository (required)
#   DRY_RUN=1       Preview deletions without removing anything
#   RM_TIMEOUT=20s  Timeout for docker rmi/untag commands

# === CONFIG (overridable) ===
# Repo to clean from environment (required)
IMAGE_REPO="${IMAGE_REPO:-}"
if [[ -z "$IMAGE_REPO" ]]; then
  echo "Error: IMAGE_REPO is required. Set IMAGE_REPO environment variable." >&2
  exit 1
fi
# Dry-run: set to 1 to preview deletions (no actual removals)
DRY_RUN="${DRY_RUN:-0}"
# Max time for each docker rmi/untag command
RM_TIMEOUT="${RM_TIMEOUT:-20s}"

# === State & logging ===
DELETED_COUNT=0
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# Always print a final summary even if something fails in the middle
print_summary() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "✅ DRY RUN complete. Images that would have been deleted: ${DELETED_COUNT}"
  else
    log "✅ Cleanup complete. Total images deleted: ${DELETED_COUNT}"
  fi
}
trap print_summary EXIT

# Run a command with timeout if available; otherwise run directly
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$RM_TIMEOUT" "$@"
  else
    "$@"
  fi
}

# Return first tag for an image ID (for nicer logs)
primary_tag() {
  docker inspect --format='{{index .RepoTags 0}}' "$1" 2>/dev/null || echo "<untagged>"
}

log "🧹 Starting image cleanup for repo: $IMAGE_REPO"

# Pre-flight: Docker must be reachable
if ! docker info >/dev/null 2>&1; then
  log "[❌] Docker daemon not reachable."
  exit 1
fi

# Swarm detection: distinguish manager vs worker
if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -qi '^active$'; then
  SWARM_ACTIVE=1
  SWARM_MANAGER=$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [[ "$SWARM_MANAGER" == "true" ]]; then
    log "ℹ️ Swarm mode: active (manager)"
  else
    log "ℹ️ Swarm mode: active (worker)"
  fi
else
  SWARM_ACTIVE=0
  SWARM_MANAGER="false"
  log "ℹ️ Swarm mode: inactive (service digest check will be empty)"
fi

# === STEP 1: Remove non-running containers ===
log "🧯 Removing exited containers (if any)..."
docker ps -aq -f status=exited | xargs -r docker rm >/dev/null 2>&1 || true

# Also proactively remove non-running containers for this repo (created/exited/paused/dead)
log "🧯 Removing non-running containers for repo: $IMAGE_REPO"
mapfile -t OLD_CTS < <(
  docker ps -a \
    --filter "ancestor=$IMAGE_REPO" \
    --filter "status=created" \
    --filter "status=exited" \
    --filter "status=dead" \
    --filter "status=paused" \
    --format '{{.ID}}'
)
if ((${#OLD_CTS[@]})); then
  printf '%s\n' "${OLD_CTS[@]}" | xargs -r docker rm -f >/dev/null 2>&1 || true
  log "🧯 Removed ${#OLD_CTS[@]} non-running container(s) for $IMAGE_REPO"
else
  log "ℹ️ No non-running containers for $IMAGE_REPO"
fi

# === STEP 2: Remove dangling images (untagged layers) ===
log "🧽 Removing dangling images (if any)..."
docker images -f dangling=true -q | xargs -r docker rmi -f >/dev/null 2>&1 || true

# === STEP 3: Collect service image digests (manager only) ===
USED_SERVICE_DIGESTS=()
if [[ "$SWARM_ACTIVE" -eq 1 && "$SWARM_MANAGER" == "true" ]]; then
  mapfile -t USED_SERVICE_DIGESTS < <(
    docker service ls --format '{{.ID}}' 2>/dev/null \
    | xargs -r -n1 docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null \
    | awk -F'@' 'NF==2{print $2}' \
    | sort -u
  )
  log "🔎 Found ${#USED_SERVICE_DIGESTS[@]} service image digest(s) in use."
else
  log "🔎 Skipping service digest collection (not a manager)."
fi

# Helper: check if a local image ID is referenced by any Swarm service (by digest)
is_used_by_service() {
  local img_id="$1"
  # Get all repo digests for this local image ID
  mapfile -t DIGESTS < <(
    docker inspect --format='{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' "$img_id" 2>/dev/null \
    | awk -F'@' 'NF==2{print $2}'
  )
  # If there is any intersection with USED_SERVICE_DIGESTS, consider it used
  for d in "${DIGESTS[@]:-}"; do
    for u in "${USED_SERVICE_DIGESTS[@]:-}"; do
      [[ "$d" == "$u" ]] && return 0
    done
  done
  return 1
}

# Helper: delete all tags of this image that belong to the repo, then delete by ID
delete_image_all_tags() {
  local img_id="$1"
  local removed_any=0
  local deleted_by_id=0

  # Get all repo:tag entries that point to this image ID, restricted to the target repo.
  # Using 'docker images' avoids empty lines/null RepoTags that may appear with 'docker inspect'.
  mapfile -t REPO_TAGS < <(
    docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
    | awk -v id="$img_id" -v repo="$IMAGE_REPO" '
        $2==id && index($1, repo ":")==1 { print $1 }
      '
  )

  # Untag each repo tag; skip any accidental empty values
  for t in "${REPO_TAGS[@]}"; do
    [[ -z "$t" ]] && continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "🧪 [DRY RUN] Would untag: $t"
      removed_any=1
    else
      if OUT=$(run_with_timeout docker rmi "$t" 2>&1); then
        log "🏷️  Untagged: $t"
        removed_any=1
      else
        log "[⚠️] Failed to untag $t — $OUT"
      fi
    fi
  done

  # Try deleting by ID (may still be referenced by other repos on this node)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "🧪 [DRY RUN] Would delete by ID: $img_id"
    return 0
  else
    if OUT=$(run_with_timeout docker rmi -f "$img_id" 2>&1); then
      log "🗑  Deleted image by ID: $img_id"
      deleted_by_id=1
    else
      log "[ℹ️] Could not delete by ID (may still be referenced elsewhere): $img_id — $OUT"
    fi
  fi

  # Consider cleaned if at least one untag happened or the ID was removed
  if [[ "$removed_any" -eq 1 || "$deleted_by_id" -eq 1 ]]; then
    return 0
  else
    return 1
  fi
}

# === STEP 4: Remove all unused images for this repo (keep only images in use) ===
log "🧾 Scanning local images for repo: $IMAGE_REPO"

# Unique list of image IDs for this repo
mapfile -t IMAGE_IDS < <(docker images "$IMAGE_REPO" --format '{{.ID}}' | sort -u)
log "🧾 Found ${#IMAGE_IDS[@]} image ID(s) for repo: $IMAGE_REPO"

# Turn off errexit during the cleanup loop to prevent premature exit on any single failure
set +e
for IMG_ID in "${IMAGE_IDS[@]:-}"; do
  # Get a friendly tag name for logs (do not fail the loop if inspect fails)
  TAGGED="$(primary_tag "$IMG_ID")"

  # Check if any running container uses this image (robust, no pipeline in condition)
  RUNNING_CNT=""
  RUNNING_CNT=$(docker ps --filter "ancestor=$IMG_ID" --format '{{.ID}}' | head -n1) || RUNNING_CNT=""
  if [[ -n "$RUNNING_CNT" ]]; then
    log "🔒 In use by RUNNING container: $TAGGED ($IMG_ID)"
    continue
  fi

  # If manager, additionally protect images whose digest is used by any Swarm service
  if [[ "$SWARM_ACTIVE" -eq 1 && "$SWARM_MANAGER" == "true" ]]; then
    if is_used_by_service "$IMG_ID"; then
      log "🔒 In use by Swarm service digest: $TAGGED ($IMG_ID)"
      continue
    fi
  fi

  # Otherwise delete it
  log "➡️  Cleaning image: $TAGGED ($IMG_ID)"
  if delete_image_all_tags "$IMG_ID"; then
    ((DELETED_COUNT++))
  else
    log "[⚠️] Skipped/failed: $TAGGED ($IMG_ID)"
  fi
done
# Restore errexit for anything after the loop
set -e

# Summary will be printed by the EXIT trap
exit 0
