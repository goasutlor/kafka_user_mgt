#!/usr/bin/env bash
# Run the Enhanced stack container (same volume layout as docker-compose.yml).
#
# =============================================================================
# Volume mounts (summary)
# =============================================================================
#   Host path                 -> Container path           Purpose
#   -------------------------    ----------------------   ------------------
#   DEPLOY_CONFIG             -> /app/config              master.config.json, credentials,
#                                                           audit / download history (app writes here)
#   RUNTIME_HOST              -> /opt/kafka-usermgmt      runtimeRoot: *.properties, user_output, packs
#                                                           (.kube here too unless overlaid by KUBE_HOST)
#   KUBE_HOST (default)       -> /opt/kafka-usermgmt/.kube  kubeconfig for oc; context names must match Setup
#                                (bind-mount overlays .kube under runtime)   default: $HOME/.kube
#   OC_DIR (default /usr/bin) -> /host/usr/bin :ro       host oc binary (Linux)
#   SSL_DIR (if HTTPS)        -> key/cert -> /app/ssl     in-container TLS (optional)
#
# Disable separate .kube bind (use only files under RUNTIME_HOST/.kube):
#   KAFKA_USERMGMT_MOUNT_KUBE=0 ./container-run-config.sh
#
# Custom kubeconfig directory on host:
#   KUBE_HOST=/path/to/.kube ./container-run-config.sh
#
# master.config / Setup: oc.kubeconfig is usually {runtimeRoot}/.kube/config (oc login default).
#   Use config-both only for a merged multi-cluster kubeconfig -> /opt/kafka-usermgmt/.kube/config-both
#   Must be the same file tree you mount above.
# =============================================================================
#
# Paths are never tied to a fixed server path: defaults use the deploying user's
# $HOME (override with KAFKA_USERMGMT_HOME). Folder names under that base are
# configurable (KAFKA_USERMGMT_REL_*), or set DEPLOY_CONFIG / RUNTIME_HOST / SSL_DIR.
#
# After the container is up, CLI gen.sh (same oc + KUBECONFIG baseline as Web):
#   ./scripts/gen-in-container.sh
#   export GEN_NONINTERACTIVE=1 GEN_MODE=2 GEN_KAFKA_USER=... ; ./scripts/gen-in-container.sh
#
# Usage:
#   ./container-run-config.sh
#   ./container-run-config.sh --upgrade-latest
#     Pull :latest from registry, remove old container, start a new one (IMAGE_NAME must end with :latest).
#     Same as: KAFKA_USERMGMT_UPGRADE_LATEST=1 ./container-run-config.sh
#     For locally built tags only, use docker compose build/up instead of --upgrade-latest.
#   Default engine: docker if installed, else podman (override: CTR_ENGINE=...)
#   Default image: full GHCR name (avoids Podman short-name registry prompt on RHEL).
#   Local image after docker compose build: IMAGE_NAME=confluent-kafka-user-management:latest
#   Pin version: IMAGE_NAME=ghcr.io/goasutlor/kafka_user_mgt:1.0.64 ./container-run-config.sh
#   Pull policy: KAFKA_USERMGMT_IMAGE_PULL=never (default) = do not re-pull on run if image already exists.
#     If no local image and tag is :latest (or no tag = latest), the script pulls once before run.
#     Pinned tags (e.g. :1.0.64): pull manually or set IMAGE_NAME to :latest / use --upgrade-latest.
#     Set to missing or always if you want pull-on-run (docker/podman both support --pull).
#   source ./container-run-config.sh && run_container_stop && run_container_start
#
# Repo clone layout (when deploy/config exists next to this script):
#   <script-dir>/deploy/config, runtime/, deploy/ssl - same as docker-compose
#
# User-home layout (default base = $HOME):
#   $KAFKA_USERMGMT_HOME/<REL_CONFIG>/   -> master.config.json, credentials  (/app/config)
#   $KAFKA_USERMGMT_HOME/<REL_RUNTIME>/    -> configs/*.properties, user_output  (/opt/kafka-usermgmt)
#   $KAFKA_USERMGMT_HOME/<REL_SSL>/        -> server.key, server.crt (optional HTTPS)
#   REL_* default to kafka-usermgmt-config, kafka-usermgmt-runtime, kafka-usermgmt-ssl
#   .kube: by default bind-mount $HOME/.kube -> /opt/kafka-usermgmt/.kube (see table above)
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

# Mount host .kube into container runtime (so oc sees the same contexts as your shell).
# Set KAFKA_USERMGMT_MOUNT_KUBE=0 to use only files already under RUNTIME_HOST/.kube.
export KAFKA_USERMGMT_MOUNT_KUBE="${KAFKA_USERMGMT_MOUNT_KUBE:-1}"
export KUBE_HOST="${KUBE_HOST:-$HOME/.kube}"

