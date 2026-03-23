#!/usr/bin/env bash
# Move everything under a single ROOT — after run, only adjust ROOT / config when moving users
# Usage:
#   OLD_ROOT=/app/user2/kotestkafka NEW_ROOT=/opt/kafka-usermgmt ./scripts/move-to-root.sh
#   Or set OLD_ROOT/NEW_ROOT below and run

set -e
OLD_ROOT="${OLD_ROOT:-/app/user2/kotestkafka}"
NEW_ROOT="${NEW_ROOT:-}"

if [[ -z "$NEW_ROOT" ]]; then
  echo "Usage: NEW_ROOT=/path/to/new/root [OLD_ROOT=/app/user2/kotestkafka] $0"
  echo "Example: NEW_ROOT=/opt/kafka-usermgmt OLD_ROOT=/app/user2/kotestkafka $0"
  echo "Note: If NEW_ROOT is under /opt, root must create it and chown to your user first (see MOVE-EVERYTHING-TO-ROOT.md §0)."
  exit 1
fi
if [[ "$NEW_ROOT" == /opt/* ]] && [[ ! -w "$(dirname "$NEW_ROOT")" ]]; then
  echo "[WARN] $NEW_ROOT is under /opt and you may not have write permission. Create the folder and chown first, e.g.:"
  echo "  sudo mkdir -p $NEW_ROOT && sudo chown -R \$(whoami) $NEW_ROOT"
  read -p "Continue anyway? [y/N] " c
  [[ "${c,,}" == "y" ]] || exit 1
fi

echo "--- Move everything under one ROOT ---"
echo "OLD_ROOT=$OLD_ROOT"
echo "NEW_ROOT=$NEW_ROOT"
read -p "Continue? [y/N] " c
[[ "${c,,}" == "y" ]] || exit 0

# Layout
mkdir -p "$NEW_ROOT"/{configs,user_output,.kube,Docker/ssl}
mkdir -p "$NEW_ROOT/kafka_2.13-3.6.1/bin"

# Copy script
if [[ -f "$OLD_ROOT/confluent-usermanagement.sh" ]]; then
  cp -a "$OLD_ROOT/confluent-usermanagement.sh" "$NEW_ROOT/"
elif [[ -f "$OLD_ROOT/gen.sh" ]]; then
  cp -a "$OLD_ROOT/gen.sh" "$NEW_ROOT/confluent-usermanagement.sh"
else
  echo "[WARN] No script at $OLD_ROOT/confluent-usermanagement.sh or gen.sh"
fi

# Configs
[[ -d "$OLD_ROOT/configs" ]] && cp -a "$OLD_ROOT/configs/"* "$NEW_ROOT/configs/" 2>/dev/null || true

# Kafka bin
[[ -d "$OLD_ROOT/kafka_2.13-3.6.1" ]] && cp -a "$OLD_ROOT/kafka_2.13-3.6.1/"* "$NEW_ROOT/kafka_2.13-3.6.1/" 2>/dev/null || true

# .kube (if under OLD_ROOT)
[[ -d "$OLD_ROOT/.kube" ]] && cp -a "$OLD_ROOT/.kube/"* "$NEW_ROOT/.kube/" 2>/dev/null || true

# Docker: config + ssl
if [[ -f "$OLD_ROOT/Docker/web.config.json" ]]; then
  cp -a "$OLD_ROOT/Docker/web.config.json" "$NEW_ROOT/Docker/"
elif [[ -f "$OLD_ROOT/web.config.json" ]]; then
  cp -a "$OLD_ROOT/web.config.json" "$NEW_ROOT/Docker/"
fi
[[ -d "$OLD_ROOT/Docker/ssl" ]] && cp -a "$OLD_ROOT/Docker/ssl/"* "$NEW_ROOT/Docker/ssl/" 2>/dev/null || true

chmod +x "$NEW_ROOT/confluent-usermanagement.sh" 2>/dev/null || true

echo ""
echo "Done. Next:"
echo "  1. Edit $NEW_ROOT/Docker/web.config.json — set gen.rootDir to \"$NEW_ROOT\" and remove (or leave) scriptPath, baseDir, ... so server derives from rootDir."
echo "  2. Set gen.kubeconfigPath to \"$NEW_ROOT/.kube/config-both\" if you copied .kube into ROOT."
echo "  3. Set server.https.keyPath to \"$NEW_ROOT/Docker/ssl/server.key\" and certPath to \"$NEW_ROOT/Docker/ssl/server.crt\"."
echo "  4. Run container with: ROOT=$NEW_ROOT and mount -v \$ROOT:\$ROOT (see MOVE-EVERYTHING-TO-ROOT.md)."
