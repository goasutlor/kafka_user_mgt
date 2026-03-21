#!/usr/bin/env bash
# Master: Export + Podman run (stable). Full copy-paste block = EXPORT-AND-PODMAN-COPY-PASTE.txt
# Usage: Set ROOT below to match your host (default /opt/kafka-usermgmt), then:
#        ./podman-run-config.sh   or   source podman-run-config.sh && run_podman_start
# After loading the image, run once to start.

# --- Export Path (set to match your host) ---
# When migrating, only change ROOT: everything lives under ROOT (config, ssl, .kube etc.; see MOVE-EVERYTHING-TO-ROOT.md)
export ROOT="${ROOT:-/opt/kafka-usermgmt}"
export CONFIG_HOST="${CONFIG_HOST:-$ROOT/Docker/web.config.json}"
export BASE_HOST="${BASE_HOST:-$ROOT}"
export OC_DIR="${OC_DIR:-/usr/bin}"
export SSL_DIR="${SSL_DIR:-$ROOT/Docker/ssl}"
export KUBE_DIR="${KUBE_DIR:-$ROOT/.kube}"

# Container and image names
export CONTAINER_NAME="${CONTAINER_NAME:-kafka-user-web}"
export IMAGE_NAME="${IMAGE_NAME:-confluent-kafka-user-management:latest}"

# Port: host:container (if server.port=3443 use 443:3443; if 443 use 443:443)
export PORT_MAP="${PORT_MAP:-443:3443}"

# Auth: user file for login (create with: node scripts/auth-users-cli.js add admin)
# To enable login + security code: set AUTH_ENABLED=1 and restart container (no rebuild). Or in web.config.json set "server": { "auth": { "enabled": true } }
export AUTH_USERS_HOST="${AUTH_USERS_HOST:-$ROOT/Docker/auth-users.json}"
export AUTH_ENABLED="${AUTH_ENABLED:-0}"

# Optional: for Auto OC Login — .kube must be mounted writable (not :ro)
# Method 1 (recommended): in config — set gen.ocLoginUser, gen.ocLoginPassword, gen.ocLoginServers in web.config.json (see OC-AUTO-LOGIN.md); no need to export
# Method 2: pass via env (or uncomment below and set values)
# export OC_LOGIN_USER="ocpadmin"
# export OC_LOGIN_PASSWORD="ocp@dmin!"
# Or use token: export OC_LOGIN_TOKEN="sha256~..." or OC_LOGIN_TOKEN_CWDC / OC_LOGIN_TOKEN_TLS2

# --- Podman run (full command) ---
# Mount .kube with :z (writable) when using ocAutoLogin; if not using auto login you can use :ro,z
run_podman_start() {
  local extra=()
  [[ -n "${OC_LOGIN_TOKEN:-}" ]] && extra+=(-e "OC_LOGIN_TOKEN=$OC_LOGIN_TOKEN")
  [[ -n "${OC_LOGIN_TOKEN_CWDC:-}" ]] && extra+=(-e "OC_LOGIN_TOKEN_CWDC=$OC_LOGIN_TOKEN_CWDC")
  [[ -n "${OC_LOGIN_TOKEN_TLS2:-}" ]] && extra+=(-e "OC_LOGIN_TOKEN_TLS2=$OC_LOGIN_TOKEN_TLS2")
  [[ -n "${OC_LOGIN_USER:-}" ]] && extra+=(-e "OC_LOGIN_USER=$OC_LOGIN_USER")
  [[ -n "${OC_LOGIN_PASSWORD:-}" ]] && extra+=(-e "OC_LOGIN_PASSWORD=$OC_LOGIN_PASSWORD")
  [[ -n "${OC_CREDENTIALS_KEY:-}" ]] && extra+=(-e "OC_CREDENTIALS_KEY=$OC_CREDENTIALS_KEY")
  [[ -n "${AUTH_ENABLED:-}" ]] && extra+=(-e "AUTH_ENABLED=$AUTH_ENABLED")

  # When everything is under ROOT: CONFIG/BASE/SSL/KUBE derive from ROOT. If .kube is under ROOT, it is already in the ROOT mount; only add a separate .kube mount when KUBE_DIR is outside ROOT.
  # ROOT must be writable so the script can create .enc in user_output.
  # Docker folder -> /app/config so audit.log and download-history.json from the app end up on host.
  # Single source of truth: all paths under ROOT (e.g. /opt/kafka-usermgmt). When .kube is external we mount to ROOT/.kube-external (not /app/user2).
  local kube_vol=()
  if [[ "$KUBE_DIR" != "$BASE_HOST"* && "$KUBE_DIR" != "$BASE_HOST" ]]; then
    kube_vol=(-v "$KUBE_DIR:$BASE_HOST/.kube-external:z")
  fi
  podman run -d --name "$CONTAINER_NAME" --restart=unless-stopped --userns=keep-id --security-opt label=disable -p "$PORT_MAP" \
    -v "${ROOT}/Docker:/app/config:z" \
    -v "$BASE_HOST:$BASE_HOST:z" \
    -v "$OC_DIR:/host/usr/bin:ro,z" \
    -v "$SSL_DIR/server.key:/app/ssl/server.key:ro,z" \
    -v "$SSL_DIR/server.crt:/app/ssl/server.crt:ro,z" \
    "${kube_vol[@]}" \
    -e CONFIG_PATH=/app/config/web.config.json \
    -e BASE_HOST="$BASE_HOST" \
    "${extra[@]}" \
    "$IMAGE_NAME"
}

run_podman_stop() {
  podman stop "$CONTAINER_NAME" 2>/dev/null || true
  podman rm "$CONTAINER_NAME" 2>/dev/null || true
}

# If this file is run directly (not sourced), start the container
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_podman_stop
  run_podman_start
fi

# Master block = EXPORT-AND-PODMAN-COPY-PASTE.txt (stable). Only change ROOT when migrating.