# Return 0 if dir1 and dir2 are the same path (then a separate .kube mount is redundant).
_same_dir() {
  local a b
  a=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  b=$(cd "$2" 2>/dev/null && pwd -P) || return 1
  [[ "$a" == "$b" ]]
}

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

_step_total=0
_step_cur=0
_step_begin() {
  _step_total="$1"
  _step_cur=0
}
_step() {
  _step_cur=$((_step_cur + 1))
  echo ""
  echo "[Step ${_step_cur}/${_step_total}] $*"
}

# True if IMAGE_NAME uses :latest or omits a tag (OCI default tag = latest).
# Use last / segment only so hostnames like ghcr.io are not treated as "has a tag".
_image_is_latest_tag() {
  local base="${IMAGE_NAME##*/}"
  [[ "$base" != *:* ]] && return 0
  [[ "$base" == *:latest ]] && return 0
  return 1
}

container_image_exists() {
  if [[ "$CTR_ENGINE" == podman ]]; then
    podman inspect --type image "$IMAGE_NAME" &>/dev/null
  else
    docker image inspect "$IMAGE_NAME" &>/dev/null
  fi
}

_hint_registry_login() {
  case "$IMAGE_NAME" in
    ghcr.io/*)
      echo "  GHCR (private package): $CTR_ENGINE login ghcr.io   # PAT with read:packages" >&2
      ;;
    quay.io/*)
      echo "  Quay: $CTR_ENGINE login quay.io" >&2
      ;;
    docker.io/*|docker.io/*/*)
      echo "  Docker Hub: $CTR_ENGINE login docker.io" >&2
      ;;
    *)
      local r="${IMAGE_NAME%%/*}"
      if [[ "$IMAGE_NAME" == */* && "$r" == *.* ]]; then
        echo "  Private registry: $CTR_ENGINE login $r" >&2
      fi
      ;;
  esac
}

# Pull from registry; on failure print hints (auth, offline, wrong arch).
pull_image_or_exit() {
  local reason="${1:-Pulling image}"
  echo "[preflight] $reason: $IMAGE_NAME" >&2
  if ! "$CTR_ENGINE" pull "$IMAGE_NAME"; then
    echo "error: $CTR_ENGINE pull failed: $IMAGE_NAME" >&2
    _hint_registry_login
    echo "  Offline / air-gapped: load a saved image: podman load -i image.tar" >&2
    echo "  Build locally: clone repo, then: docker compose build && IMAGE_NAME=confluent-kafka-user-management:latest $0" >&2
    exit 1
  fi
  if ! container_image_exists; then
    echo "error: image still not present after pull: $IMAGE_NAME" >&2
    exit 1
  fi
}

# Ensure a runnable image exists locally (auto-pull only for :latest or untagged ref).
ensure_image_available() {
  if container_image_exists; then
    return 0
  fi
  echo "[preflight] No local image: $IMAGE_NAME" >&2
  if _image_is_latest_tag; then
    pull_image_or_exit "No local copy — pulling (latest / default tag)"
  else
    echo "error: image not found locally; tag is pinned (not :latest) — automatic pull is disabled for pinned tags" >&2
    echo "  Run:  $CTR_ENGINE pull \"$IMAGE_NAME\"" >&2
    _hint_registry_login
    echo "  Or switch to latest: IMAGE_NAME=<registry>/repo:latest  $0 --upgrade-latest" >&2
    echo "  Or local build: IMAGE_NAME=confluent-kafka-user-management:latest after docker compose build" >&2
    exit 1
  fi
}

run_container_start() {
  local effective_pull="${1:-$KAFKA_USERMGMT_IMAGE_PULL}"
  if ! command -v "$CTR_ENGINE" &>/dev/null; then
    echo "error: $CTR_ENGINE not found; install Docker/Podman or set CTR_ENGINE=" >&2
    exit 1
  fi
  if [[ ! -d "$DEPLOY_CONFIG" ]]; then
    echo "error: DEPLOY_CONFIG is not a directory: $DEPLOY_CONFIG" >&2
    echo "  Create it and add master.config.json (or use repo layout with deploy/config)." >&2
    exit 1
  fi
  if [[ ! -d "$RUNTIME_HOST" ]]; then
    echo "error: RUNTIME_HOST is not a directory: $RUNTIME_HOST" >&2
    echo "  Create: mkdir -p \"$RUNTIME_HOST/configs\" \"$RUNTIME_HOST/.kube\" \"$RUNTIME_HOST/user_output\"" >&2
    exit 1
  fi

  ensure_image_available

  if [[ ! -d "$OC_DIR" ]]; then
    echo "error: OC_DIR is not a directory: $OC_DIR (host oc bind-mount; create dir or set OC_DIR=)" >&2
    echo "  On Linux use default /usr/bin. If unused, you still need a valid path for this script's volume line." >&2
    exit 1
  fi

  local -a cmd=(
    run -d
    --pull="$effective_pull"
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

  # Bind user's (or KUBE_HOST) kubeconfig on top of /opt/kafka-usermgmt/.kube — portal/gen use KUBECONFIG from config.
  local kube_note=""
  if [[ "${KAFKA_USERMGMT_MOUNT_KUBE}" == "1" ]]; then
    mkdir -p "$KUBE_HOST"
    local rt_kube="$RUNTIME_HOST/.kube"
    if _same_dir "$KUBE_HOST" "$rt_kube" 2>/dev/null; then
      kube_note="kube: same dir as RUNTIME_HOST/.kube (no extra bind) — $KUBE_HOST"
    else
      if [[ "$CTR_ENGINE" == podman ]]; then
        cmd+=(-v "$KUBE_HOST:/opt/kafka-usermgmt/.kube:z")
      else
        cmd+=(-v "$KUBE_HOST:/opt/kafka-usermgmt/.kube")
      fi
      kube_note="kube: $KUBE_HOST  ->  /opt/kafka-usermgmt/.kube  (oc / Setup Verify / GET /api/users)"
    fi
  else
    kube_note="kube: host bind disabled (KAFKA_USERMGMT_MOUNT_KUBE=0) — using files only under $RUNTIME_HOST/.kube"
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

  if ! "$CTR_ENGINE" "${cmd[@]}" "${env_args[@]}" "${https_args[@]}" "$IMAGE_NAME"; then
    echo "error: $CTR_ENGINE run failed (check port $PORT_MAP, SELinux labels, disk, or logs above)" >&2
    echo "  Status: $CTR_ENGINE ps -a --filter name=$CONTAINER_NAME" >&2
    exit 1
  fi
  echo ""
  echo "Started $CONTAINER_NAME ($CTR_ENGINE) - image $IMAGE_NAME  port $PORT_MAP"
  echo ""
  echo "=== Mount summary (host -> container | purpose) ==="
  echo "  config   | $DEPLOY_CONFIG -> /app/config | master.config, credentials, audit"
  echo "  runtime  | $RUNTIME_HOST -> /opt/kafka-usermgmt | props, user_output, runtimeRoot"
  echo "  $kube_note"
  echo "  oc (ro)  | $OC_DIR -> /host/usr/bin | host oc binary"
  if [[ ${#https_args[@]} -gt 0 ]]; then
    echo "  https    | $SSL_DIR/server.{key,crt} -> /app/ssl | in-container TLS"
  fi
  echo "=== Set oc.kubeconfig / gen.kubeconfigPath under /opt/kafka-usermgmt/.kube (prefer config; config-both only if merged multi-cluster) ==="
  echo ""
}

run_container_stop() {
  "$CTR_ENGINE" stop "$CONTAINER_NAME" 2>/dev/null || true
  "$CTR_ENGINE" rm "$CONTAINER_NAME" 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  UPGRADE_LATEST=0
  case "${1:-}" in
    --upgrade-latest|--pull-latest)
      UPGRADE_LATEST=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--upgrade-latest]"
      echo "  (default) Stop/remove existing container, then start. If no local image and tag is :latest (or untagged), pulls once."
      echo "  --upgrade-latest  IMAGE_NAME must be :latest or untagged — always pull, remove old container, start new."
      echo "  Env: CTR_ENGINE, IMAGE_NAME, CONTAINER_NAME, PORT_MAP, KAFKA_USERMGMT_UPGRADE_LATEST=1, ..."
      exit 0
      ;;
  esac
  [[ "${KAFKA_USERMGMT_UPGRADE_LATEST:-0}" == "1" ]] && UPGRADE_LATEST=1
  if [[ -n "${1:-}" ]]; then
    echo "error: unknown argument: $1 (try --help)" >&2
    exit 2
  fi

  if [[ "$UPGRADE_LATEST" == "1" ]]; then
    if ! _image_is_latest_tag; then
      echo "error: --upgrade-latest requires IMAGE_NAME with :latest or no tag (current: $IMAGE_NAME)" >&2
      exit 1
    fi
    _step_begin 3
    _step "Stopping and removing existing container (if any)"
    run_container_stop
    _step "Pulling latest image from registry"
    pull_image_or_exit "Refreshing image"
    _step "Starting new container (run uses --pull=never; image already updated)"
    run_container_start never
  else
    _step_begin 2
    _step "Stopping and removing existing container (if any)"
    run_container_stop
    _step "Starting container (run --pull=${KAFKA_USERMGMT_IMAGE_PULL})"
    run_container_start
  fi
  echo ""
  echo "Done. All steps completed."
fi
