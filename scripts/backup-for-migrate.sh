#!/usr/bin/env bash
# =============================================================================
# Backup for Migrate — Run on source machine to collect everything for restore on new machine.
# Structure per clarify_folder.txt / production:
#   - confluent-usermanagement.sh (main script)
#   - podman_runconfig.sh
#   - certs/, configs/, Docker/, user_output/, (optional) kafka_2.13-3.6.1/
# Usage: ./backup-for-migrate.sh [BASE_DIR] [OUTPUT_TAR]
#        BASE_DIR  = kafka-usermgmt folder (default: /opt/kafka-usermgmt or $PWD)
#        OUTPUT_TAR = path of .tar.gz to create (default: kafka-usermgmt-migrate-YYYYMMDD-HHMM.tar.gz)
# Include Kafka distro (large ~100MB+): INCLUDE_KAFKA_DIST=1 ./backup-for-migrate.sh ...
# Include .kube (kubeconfig for oc): INCLUDE_KUBE=1 ./backup-for-migrate.sh ...
# =============================================================================

set -e
export LANG=C

# Source folder (kafka-usermgmt)
BASE="${1:-${BASE:-/opt/kafka-usermgmt}}"
BASE="$(cd -P "$BASE" 2>/dev/null && pwd)" || { echo "Error: BASE dir not found: $BASE"; exit 1; }

