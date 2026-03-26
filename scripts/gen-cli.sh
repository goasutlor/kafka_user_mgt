#!/usr/bin/env bash
# CLI UX wrapper for bundled gen.sh (Portal-compatible baseline env)
# - Keeps gen.sh as single engine
# - Adds guided menu + env selection for operators
# - Calls scripts/gen-in-container.sh (which injects PATH/KUBECONFIG/GEN_BASE_DIR safely)
#
# Usage:
#   ./scripts/gen-cli.sh              # menu (pick env inside with option 6)
#   ./scripts/gen-cli.sh dev          # lock to master.config environments[].id == dev, then menu
#   ./scripts/gen-cli.sh --help
#
# Same GEN_* as Portal: GEN_ACTIVE_ENV_ID, GEN_OCP_SITES, GEN_KAFKA_BOOTSTRAP

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/gen-in-container.sh"
MASTER_IN_CONTAINER="${MASTER_IN_CONTAINER:-/app/config/master.config.json}"

if [[ ! -x "$RUNNER" ]]; then
  echo "ERROR: $RUNNER not found or not executable" >&2
  echo "Run: chmod +x scripts/gen-in-container.sh scripts/gen-cli.sh" >&2
  exit 1
fi

if [[ -z "${CTR_ENGINE:-}" ]]; then
  if command -v podman &>/dev/null; then
    CTR_ENGINE=podman
  elif command -v docker &>/dev/null; then
    CTR_ENGINE=docker
  else
    echo "ERROR: install podman or docker" >&2
    exit 1
  fi
fi
CONTAINER_NAME="${CONTAINER_NAME:-kafka-user-mgmt}"

exec_in_container() {
  "$CTR_ENGINE" exec "$CONTAINER_NAME" sh -lc "$1"
}

usage() {
  cat <<'EOF'
Usage: gen-cli.sh [environment-id]

  environment-id  Optional. Must match master.config.json -> environments.environments[].id
                  (e.g. dev, sit, uat or your environment id). Sets GEN_ACTIVE_ENV_ID, GEN_OCP_SITES,
                  GEN_KAFKA_BOOTSTRAP the same way as the Portal env switch, then opens the menu.

  With no args: open menu; use option 6 to pick env interactively.

Requires: running container (CONTAINER_NAME), podman|docker, jq inside container, master at
  /app/config/master.config.json (override with MASTER_IN_CONTAINER on host if needed).
EOF
}

list_env_ids_from_master() {
  exec_in_container "jq -r '.environments.environments[]?.id // empty' '$MASTER_IN_CONTAINER' 2>/dev/null || true" | sed '/^$/d'
}

# Apply Portal parity env from master.config (same fields as Web session env).
apply_environment_by_id() {
  local ENV_ID="$1"
  local ids sites bootstrap

  ids=$(list_env_ids_from_master || true)
  if [[ -z "$ids" ]]; then
    echo "[profile] No environments.environments[] in $MASTER_IN_CONTAINER (skip env lock)." >&2
    return 1
  fi

  if ! echo "$ids" | grep -qx "$ENV_ID"; then
    echo "ERROR: Unknown environment id '$ENV_ID'." >&2
    echo "Valid ids (from master.config):" >&2
    echo "$ids" | sed 's/^/  /' >&2
    return 1
  fi

  export GEN_ACTIVE_ENV_ID="$ENV_ID"

  sites=$(exec_in_container "jq -r --arg id '$ENV_ID' '.environments.environments[]? | select(.id==\$id) | [.sites[]? | ((.ocContext // \"\") + \":\" + (.namespace // \"\"))] | map(select(. != \":\")) | join(\",\")' '$MASTER_IN_CONTAINER' 2>/dev/null || true") || sites=""
  bootstrap=$(exec_in_container "jq -r --arg id '$ENV_ID' '.environments.environments[]? | select(.id==\$id) | .bootstrapServers // empty' '$MASTER_IN_CONTAINER' 2>/dev/null || true") || bootstrap=""

  if [[ -n "$sites" ]]; then
    export GEN_OCP_SITES="$sites"
  else
    unset GEN_OCP_SITES 2>/dev/null || true
  fi
  if [[ -n "$bootstrap" ]]; then
    export GEN_KAFKA_BOOTSTRAP="$bootstrap"
  else
    unset GEN_KAFKA_BOOTSTRAP 2>/dev/null || true
  fi

  echo "[profile] GEN_ACTIVE_ENV_ID=$ENV_ID"
  [[ -n "${GEN_OCP_SITES:-}" ]] && echo "[profile] GEN_OCP_SITES=$GEN_OCP_SITES"
  [[ -n "${GEN_KAFKA_BOOTSTRAP:-}" ]] && echo "[profile] GEN_KAFKA_BOOTSTRAP=$GEN_KAFKA_BOOTSTRAP"
  return 0
}

