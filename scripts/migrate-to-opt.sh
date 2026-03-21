#!/usr/bin/env bash
# =============================================================================
# Migrate to /opt/kafka-usermgmt — Move or copy everything from an old path
# to /opt/kafka-usermgmt so the whole stack lives under one root (seamless
# backup/restore and no /app/user2 reference).
#
# Usage:
#   sudo ./migrate-to-opt.sh [OLD_ROOT]
#   OLD_ROOT = current location of kafka-usermgmt (default: /app/user2/kotestkafka)
#   NEW_ROOT is always /opt/kafka-usermgmt (override with MIGRATE_NEW_ROOT if needed).
#
# Optional env:
#   MIGRATE_NEW_ROOT  = target directory (default: /opt/kafka-usermgmt)
#   MIGRATE_OWNER     = user:group for chown after copy (e.g. user2:user1)
#   MIGRATE_COPY      = 1 to copy (default); 0 to move (rm -rf OLD after copy)
# =============================================================================

set -e
export LANG=C

OLD_ROOT="${1:-${MIGRATE_OLD_ROOT:-/app/user2/kotestkafka}}"
NEW_ROOT="${MIGRATE_NEW_ROOT:-/opt/kafka-usermgmt}"

if [[ ! -d "$OLD_ROOT" ]]; then
  echo "Error: OLD_ROOT not found: $OLD_ROOT"
  echo "Usage: $0 [OLD_ROOT]"
  echo "  OLD_ROOT = current path of kafka-usermgmt (default: /app/user2/kotestkafka)"
  exit 1
fi

OLD_ROOT="$(cd -P "$OLD_ROOT" && pwd)"
mkdir -p "$NEW_ROOT"
NEW_ROOT="$(cd -P "$NEW_ROOT" && pwd)"

echo "Migrate to single root (seamless)"
echo "  OLD_ROOT = $OLD_ROOT"
echo "  NEW_ROOT = $NEW_ROOT"
echo ""

if [[ -d "$NEW_ROOT/Docker" || -d "$NEW_ROOT/configs" ]]; then
  echo "Warning: $NEW_ROOT already has content (Docker or configs)."
  read -p "Overwrite / merge? [y/N] " -r
  if [[ "${REPLY,,}" != "y" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# Copy entire tree
echo "Copying $OLD_ROOT -> $NEW_ROOT ..."
mkdir -p "$NEW_ROOT"
cp -a "$OLD_ROOT"/. "$NEW_ROOT/" 2>/dev/null || ( rsync -a "$OLD_ROOT/" "$NEW_ROOT/" 2>/dev/null ) || {
  echo "Error: copy failed. Try running as root."
  exit 1
}

# If .kube was outside OLD (e.g. /app/user2/.kube), copy it under NEW_ROOT
KUBE_OLD="/app/user2/.kube"
if [[ -d "$KUBE_OLD" && ! -d "$NEW_ROOT/.kube" ]]; then
  echo "Copying $KUBE_OLD -> $NEW_ROOT/.kube ..."
  cp -a "$KUBE_OLD" "$NEW_ROOT/.kube"
fi

# Rewrite paths: Docker/web.config.json and configs/*.properties (ssl.truststore.location etc.)
OLD_ESC="${OLD_ROOT//\//\\/}"
NEW_ESC="${NEW_ROOT//\//\\/}"

CONFIG="$NEW_ROOT/Docker/web.config.json"
if [[ -f "$CONFIG" ]]; then
  echo "Updating paths in Docker/web.config.json ..."
  sed -i.bak -e "s|$OLD_ESC|$NEW_ESC|g" "$CONFIG"
  sed -i -e "s|/app/user2/\\.kube|$NEW_ESC/.kube|g" "$CONFIG"
  rm -f "$CONFIG.bak"
  echo "  Done."
fi

CONFIGS_DIR="$NEW_ROOT/configs"
if [[ -d "$CONFIGS_DIR" ]]; then
  echo "Updating paths in configs/*.properties (certs, etc.) ..."
  for f in "$CONFIGS_DIR"/*.properties; do
    [[ -f "$f" ]] || continue
    sed -i.bak -e "s|$OLD_ESC|$NEW_ESC|g" -e "s|/app/user2/\\.kube|$NEW_ESC/.kube|g" "$f"
    rm -f "${f}.bak"
  done
  echo "  Done. Kafka client configs now point to $NEW_ROOT (e.g. certs, truststore)."
fi

# chown if requested
if [[ -n "${MIGRATE_OWNER:-}" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "Setting owner to $MIGRATE_OWNER ..."
    chown -R "$MIGRATE_OWNER" "$NEW_ROOT" || true
  else
    echo "Skipping chown (not root). Run: sudo chown -R $MIGRATE_OWNER $NEW_ROOT"
  fi
fi

echo ""
echo "--- Migrate done ---"
echo "  All under: $NEW_ROOT"
echo ""
echo "Next steps:"
echo "  1. Stop existing container if running: podman stop kafka-user-web; podman rm kafka-user-web"
echo "  2. Start from new path: export ROOT=$NEW_ROOT && cd $NEW_ROOT && ./podman_runconfig.sh"
echo "  3. If you no longer need the old path: rm -rf $OLD_ROOT"
echo ""
