#!/usr/bin/env bash
# Run the Enhanced stack container (same volume layout as docker-compose.yml).
#
# Paths are never tied to a fixed server path: defaults use the deploying user's
# $HOME (override with KAFKA_USERMGMT_HOME). Folder names under that base are
# configurable (KAFKA_USERMGMT_REL_*), or set DEPLOY_CONFIG / RUNTIME_HOST / SSL_DIR.
#
# Usage:
#   ./container-run-config.sh
#   Default engine: docker if installed, else podman (override: CTR_ENGINE=...)
#   Default image: full GHCR name (avoids Podman short-name registry prompt on RHEL).
#   Local image after docker compose build: IMAGE_NAME=confluent-kafka-user-management:latest
#   Pin version: IMAGE_NAME=ghcr.io/goasutlor/kafka_user_mgt:1.0.63 ./container-run-config.sh
#   Pull policy: KAFKA_USERMGMT_IMAGE_PULL=never (default) = use local image only, no registry pull.
#     Set to missing or always if you want pull-on-run (docker/podman both support --pull).
#   source ./container-run-config.sh && run_container_stop && run_container_start
#
# Repo clone layout (when deploy/config exists next to this script):
#   <script-dir>/deploy/config, runtime/, deploy/ssl - same as docker-compose
#
# User-home layout (default base = $HOME):
#   $KAFKA_USERMGMT_HOME/<REL_CONFIG>/   -> master.config.json, credentials  (/app/config)
#   $KAFKA_USERMGMT_HOME/<REL_RUNTIME>/    -> .kube, configs/*.properties, user_output  (/opt/kafka-usermgmt)
#   $KAFKA_USERMGMT_HOME/<REL_SSL>/        -> server.key, server.crt (optional HTTPS)
#   REL_* default to kafka-usermgmt-config, kafka-usermgmt-runtime, kafka-usermgmt-ssl
#
# Auto: if script-dir/deploy/config is missing but home config+runtime dirs exist -> home layout.
# Force: KAFKA_USERMGMT_USE_HOME_DIRS=1 | KAFKA_USERMGMT_USE_REPO_DIRS=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# docker | podman - prefer docker when both exist; on Podman-only hosts this picks podman.
if [[ ! -v CTR_ENGINE ]]; then
  if command -v docker &>/dev/null; then
    CTR_ENGINE=docker
  elif command -v podman &>/dev/null; then
    CTR_ENGINE=podman
  else
    CTR_ENGINE=docker
  fi
fi
export CTR_ENGINE

export CONTAINER_NAME="${CONTAINER_NAME:-kafka-user-mgmt}"
# Fully qualified: Podman short names (confluent-...:latest) trigger interactive registry choice on RHEL.
export IMAGE_NAME="${IMAGE_NAME:-ghcr.io/goasutlor/kafka_user_mgt:latest}"
# never = run local image only (no pull). Use missing/always to fetch from registry.
export KAFKA_USERMGMT_IMAGE_PULL="${KAFKA_USERMGMT_IMAGE_PULL:-never}"
# Host 443 -> container 3443 (Node listens on 3443 inside image). Override: PORT_MAP=8443:3443
export PORT_MAP="${PORT_MAP:-443:3443}"

# Base directory for user-centric paths (any user, any home path).
export KAFKA_USERMGMT_HOME="${KAFKA_USERMGMT_HOME:-$HOME}"
# Relative directory names under KAFKA_USERMGMT_HOME (change to match your layout).
export KAFKA_USERMGMT_REL_CONFIG="${KAFKA_USERMGMT_REL_CONFIG:-kafka-usermgmt-config}"
export KAFKA_USERMGMT_REL_RUNTIME="${KAFKA_USERMGMT_REL_RUNTIME:-kafka-usermgmt-runtime}"
export KAFKA_USERMGMT_REL_SSL="${KAFKA_USERMGMT_REL_SSL:-kafka-usermgmt-ssl}"

export KAFKA_USERMGMT_USE_HOME_DIRS="${KAFKA_USERMGMT_USE_HOME_DIRS:-0}"
export KAFKA_USERMGMT_USE_REPO_DIRS="${KAFKA_USERMGMT_USE_REPO_DIRS:-0}"

