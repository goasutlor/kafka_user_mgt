#!/usr/bin/env bash
# Wait for the latest "Docker — build & push GHCR" workflow run on a branch to finish, then print result.
# Requires: GitHub CLI (gh) — https://cli.github.com/ — and `gh auth login`
#
# Usage:
#   ./scripts/wait-ghcr-build.sh              # branch main, repo from GITHUB_REPO or default below
#   ./scripts/wait-ghcr-build.sh master
#   GITHUB_REPO=owner/name ./scripts/wait-ghcr-build.sh

set -euo pipefail

BRANCH="${1:-main}"
REPO="${GITHUB_REPO:-goasutlor/kafka_user_mgt}"
WORKFLOW="docker-ghcr.yml"
IMAGE="ghcr.io/goasutlor/kafka_user_mgt:latest"

if ! command -v gh >/dev/null 2>&1; then
  echo "Install GitHub CLI: https://cli.github.com/  then: gh auth login" >&2
  exit 1
fi

echo "Watching latest run: repo=$REPO workflow=$WORKFLOW branch=$BRANCH"
RUN_ID="$(gh run list --repo "$REPO" --workflow="$WORKFLOW" --branch="$BRANCH" --limit=1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  echo "No run found yet; waiting up to 120s for workflow to appear..."
  for _ in $(seq 1 24); do
    sleep 5
    RUN_ID="$(gh run list --repo "$REPO" --workflow="$WORKFLOW" --branch="$BRANCH" --limit=1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    if [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]]; then
      break
    fi
  done
fi
if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  echo "Could not find a workflow run. Push first, or open:" >&2
  echo "  https://github.com/$REPO/actions/workflows/$WORKFLOW" >&2
  exit 1
fi

echo "Run ID: $RUN_ID — streaming status..."
if gh run watch "$RUN_ID" --repo "$REPO" --exit-status; then
  echo ""
  echo "GHCR build finished successfully."
  echo "Pull: docker pull $IMAGE"
  exit 0
else
  echo ""
  echo "GHCR build failed. Logs: gh run view $RUN_ID --repo $REPO --log-failed" >&2
  exit 1
fi
