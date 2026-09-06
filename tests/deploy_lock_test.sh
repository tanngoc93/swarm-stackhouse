#!/usr/bin/env bash
set -euo pipefail

# Linux integration tests using real flock, with no Docker or Swarm mutations.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
export LOCK_HELPER="$repo_root/scripts/deploy_lock.sh"
export GLOBAL_DEPLOY_LOCK_FILE="$test_dir/global.lock"
export GLOBAL_DEPLOY_LOCK_TIMEOUT=5
export TEST_DIR="$test_dir"

wait_for() {
  local attempt
  for attempt in {1..100}; do
    [[ -e "$1" ]] && return 0
    sleep 0.05
  done
  echo "Timed out waiting for $1" >&2
  return 1
}

# Acquire twice inside the same background subshell, then from an exec child.
# The parent has no FD 200, so checking /proc/$$/fd deadlocks here.
timeout 8 bash -euc '
  source "$LOCK_HELPER"
  (
    acquire_global_deploy_lock first
    acquire_global_deploy_lock nested
    bash -euc '\''source "$LOCK_HELPER"; acquire_global_deploy_lock child'\''
  ) &
  wait "$!"
'
echo "PASS: subshell and child inherit the same lock"

# A marker with an unrelated descriptor must not bypass the busy global lock.
timeout 10 bash -euc '
  source "$LOCK_HELPER"
  acquire_global_deploy_lock holder
  touch "$TEST_DIR/holder-ready"
  while [[ ! -e "$TEST_DIR/release" ]]; do sleep 0.05; done
' > "$test_dir/holder.log" 2>&1 &
holder=$!
wait_for "$test_dir/holder-ready"
timeout 10 bash -euc '
  exec 200>"$TEST_DIR/unrelated.lock"
  export GLOBAL_DEPLOY_LOCK_HELD=true
  source "$LOCK_HELPER"
  touch "$TEST_DIR/waiter-ready"
  acquire_global_deploy_lock waiter
  touch "$TEST_DIR/waiter-entered"
' > "$test_dir/waiter.log" 2>&1 &
waiter=$!
wait_for "$test_dir/waiter-ready"
sleep 0.15
[[ ! -e "$test_dir/waiter-entered" ]]

if GLOBAL_DEPLOY_LOCK_TIMEOUT=1 bash -euc \
  'source "$LOCK_HELPER"; acquire_global_deploy_lock timeout; touch "$TEST_DIR/timeout-entered"' \
  > "$test_dir/timeout.log" 2>&1; then
  echo "Busy lock unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -e "$test_dir/timeout-entered" ]]
grep -q 'Timed out waiting' "$test_dir/timeout.log"
touch "$test_dir/release"
wait "$holder"
wait "$waiter"
[[ -e "$test_dir/waiter-entered" ]]
echo "PASS: concurrent worker waits, timeout fails, then queued worker resumes"

# Exercise the actual deploy worker behind a lock held by a migration runner.
# Docker is a strict mock: no real provider or Swarm calls can run.
mkdir "$test_dir/bin"
cat > "$test_dir/bin/docker" <<'MOCK'
#!/usr/bin/env bash
case "$1 $2" in
  'info --format') echo true ;;
  'stack services') echo demo_web ;;
  'service inspect') echo example/app:test ;;
  *) echo "Unexpected Docker command" >&2; exit 99 ;;
esac
MOCK
chmod +x "$test_dir/bin/docker"
touch "$test_dir/stack.yml"
export LOCK_FILE="$test_dir/stack.lock"
export LOG_FILE="$test_dir/deploy.log"
timeout 10 bash -euc '
  exec 9>"$LOCK_FILE"
  flock -x 9
  echo "$BASHPID" >&9
  touch "$TEST_DIR/stack-ready"
  while [[ ! -e "$TEST_DIR/stack-release" ]]; do sleep 0.05; done
' &
stack_holder=$!
wait_for "$test_dir/stack-ready"
inode_before="$(stat -c %i "$LOCK_FILE")"
PATH="$test_dir/bin:$PATH" IMAGE_REPO=example/app IMAGE_TAG=test STACK_NAME=demo \
  STACK_FILE="$test_dir/stack.yml" CLEANUP_SCRIPT="$test_dir/no-cleanup" \
  timeout 10 bash "$repo_root/scripts/deploy_and_cleanup.sh" &
worker=$!
wait_for "$LOG_FILE"
sleep 0.15
kill -0 "$worker"
! grep -q 'No deployment needed' "$LOG_FILE"
touch "$test_dir/stack-release"
wait "$stack_holder"
wait "$worker"
grep -q 'No deployment needed' "$LOG_FILE"
[[ "$(stat -c %i "$LOCK_FILE")" == "$inode_before" ]]
echo "PASS: actual deploy worker waits on existing stack lock and preserves inode"

if GLOBAL_DEPLOY_LOCK_TIMEOUT=invalid bash -euc \
  'source "$LOCK_HELPER"; acquire_global_deploy_lock invalid' >/dev/null 2>&1; then
  echo "Invalid timeout unexpectedly succeeded" >&2
  exit 1
fi
echo "PASS: invalid timeout is rejected"