_layout_home() {
  export DEPLOY_CONFIG="${DEPLOY_CONFIG:-$KAFKA_USERMGMT_HOME/$KAFKA_USERMGMT_REL_CONFIG}"
  export RUNTIME_HOST="${RUNTIME_HOST:-$KAFKA_USERMGMT_HOME/$KAFKA_USERMGMT_REL_RUNTIME}"
  export SSL_DIR="${SSL_DIR:-$KAFKA_USERMGMT_HOME/$KAFKA_USERMGMT_REL_SSL}"
}
_layout_repo() {
  export DEPLOY_CONFIG="${DEPLOY_CONFIG:-$SCRIPT_DIR/deploy/config}"
  export RUNTIME_HOST="${RUNTIME_HOST:-$SCRIPT_DIR/runtime}"
  export SSL_DIR="${SSL_DIR:-$SCRIPT_DIR/deploy/ssl}"
}

_home_cfg="$KAFKA_USERMGMT_HOME/$KAFKA_USERMGMT_REL_CONFIG"
_home_rt="$KAFKA_USERMGMT_HOME/$KAFKA_USERMGMT_REL_RUNTIME"

if [[ "$KAFKA_USERMGMT_USE_REPO_DIRS" == "1" ]]; then
  _layout_repo
elif [[ "$KAFKA_USERMGMT_USE_HOME_DIRS" == "1" ]]; then
  _layout_home
elif [[ -d "$SCRIPT_DIR/deploy/config" ]]; then
  _layout_repo
elif [[ -d "$_home_cfg" && -d "$_home_rt" ]]; then
  echo "[container-run-config] user-home layout: base=$KAFKA_USERMGMT_HOME (no $SCRIPT_DIR/deploy/config)" >&2
  _layout_home
else
  _layout_repo
fi

export OC_DIR="${OC_DIR:-/usr/bin}"

# App env (defaults align with docker-compose.yml)
export CONFIG_PATH="${CONFIG_PATH:-/app/config/master.config.json}"
export ALLOW_SETUP_RECONFIGURE="${ALLOW_SETUP_RECONFIGURE:-1}"
export AUTH_ENABLED="${AUTH_ENABLED:-0}"
export SETUP_TOKEN="${SETUP_TOKEN:-}"
export GOLIVE_REPORT_TOKEN="${GOLIVE_REPORT_TOKEN:-}"
export GOLIVE_PORTAL_BASE_URL="${GOLIVE_PORTAL_BASE_URL:-}"
export TRUST_PROXY="${TRUST_PROXY:-0}"
export USE_HTTPS="${USE_HTTPS:-}"
export SSL_KEY_PATH="${SSL_KEY_PATH:-}"
export SSL_CERT_PATH="${SSL_CERT_PATH:-}"
export HSTS_MAX_AGE="${HSTS_MAX_AGE:-}"
export HSTS_INCLUDE_SUBDOMAINS="${HSTS_INCLUDE_SUBDOMAINS:-0}"

# gen.sh / server: runtime root inside container (matches master.config runtimeRoot)
export BASE_HOST="${BASE_HOST:-/opt/kafka-usermgmt}"

