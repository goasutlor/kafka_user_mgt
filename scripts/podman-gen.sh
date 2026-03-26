#!/usr/bin/env bash
# Run bundled gen.sh in the app container via **podman exec** (same baseline env as the Portal).
# Use this from a git checkout on your workstation — do not copy scripts out of the image to ad-hoc paths.
#
# Usage:
#   ./scripts/podman-gen.sh
#   GEN_NONINTERACTIVE=1 GEN_MODE=2 GEN_KAFKA_USER=u GEN_TEST_PASS=p GEN_TOPIC_NAME=t ./scripts/podman-gen.sh
#
# Optional: CONTAINER_NAME, KUBECONFIG (inside-container path), GEN_BASE_DIR — see gen-in-container.sh
# For Docker instead of Podman, use ./scripts/gen-in-container.sh (auto-detects docker).

set -euo pipefail
export CTR_ENGINE=podman
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gen-in-container.sh" "$@"