# Output file
STAMP=$(date +%Y%m%d-%H%M)
DEFAULT_OUTPUT="kafka-usermgmt-migrate-${STAMP}.tar.gz"
OUTPUT="${2:-${OUTPUT:-$DEFAULT_OUTPUT}}"
if [[ "$OUTPUT" != /* ]]; then
  OUTPUT="$(pwd)/$OUTPUT"
fi

# Include Kafka distro (kafka_2.13-3.6.1) or not — large; skip if new machine already has it
INCLUDE_KAFKA_DIST="${INCLUDE_KAFKA_DIST:-0}"
# Include .kube (kubeconfig) — contains credentials, use with care
INCLUDE_KUBE="${INCLUDE_KUBE:-0}"

echo "Backup for migrate"
echo "  BASE  = $BASE"
echo "  OUTPUT= $OUTPUT"
echo "  INCLUDE_KAFKA_DIST = $INCLUDE_KAFKA_DIST"
echo "  INCLUDE_KUBE       = $INCLUDE_KUBE"
echo ""

# Check required files/dirs exist
REQUIRED=(
  "confluent-usermanagement.sh"
  "podman_runconfig.sh"
  "configs"
  "Docker"
)
MISSING=()
for f in "${REQUIRED[@]}"; do
  [[ -e "$BASE/$f" ]] || MISSING+=("$f")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Warning: missing in BASE: ${MISSING[*]}"
  echo "  (If using different names e.g. gen.sh instead of confluent-usermanagement.sh, copy/link first then run backup)"
  read -p "Continue anyway? [y/N] " -r
  [[ "${REPLY,,}" == "y" ]] || exit 1
fi

# Create temp dir and copy (preserve structure)
TMPD=$(mktemp -d)
trap "rm -rf '$TMPD'" EXIT INT TERM

mkdir -p "$TMPD/kafka-usermgmt"
cd "$BASE"

# 1) Main scripts — names on production
for script in confluent-usermanagement.sh podman_runconfig.sh; do
  if [[ -f "$script" ]]; then
    cp -a "$script" "$TMPD/kafka-usermgmt/"
  fi
done
# If only gen.sh / podman-run-config.sh (repo names) exist, copy as names expected on new machine
if [[ -f "gen.sh" && ! -f "$TMPD/kafka-usermgmt/confluent-usermanagement.sh" ]]; then
  cp -a "gen.sh" "$TMPD/kafka-usermgmt/confluent-usermanagement.sh"
fi
if [[ -f "podman-run-config.sh" && ! -f "$TMPD/kafka-usermgmt/podman_runconfig.sh" ]]; then
  cp -a "podman-run-config.sh" "$TMPD/kafka-usermgmt/podman_runconfig.sh"
fi

# 2) certs/
if [[ -d "certs" ]]; then
  cp -a certs "$TMPD/kafka-usermgmt/"
fi

# 3) configs/ (kafka-client-master.properties is primary)
if [[ -d "configs" ]]; then
  cp -a configs "$TMPD/kafka-usermgmt/"
fi

# 4) Docker/ (web.config.json, auth-users.json, audit.log, download-history.json, ssl/)
if [[ -d "Docker" ]]; then
  mkdir -p "$TMPD/kafka-usermgmt/Docker"
  for f in web.config.json auth-users.json audit.log download-history.json; do
    [[ -f "Docker/$f" ]] && cp -a "Docker/$f" "$TMPD/kafka-usermgmt/Docker/"
  done
  if [[ -d "Docker/ssl" ]]; then
    cp -a Docker/ssl "$TMPD/kafka-usermgmt/Docker/"
  fi
fi

# 5) user_output/ (*.enc)
if [[ -d "user_output" ]]; then
  cp -a user_output "$TMPD/kafka-usermgmt/"
fi

# 6) *.enc at root
shopt -s nullglob
for enc in *.enc; do
  cp -a "$enc" "$TMPD/kafka-usermgmt/"
done
shopt -u nullglob

# 7) (Optional) kafka_2.13-3.6.1/
if [[ "$INCLUDE_KAFKA_DIST" == "1" && -d "kafka_2.13-3.6.1" ]]; then
  echo "  Including kafka_2.13-3.6.1 (may take a while)..."
  cp -a kafka_2.13-3.6.1 "$TMPD/kafka-usermgmt/"
fi

# 8) (Optional) .kube — kubeconfig for oc login
if [[ "$INCLUDE_KUBE" == "1" && -d ".kube" ]]; then
  echo "  Including .kube (kubeconfig)..."
  cp -a .kube "$TMPD/kafka-usermgmt/"
fi

# Manifest for Restore
cat > "$TMPD/kafka-usermgmt/MIGRATE_MANIFEST.txt" << EOF
Backup for migrate — created $(date -Iseconds 2>/dev/null || date)
BASE on source: $BASE
INCLUDE_KAFKA_DIST: $INCLUDE_KAFKA_DIST
INCLUDE_KUBE: $INCLUDE_KUBE

Contents (expected):
  confluent-usermanagement.sh   — main script (or gen.sh in repo)
  podman_runconfig.sh           — run container (or podman-run-config.sh in repo)
  certs/                         — ca-bundle.crt, kafka-truststore.jks
  configs/                       — kafka-client-master.properties (primary), kafka-client*.properties
  Docker/
    web.config.json
    auth-users.json
    audit.log
    download-history.json
    ssl/ (server.crt, server.key)
  user_output/                   — generated *.enc
  *.enc (at root if any)
  .kube/ (if INCLUDE_KUBE=1)     — kubeconfig for oc

Restore on new machine:
  1. Unpack: tar -xzf <this-backup>.tar.gz -C /opt  # yields /opt/kafka-usermgmt
  2. chmod +x /opt/kafka-usermgmt/*.sh
  3. Edit web.config.json if paths/hosts changed (gen.rootDir, gen.kubeconfigPath, etc.)
  4. Copy .kube (kubeconfig) to same path relative to ROOT if using ocAutoLogin (e.g. ROOT/.kube)
  5. Load image: podman load -i confluent-kafka-user-management-*.tar
  6. Run: cd /opt/kafka-usermgmt && ./podman_runconfig.sh
EOF

# Create tarball
echo "Creating tarball..."
cd "$TMPD"
tar -czf "$OUTPUT" kafka-usermgmt
echo "Done: $OUTPUT"
echo ""
echo "Next: copy this file to the new machine and run restore (see scripts/restore-migrate.sh or MIGRATE.md)"
