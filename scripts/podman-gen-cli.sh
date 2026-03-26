#!/usr/bin/env bash
# Interactive menu + optional environment lock (Portal parity) using **podman exec** only.
# Wraps gen-cli.sh with CTR_ENGINE=podman so behaviour matches production Podman deployments.
#
# Usage:
#   ./scripts/podman-gen-cli.sh                 # menu; option 6 picks environment
#   ./scripts/podman-gen-cli.sh <environment-id>  # lock to master.config environments[].id, then menu
#
# Requires: same container/volume layout as gen-in-container.sh (host oc mounted, runtime at GEN_BASE_DIR).

set -euo pipefail
export CTR_ENGINE=podman
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gen-cli.sh" "$@"
