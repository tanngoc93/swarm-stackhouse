#!/usr/bin/env bash
## setup.sh
# Interactive helper that fetches the latest `stackhouse_deploy_and_clean.sh`
# from GitHub and embeds user supplied variables into a ready-to-run
# deployment script. All prompts are interactive to keep usage simple.

set -euo pipefail

#----- utilities -------------------------------------------------------
require() {
  # Ensure a required command exists in PATH
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: '$1' is required but not installed." >&2
    exit 1
  }
}

prompt_non_empty() {
  # Prompt the user until a non-empty value is entered
  local var_name="$1" prompt="$2" value
  while true; do
    read -rp "$prompt" value
    [[ -n "$value" ]] && { printf '%s' "$value"; return; }
    echo "$var_name cannot be empty."
  done
}

require curl
require sed

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

#----- prompt for settings -------------------------------------------
IMAGE_REPO=$(prompt_non_empty "IMAGE_REPO" "IMAGE_REPO: ")
STACK_NAME=$(prompt_non_empty "STACK_NAME" "STACK_NAME: ")
STACK_FILE=$(prompt_non_empty "STACK_FILE" "STACK_FILE: ")

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