run_container_start() {
  if ! command -v "$CTR_ENGINE" &>/dev/null; then
    echo "error: $CTR_ENGINE not found; install Docker/Podman or set CTR_ENGINE=" >&2
    exit 1
  fi
  if [[ ! -d "$DEPLOY_CONFIG" ]]; then
    echo "error: DEPLOY_CONFIG is not a directory: $DEPLOY_CONFIG" >&2
    exit 1
  fi
  if [[ ! -d "$RUNTIME_HOST" ]]; then
    echo "error: RUNTIME_HOST is not a directory: $RUNTIME_HOST" >&2
    exit 1
  fi

  local -a cmd=(
    run -d
    --pull="$KAFKA_USERMGMT_IMAGE_PULL"
    --name "$CONTAINER_NAME"
    --restart=unless-stopped
    -p "$PORT_MAP"
  )
  if [[ "$CTR_ENGINE" == podman ]]; then
    cmd+=(--userns=keep-id --security-opt label=disable)
  fi

  # OC bind: :ro only (no :z). Relabeling host /usr/bin with :z can fail with lsetxattr on RHEL.
  if [[ "$CTR_ENGINE" == podman ]]; then
    cmd+=(-v "$DEPLOY_CONFIG:/app/config:z" -v "$RUNTIME_HOST:/opt/kafka-usermgmt:z" -v "$OC_DIR:/host/usr/bin:ro")
  else
    cmd+=(-v "$DEPLOY_CONFIG:/app/config" -v "$RUNTIME_HOST:/opt/kafka-usermgmt" -v "$OC_DIR:/host/usr/bin:ro")
  fi

  local -a env_args=(
    -e "CONFIG_PATH=$CONFIG_PATH"
    -e "ALLOW_SETUP_RECONFIGURE=$ALLOW_SETUP_RECONFIGURE"
    -e "AUTH_ENABLED=$AUTH_ENABLED"
    -e "BASE_HOST=$BASE_HOST"
    -e "TRUST_PROXY=$TRUST_PROXY"
    -e "HSTS_INCLUDE_SUBDOMAINS=$HSTS_INCLUDE_SUBDOMAINS"
  )
  [[ -n "${SETUP_TOKEN:-}" ]] && env_args+=(-e "SETUP_TOKEN=$SETUP_TOKEN")
  [[ -n "${GOLIVE_REPORT_TOKEN:-}" ]] && env_args+=(-e "GOLIVE_REPORT_TOKEN=$GOLIVE_REPORT_TOKEN")
  [[ -n "${GOLIVE_PORTAL_BASE_URL:-}" ]] && env_args+=(-e "GOLIVE_PORTAL_BASE_URL=$GOLIVE_PORTAL_BASE_URL")
  [[ -n "${HSTS_MAX_AGE:-}" ]] && env_args+=(-e "HSTS_MAX_AGE=$HSTS_MAX_AGE")

  # Optional OC auto-login (writable .kube on host under runtime/.kube)
  [[ -n "${OC_LOGIN_TOKEN:-}" ]] && env_args+=(-e "OC_LOGIN_TOKEN=$OC_LOGIN_TOKEN")
  [[ -n "${OC_LOGIN_TOKEN_CWDC:-}" ]] && env_args+=(-e "OC_LOGIN_TOKEN_CWDC=$OC_LOGIN_TOKEN_CWDC")
  [[ -n "${OC_LOGIN_TOKEN_TLS2:-}" ]] && env_args+=(-e "OC_LOGIN_TOKEN_TLS2=$OC_LOGIN_TOKEN_TLS2")
  [[ -n "${OC_LOGIN_USER:-}" ]] && env_args+=(-e "OC_LOGIN_USER=$OC_LOGIN_USER")
  [[ -n "${OC_LOGIN_PASSWORD:-}" ]] && env_args+=(-e "OC_LOGIN_PASSWORD=$OC_LOGIN_PASSWORD")
  [[ -n "${OC_CREDENTIALS_KEY:-}" ]] && env_args+=(-e "OC_CREDENTIALS_KEY=$OC_CREDENTIALS_KEY")

  local -a https_args=()
  if [[ "${USE_HTTPS:-}" == "0" ]]; then
    :
  elif [[ "${TRUST_PROXY}" == "1" && "${USE_HTTPS:-}" != "1" ]]; then
    :
  elif [[ "${USE_HTTPS:-}" == "1" ]] || [[ -f "$SSL_DIR/server.key" && -f "$SSL_DIR/server.crt" ]]; then
    https_args+=(
      -e USE_HTTPS=1
      -e "SSL_KEY_PATH=${SSL_KEY_PATH:-/app/ssl/server.key}"
      -e "SSL_CERT_PATH=${SSL_CERT_PATH:-/app/ssl/server.crt}"
    )
    if [[ "$CTR_ENGINE" == podman ]]; then
      cmd+=(-v "$SSL_DIR/server.key:/app/ssl/server.key:ro,z" -v "$SSL_DIR/server.crt:/app/ssl/server.crt:ro,z")
    else
      cmd+=(-v "$SSL_DIR/server.key:/app/ssl/server.key:ro" -v "$SSL_DIR/server.crt:/app/ssl/server.crt:ro")
    fi
  fi

  "$CTR_ENGINE" "${cmd[@]}" "${env_args[@]}" "${https_args[@]}" "$IMAGE_NAME"
  echo "Started $CONTAINER_NAME ($CTR_ENGINE) - image $IMAGE_NAME  port $PORT_MAP"
  echo "  config: $DEPLOY_CONFIG  -> /app/config"
  echo "  runtime: $RUNTIME_HOST  -> /opt/kafka-usermgmt"
}

run_container_stop() {
  "$CTR_ENGINE" stop "$CONTAINER_NAME" 2>/dev/null || true
  "$CTR_ENGINE" rm "$CONTAINER_NAME" 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_container_stop
  run_container_start
fi