pick_environment_profile() {
  local ids id_count chosen ENV_ID
  ids=$(list_env_ids_from_master || true)
  id_count=$(echo "$ids" | sed '/^$/d' | wc -l | tr -d ' ')

  if [[ "$id_count" -eq 0 ]]; then
    echo "[profile] No environments[] in master.config (using existing env/defaults)."
    return 0
  fi

  echo ""
  echo "Available environment profiles from master.config:"
  nl -w1 -s') ' <(echo "$ids" | sed '/^$/d')
  echo "0) Keep current env/default"
  read -r -p "Select environment [0-${id_count}] (default 0): " chosen
  chosen="${chosen:-0}"

  if [[ "$chosen" == "0" ]]; then
    return 0
  fi

  if ! [[ "$chosen" =~ ^[0-9]+$ ]] || [[ "$chosen" -lt 1 ]] || [[ "$chosen" -gt "$id_count" ]]; then
    echo "Invalid selection. Keep current env/default." >&2
    return 0
  fi

  ENV_ID=$(echo "$ids" | sed '/^$/d' | sed -n "${chosen}p")
  apply_environment_by_id "$ENV_ID"
}

run_preflight() {
  export GEN_NONINTERACTIVE=1
  export GEN_MODE=6
  "$RUNNER"
}

run_test_user() {
  local user pass topic
  read -r -p "Kafka username: " user
  read -r -s -p "Password: " pass; echo
  read -r -p "Topic name: " topic
  [[ -z "$user" || -z "$pass" || -z "$topic" ]] && { echo "All fields are required."; return 1; }

  export GEN_NONINTERACTIVE=1
  export GEN_MODE=2
  export GEN_KAFKA_USER="$user"
  export GEN_TEST_PASS="$pass"
  export GEN_TOPIC_NAME="$topic"
  "$RUNNER"
}

run_add_acl_existing() {
  local user topic acl
  read -r -p "Existing username: " user
  read -r -p "Topic name: " topic
  read -r -p "ACL preset [1=Read,2=Client,3=All] (default 2): " acl
  acl="${acl:-2}"
  [[ -z "$user" || -z "$topic" ]] && { echo "Username and topic are required."; return 1; }

  export GEN_NONINTERACTIVE=1
  export GEN_MODE=5
  export GEN_KAFKA_USER="$user"
  export GEN_TOPIC_NAME="$topic"
  export GEN_ACL="$acl"
  "$RUNNER"
}

run_guided_add_user() {
  local sys topic user pass acl
  read -r -p "System name: " sys
  read -r -p "Topic name: " topic
  read -r -p "Kafka username: " user
  read -r -s -p "Passphrase (.enc): " pass; echo
  read -r -p "ACL preset [1=Read,2=Client,3=All] (default 2): " acl
  acl="${acl:-2}"
  [[ -z "$sys" || -z "$topic" || -z "$user" || -z "$pass" ]] && { echo "All fields are required."; return 1; }

  export GEN_NONINTERACTIVE=1
  export GEN_MODE=1
  export GEN_SYSTEM_NAME="$sys"
  export GEN_TOPIC_NAME="$topic"
  export GEN_KAFKA_USER="$user"
  export GEN_PASSPHRASE="$pass"
  export GEN_ACL="$acl"
  "$RUNNER"
}

main_menu() {
  while true; do
    echo ""
    echo "==========================================================="
    echo "  Kafka User Mgmt CLI (Portal-like wrapper, same gen.sh)"
    echo "==========================================================="
    echo "Container: ${CONTAINER_NAME} | Engine: ${CTR_ENGINE}"
    [[ -n "${GEN_ACTIVE_ENV_ID:-}" ]] && echo "Active ENV: ${GEN_ACTIVE_ENV_ID}"
    echo ""
    echo "1) Open original interactive gen.sh menu"
    echo "2) Preflight (Mode 6)"
    echo "3) Test existing user (Mode 2)"
    echo "4) Add ACL for existing user (Mode 5)"
    echo "5) Guided Add user (Mode 1)"
    echo "6) Select environment profile from master.config"
    echo "Q) Quit"
    read -r -p "Choose: " choice
    case "${choice:-}" in
      1)
        unset GEN_NONINTERACTIVE GEN_MODE
        "$RUNNER"
        ;;
      2)
        run_preflight
        ;;
      3)
        run_test_user
        ;;
      4)
        run_add_acl_existing
        ;;
      5)
        run_guided_add_user
        ;;
      6)
        pick_environment_profile
        ;;
      q|Q)
        echo "Bye"
        exit 0
        ;;
      *)
        echo "Invalid choice"
        ;;
    esac
  done
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  apply_environment_by_id "$1" || exit 1
  shift
fi

main_menu
