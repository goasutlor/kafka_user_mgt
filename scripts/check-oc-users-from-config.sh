#!/bin/bash
# Test oc + kubeconfig from web.config.json (every site) — run on host before deploy.
# No container required; PASS means credentials work for a future GET /api/users.
#
# Usage:
#   ./scripts/check-oc-users-from-config.sh
#   ./scripts/check-oc-users-from-config.sh /path/to/web.config.json
#
# Requires: oc, jq

CONFIG="${1:-}"
for cand in "$CONFIG" "$CONFIG_PATH" "webapp/config/web.config.json" "config/web.config.json"; do
  [[ -n "$cand" && -r "$cand" ]] && CONFIG="$cand" && break
done
if [[ ! -r "$CONFIG" ]]; then
  echo "Usage: $0 [path/to/web.config.json]"
  echo "  Or set CONFIG_PATH and run $0"
  echo "  Requires jq and oc"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "[FAIL] jq not found — install (apt install jq / yum install jq)"
  exit 1
fi
if ! command -v oc &>/dev/null; then
  echo "[FAIL] oc not found — install OpenShift CLI"
  exit 1
fi

KUBE=$(jq -r '.gen.kubeconfigPath // empty' "$CONFIG")
SECRET=$(jq -r '.gen.k8sSecretName // "kafka-server-side-credentials"' "$CONFIG")
SITES_JSON=$(jq -c '.gen.sites // [{name: "default", namespace: .gen.namespace, ocContext: .gen.ocContext}] | if length == 0 then [{name: "default", namespace: .gen.namespace, ocContext: .gen.ocContext}] else . end' "$CONFIG" 2>/dev/null)
if [[ -z "$SITES_JSON" || "$SITES_JSON" == "null" ]]; then
  NS=$(jq -r '.gen.namespace // empty' "$CONFIG")
  CTX=$(jq -r '.gen.ocContext // empty' "$CONFIG")
  if [[ -z "$NS" || -z "$CTX" ]]; then
    echo "[FAIL] $CONFIG must define gen.sites[] or both gen.namespace and gen.ocContext (no legacy defaults)."
    exit 1
  fi
  SITES_JSON="[{\"name\":\"default\",\"namespace\":\"$NS\",\"ocContext\":\"$CTX\"}]"
fi

if [[ -z "$KUBE" || "$KUBE" == "null" ]]; then
  echo "[FAIL] $CONFIG missing gen.kubeconfigPath"
  exit 1
fi
if [[ ! -r "$KUBE" ]]; then
  echo "[FAIL] kubeconfig not readable: $KUBE"
  echo "   Run from a host where this path exists (or matches the container mount)"
  exit 1
fi

echo ""
echo "--- Shell test: oc get secret (from web.config.json) — before deploy ---"
echo "   config: $CONFIG"
echo "   kubeconfig: $KUBE"
echo "   secret: $SECRET"
echo ""

PASS=0
FAIL=0
FAILED_SITES=()

idx=0
while true; do
  name=$(echo "$SITES_JSON" | jq -r ".[$idx].name // empty")
  [[ -z "$name" || "$name" == "null" ]] && break
  ns=$(echo "$SITES_JSON" | jq -r ".[$idx].namespace")
  ctx=$(echo "$SITES_JSON" | jq -r ".[$idx].ocContext")
  out=$(KUBECONFIG="$KUBE" oc get secret "$SECRET" -n "$ns" --context "$ctx" -o jsonpath='{.data.plain-users\.json}' 2>&1)
  code=$?
  if [[ $code -eq 0 && -n "$out" ]]; then
    echo "[PASS] Site $name ($ctx) — oc get secret OK (plain-users.json length ${#out})"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] Site $name ($ctx) — oc get secret failed"
    echo "   $(echo "$out" | head -3 | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
    FAILED_SITES+=("$name")
  fi
  idx=$((idx + 1))
done

echo ""
echo "--- Result: $PASS passed, $FAIL failed ---"
if [[ $FAIL -gt 0 ]]; then
  echo "   Fix: oc login for every context, re-run (see ADD-USER-TROUBLESHOOT.md)"
fi
if [[ $PASS -gt 0 ]]; then
  echo "   After deploy with this kubeconfig mounted, GET /api/users should work for PASS sites"
  exit 0
fi
exit 1
