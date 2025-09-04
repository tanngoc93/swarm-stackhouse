#!/usr/bin/env bash
# setup.sh - interactive generator for deploy scripts based on stackhouse_deploy_and_clean.sh

set -euo pipefail

cat <<'DESC'
=====================================================================
Stackhouse deploy setup
---------------------------------------------------------------------
This utility generates a custom deployment script based on the latest
stackhouse_deploy_and_clean.sh from GitHub. You'll be prompted for:
  - IMAGE_REPO : container image repository
  - STACK_NAME : name of the Swarm stack
  - STACK_FILE : path to the stack YAML file
A script named deploy_<STACK_NAME>_<timestamp>.sh will be created in
this directory with these values baked in.
=====================================================================
DESC

read -rp "IMAGE_REPO: " IMAGE_REPO
while [[ -z "$IMAGE_REPO" ]]; do
  echo "IMAGE_REPO cannot be empty."
  read -rp "IMAGE_REPO: " IMAGE_REPO
done

read -rp "STACK_NAME: " STACK_NAME
while [[ -z "$STACK_NAME" ]]; do
  echo "STACK_NAME cannot be empty."
  read -rp "STACK_NAME: " STACK_NAME
done

read -rp "STACK_FILE: " STACK_FILE
while [[ -z "$STACK_FILE" ]]; do
  echo "STACK_FILE cannot be empty."
  read -rp "STACK_FILE: " STACK_FILE
done

# Escape user input for safe sed replacement
escape_sed() { printf '%s' "$1" | sed -e 's/[\\/|&]/\\&/g'; }

rep_repo=$(escape_sed "$IMAGE_REPO")
rep_name=$(escape_sed "$STACK_NAME")
rep_file=$(escape_sed "$STACK_FILE")

timestamp=$(date +%s)
output="deploy_${STACK_NAME}_${timestamp}.sh"

echo "⬇️  Fetching latest stackhouse_deploy_and_clean.sh from GitHub..."
curl -fsSL \
  https://raw.githubusercontent.com/tanngoc93/swarm-stackhouse/main/stackhouse_deploy_and_clean.sh \
  -o "$output" || {
    echo "❌ Failed to download stackhouse_deploy_and_clean.sh"
    exit 1
  }

# Replace defaults with user input (keeping ${VAR:-...} format)
sed -i.bak "s|^IMAGE_REPO=.*|IMAGE_REPO=\"\${IMAGE_REPO:-$rep_repo}\"|" "$output"
sed -i.bak "s|^STACK_NAME=.*|STACK_NAME=\"\${STACK_NAME:-$rep_name}\"|" "$output"
sed -i.bak "s|^STACK_FILE=.*|STACK_FILE=\"\${STACK_FILE:-$rep_file}\"|" "$output"
rm -f "$output.bak"

chmod +x "$output"

echo -e "\n✅ Created deployment script: $output"
