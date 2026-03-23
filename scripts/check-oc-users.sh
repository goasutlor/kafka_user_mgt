#!/bin/bash
# Quick check: oc + kubeconfig + context ready for GET /api/users.
# Run on the host that will run the container (or any host with oc) before check-deployment.sh.
#
# Usage:
#   ./scripts/check-oc-users.sh
#   ./scripts/check-oc-users.sh /opt/kafka-usermgmt/.kube/config
#   KUBECONFIG=/opt/kafka-usermgmt/.kube/config ./scripts/check-oc-users.sh
#
# Pass kubeconfig path or set KUBECONFIG. If all PASS, config (gen.sites or namespace/ocContext, kubeconfigPath) matches this file.
# Multi-cluster: set GEN_SITES_JSON or run per-context (this script checks one context from GEN_NAMESPACE/GEN_OC_CONTEXT).

KUBE="${1:-${KUBECONFIG:-$HOME/.kube/config}}"
NS="${GEN_NAMESPACE:-esb-prod-cwdc}"
CTX="${GEN_OC_CONTEXT:-cwdc}"
SECRET="${GEN_K8S_SECRET:-kafka-server-side-credentials}"

PASS=0
FAIL=0

echo ""
echo "--- Check oc / kubeconfig for GET /api/users ---"
echo "   KUBECONFIG (or arg): $KUBE"
echo "   namespace: $NS  context: $CTX  secret: $SECRET"
echo ""

if [[ ! -r "$KUBE" ]]; then
  echo "[FAIL] kubeconfig not readable or missing: $KUBE"
  echo "   If the container runs as root but kubeconfig belongs to another user, run:"
  echo "     ./scripts/check-oc-users.sh /opt/kafka-usermgmt/.kube/config"
  echo "   When .kube is under ROOT, no extra mount; if outside ROOT use -v KUBE_DIR:ROOT/.kube-external:z"
  exit 1
fi
echo "[PASS] kubeconfig file readable"
PASS=$((PASS + 1))

# Some oc versions lack -o name or use different output — try both
ctx_found=
if names=$(KUBECONFIG="$KUBE" oc config get-contexts -o name 2>/dev/null); then
  if echo "$names" | grep -Fxq "$CTX"; then
    ctx_found=1
  fi
fi
if [[ -z "$ctx_found" ]]; then
  if KUBECONFIG="$KUBE" oc config get-contexts --no-headers 2>/dev/null | awk '{print $2}' | grep -Fxq "$CTX"; then
    ctx_found=1
  fi
fi
if [[ -z "$ctx_found" ]]; then
  echo "[FAIL] no context named \"$CTX\" in this kubeconfig"
  echo "   Contexts (oc config get-contexts -o name):"
  KUBECONFIG="$KUBE" oc config get-contexts -o name 2>/dev/null | sed 's/^/     /' || true
  echo "   Or: KUBECONFIG=$KUBE oc config get-contexts"
  echo "   Then align web.config.json gen.sites (or gen.ocContext) with a name from the list above"
  echo ""
  echo "   If this file is user A's but you run the script as root, oc may merge with /root/.kube/config."
  echo "   Prefer: run as that user, or have them run the container (see RUN-AFTER-LOAD.md)."
  FAIL=$((FAIL + 1))
else
  echo "[PASS] context \"$CTX\" present"
  PASS=$((PASS + 1))
fi

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "--- Result: $PASS passed, $FAIL failed ---"
  exit 1
fi

out=$(KUBECONFIG="$KUBE" oc get secret "$SECRET" -n "$NS" --context "$CTX" -o jsonpath='{.data.plain-users\.json}' 2>&1)
code=$?
if [[ $code -ne 0 ]]; then
  echo "[FAIL] oc get secret failed (exit $code)"
  echo "   $out"
  echo "   Fix namespace/context/secret or oc permissions on the cluster"
  FAIL=$((FAIL + 1))
elif [[ -z "$out" ]]; then
  echo "[FAIL] secret exists but plain-users.json empty or key missing"
  FAIL=$((FAIL + 1))
else
  echo "[PASS] oc get secret ... plain-users.json OK (length ${#out})"
  PASS=$((PASS + 1))
fi

echo ""
echo "--- Result: $PASS passed, $FAIL failed ---"
if [[ $FAIL -eq 0 ]]; then
  echo "If the container mounts this kubeconfig and config has matching kubeconfigPath + gen.sites, GET /api/users should work."
  exit 0
fi
exit 1
