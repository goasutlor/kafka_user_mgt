#!/usr/bin/env bash
# =============================================================================
# Restore / Migrate — Run on new (target) machine after copying backup from source.
# Should be run as root so chown can set new user/group on restored files.
#
# Interactive mode: run with no arguments; script will prompt for:
#   - Backup file path
#   - Target folder (or default /opt/kafka-usermgmt)
#   - Owner (user) and group for restored files
#
# Non-interactive: pass arguments or use env vars:
#   ./restore-migrate.sh <backup.tar.gz> [TARGET_PARENT]
#   RESTORE_OWNER_USER=user2 RESTORE_OWNER_GROUP=user1 ./restore-migrate.sh backup.tar.gz /opt
#   TARGET_PARENT = parent directory (default /opt) → yields TARGET_PARENT/kafka-usermgmt
# =============================================================================

set -e
export LANG=C

# Can be set via env when not using interactive prompts
RESTORE_OWNER_USER="${RESTORE_OWNER_USER:-}"
RESTORE_OWNER_GROUP="${RESTORE_OWNER_GROUP:-}"
RESTORE_TARGET_PARENT="${RESTORE_TARGET_PARENT:-}"
RESTORE_NONINTERACTIVE="${RESTORE_NONINTERACTIVE:-0}"

# --- Check root (chown requires root) ---
CAN_CHOWN=true
[[ "$(id -u)" -ne 0 ]] && CAN_CHOWN=false

# --- Get backup file path ---
BACKUP_TAR=""
if [[ $# -ge 1 && -f "${1:-}" ]]; then
  BACKUP_TAR="$1"
  shift
fi

if [[ -z "$BACKUP_TAR" ]]; then
  echo "Restore / Migrate (Interactive)"
  echo "  Run as root (sudo) so chown can set owner/group: sudo $0"
  echo ""
  read -p "Path to backup file (.tar.gz): " BACKUP_TAR
  BACKUP_TAR="$(echo "$BACKUP_TAR" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

if [[ -z "$BACKUP_TAR" || ! -f "$BACKUP_TAR" ]]; then
  echo "Error: backup file not found: $BACKUP_TAR"
  exit 1
fi
BACKUP_TAR="$(cd -P "$(dirname "$BACKUP_TAR")" && pwd)/$(basename "$BACKUP_TAR")"

# --- Target parent (directory that will contain kafka-usermgmt) ---
TARGET_PARENT="$RESTORE_TARGET_PARENT"
if [[ -z "$TARGET_PARENT" ]]; then
  if [[ "$RESTORE_NONINTERACTIVE" == "1" && $# -ge 1 ]]; then
    TARGET_PARENT="${1:-/opt}"
    shift
  elif [[ $# -ge 1 ]]; then
    TARGET_PARENT="$1"
    shift
  fi
fi

if [[ -z "$TARGET_PARENT" ]]; then
  echo ""
  echo "Target folder: parent directory — result will be <parent>/kafka-usermgmt"
  echo "  Example: /opt → yields /opt/kafka-usermgmt"
  read -p "Target parent directory [default: /opt]: " TARGET_PARENT
  TARGET_PARENT="${TARGET_PARENT:-/opt}"
fi

TARGET_PARENT="$(cd -P "$TARGET_PARENT" 2>/dev/null && pwd)" || { echo "Error: target parent not found: $TARGET_PARENT"; exit 1; }
DEST="$TARGET_PARENT/kafka-usermgmt"

# --- Owner (user) ---
NEW_USER="$RESTORE_OWNER_USER"
if [[ -z "$NEW_USER" && "$RESTORE_NONINTERACTIVE" != "1" ]]; then
  echo ""
  echo "Owner (user) for restored files — new machine may use a different user."
  read -p "Owner user [e.g. user2]: " NEW_USER
  NEW_USER="$(echo "$NEW_USER" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

# --- Owner (group) ---
NEW_GROUP="$RESTORE_OWNER_GROUP"
if [[ -z "$NEW_GROUP" && "$RESTORE_NONINTERACTIVE" != "1" ]]; then
  echo ""
  echo "Owner (group) for restored files"
  read -p "Owner group [e.g. user1 or same as user]: " NEW_GROUP
  NEW_GROUP="$(echo "$NEW_GROUP" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

# --- Summary and confirm ---
echo ""
echo "--- Restore summary ---"
echo "  Backup file : $BACKUP_TAR"
echo "  Target      : $DEST"
echo "  Owner       : ${NEW_USER:-'(unchanged)'}"
echo "  Group       : ${NEW_GROUP:-'(unchanged)'}"
echo "  Run as root : $CAN_CHOWN (chown will ${CAN_CHOWN:+run} ${CAN_CHOWN:-be skipped})"
echo ""

if [[ "$RESTORE_NONINTERACTIVE" != "1" ]]; then
  read -p "Proceed? [Y/n] " -r
  if [[ -n "$REPLY" && "${REPLY,,}" != "y" && "${REPLY,,}" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Remove existing dir if present
if [[ -d "$DEST" ]]; then
  echo "Removing existing $DEST ..."
  rm -rf "$DEST"
fi

echo "Extracting..."
tar -xzf "$BACKUP_TAR" -C "$TARGET_PARENT"

if [[ ! -d "$DEST" ]]; then
  echo "Error: expected $DEST after extract (tarball may have different structure)"
  exit 1
fi

echo "Setting execute permission on scripts..."
chmod +x "$DEST"/*.sh 2>/dev/null || true

# chown entire restored tree
if [[ -n "$NEW_USER" || -n "$NEW_GROUP" ]]; then
  if $CAN_CHOWN; then
    if [[ -n "$NEW_USER" && -z "$NEW_GROUP" ]]; then
      NEW_GROUP="$NEW_USER"
    elif [[ -z "$NEW_USER" && -n "$NEW_GROUP" ]]; then
      NEW_USER="$NEW_GROUP"
    fi
    echo "Setting owner to $NEW_USER:$NEW_GROUP ..."
    if chown -R "$NEW_USER:$NEW_GROUP" "$DEST" 2>/dev/null; then
      echo "  chown done."
    else
      echo "  Warning: chown failed (user/group may not exist). Run later: sudo chown -R $NEW_USER:$NEW_GROUP $DEST"
    fi
  else
    echo "Skipping chown (not root). Run later: sudo chown -R $NEW_USER:$NEW_GROUP $DEST"
  fi
fi

echo ""
echo "--- Restore done ---"
echo "  Restored to: $DEST"
echo "  Owner       : ${NEW_USER:-unchanged} ${NEW_GROUP:+($NEW_GROUP)}"
echo ""
echo "Checklist before starting Web container:"
echo "  1. Edit web.config.json if paths/hosts changed (gen.rootDir, gen.kubeconfigPath, etc.)"
echo "  2. Edit podman_runconfig.sh ROOT if not using $DEST"
echo "  3. Copy .kube to $DEST/.kube if using ocAutoLogin"
echo "  4. Load image: podman load -i confluent-kafka-user-management-*.tar"
echo "  5. Run (as owner user): cd $DEST && ./podman_runconfig.sh"
echo ""
if [[ -f "$DEST/MIGRATE_MANIFEST.txt" ]]; then
  echo "See also: $DEST/MIGRATE_MANIFEST.txt"
fi
