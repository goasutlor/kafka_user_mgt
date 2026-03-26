#!/usr/bin/env bash
# Run bundled gen.sh inside the running app container with the same baseline env
# the Web portal sets (PATH for host oc, KUBECONFIG + GEN_BASE_DIR under runtime).
#
# Prerequisite: container was started with the same volume layout as docker-compose.yml
# or ./container-run-config.sh — especially:
#   -v /usr/bin:/host/usr/bin:ro   (host oc)
#   - runtime -> /opt/kafka-usermgmt
#
# Usage (from host, with a git checkout — recommended):
#   ./scripts/podman-gen.sh              # Podman only
#   ./scripts/gen-in-container.sh        # Podman or Docker (auto)
#   GEN_NONINTERACTIVE=1 GEN_MODE=2 GEN_KAFKA_USER=u GEN_TEST_PASS=p GEN_TOPIC_NAME=t \
#     ./scripts/gen-in-container.sh
#
# Optional:
#   CONTAINER_NAME=kafka-user-mgmt   # default
#   CTR_ENGINE=podman|docker         # auto-detect if unset
#   KUBECONFIG=/opt/kafka-usermgmt/.kube/config-both   # inside-container path (default: .../config)
#   GEN_SKIP_PORTAL_PARITY=1         # skip auto default env / sites (use gen.sh defaults or your GEN_* only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

if ! "$CTR_ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
  echo "ERROR: container '$CONTAINER_NAME' is not running." >&2
  echo "  Start it with: ./container-run-config.sh  (or docker compose up -d)" >&2
  exit 1
fi

if ! "$CTR_ENGINE" exec "$CONTAINER_NAME" test -x /host/usr/bin/oc 2>/dev/null; then
  echo "ERROR: /host/usr/bin/oc not found or not executable inside '$CONTAINER_NAME'." >&2
  echo "  Portal works because Node runs in the same shell user; gen.sh still needs 'oc'." >&2
  echo "  Fix: recreate the container with host oc mounted, e.g." >&2
  echo "    -v /usr/bin:/host/usr/bin:ro" >&2
  echo "  See: docker-compose.yml volumes, or ./container-run-config.sh / ./podman-run-config.sh" >&2
  exit 1
fi

Kube_in_container="${KUBECONFIG:-/opt/kafka-usermgmt/.kube/config}"
Base_dir="${GEN_BASE_DIR:-/opt/kafka-usermgmt}"

exec_args=(
  -e "PATH=/usr/local/bin:/usr/bin:/bin:/host/usr/bin"
  -e "GEN_OC_PATH=/host/usr/bin/oc"
  -e "KUBECONFIG=${Kube_in_container}"
  -e "GEN_BASE_DIR=${Base_dir}"
)

# Forward any GEN_* variables exported on the host into the container (CLI parity with manual exec).
while IFS= read -r name; do
  [[ -n "${name:-}" ]] || continue
  [[ "$name" == GEN_* ]] || continue
  v="${!name}"
  [[ -n "$v" ]] || continue
  exec_args+=(-e "${name}=${v}")
done < <(compgen -e | grep '^GEN_' || true)

# Source portal-parity-env.sh inside container so CLI matches Portal default environment (dev/sit/uat)
# when GEN_OCP_SITES is unset — same core as Web (environments.json + master.config).
exec "$CTR_ENGINE" exec -it "${exec_args[@]}" "$CONTAINER_NAME" \
  bash -c 'source /app/host-cli/portal-parity-env.sh 2>/dev/null || true; exec /app/bundled-gen/gen.sh "$@"' _ "$@"
