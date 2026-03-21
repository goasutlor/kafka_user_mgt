#!/bin/bash
# เทส oc + kubeconfig ตาม web.config.json (ทุก site) — รันบน host ก่อน deploy
# ไม่ต้องรัน container; ถ้า PASS แปลว่า credentials ใช้ได้ ถ้า deploy ไป GET /api/users ควรได้
#
# ใช้:
#   ./scripts/check-oc-users-from-config.sh
#   ./scripts/check-oc-users-from-config.sh /path/to/web.config.json
#
# ต้องมี: oc, jq

CONFIG="${1:-}"
for cand in "$CONFIG" "$CONFIG_PATH" "webapp/config/web.config.json" "config/web.config.json"; do
  [[ -n "$cand" && -r "$cand" ]] && CONFIG="$cand" && break
done
if [[ ! -r "$CONFIG" ]]; then
  echo "Usage: $0 [path/to/web.config.json]"
  echo "  หรือ set CONFIG_PATH แล้วรัน $0"
  echo "  ต้องมี jq และ oc"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "[FAIL] ไม่พบ jq — ติดตั้งก่อน (apt install jq / yum install jq)"
  exit 1
fi
if ! command -v oc &>/dev/null; then
  echo "[FAIL] ไม่พบ oc — ติดตั้ง OpenShift CLI ก่อน"
  exit 1
fi

KUBE=$(jq -r '.gen.kubeconfigPath // empty' "$CONFIG")
SECRET=$(jq -r '.gen.k8sSecretName // "kafka-server-side-credentials"' "$CONFIG")
SITES_JSON=$(jq -c '.gen.sites // [{name: "default", namespace: .gen.namespace, ocContext: .gen.ocContext}] | if length == 0 then [{name: "default", namespace: .gen.namespace, ocContext: .gen.ocContext}] else . end' "$CONFIG" 2>/dev/null)
if [[ -z "$SITES_JSON" || "$SITES_JSON" == "null" ]]; then
  NS=$(jq -r '.gen.namespace // "esb-prod-cwdc"' "$CONFIG")
  CTX=$(jq -r '.gen.ocContext // "cwdc"' "$CONFIG")
  SITES_JSON="[{\"name\":\"default\",\"namespace\":\"$NS\",\"ocContext\":\"$CTX\"}]"
fi

if [[ -z "$KUBE" || "$KUBE" == "null" ]]; then
  echo "[FAIL] ใน $CONFIG ไม่มี gen.kubeconfigPath"
  exit 1
fi
if [[ ! -r "$KUBE" ]]; then
  echo "[FAIL] ไฟล์ kubeconfig อ่านไม่ได้: $KUBE"
  echo "   รันจาก host ที่มี path นี้ (หรือ path ที่ mount เข้า container)"
  exit 1
fi

echo ""
echo "--- Shell test: oc get secret (ตาม web.config.json) — ก่อน deploy ---"
echo "   config: $CONFIG"
echo "   kubeconfig: $KUBE"
echo "   secret: $SECRET"
echo ""

PASS=0
FAIL=0
FAILED_SITES=()

# รายการ sites จาก jq
idx=0
while true; do
  name=$(echo "$SITES_JSON" | jq -r ".[$idx].name // empty")
  [[ -z "$name" || "$name" == "null" ]] && break
  ns=$(echo "$SITES_JSON" | jq -r ".[$idx].namespace")
  ctx=$(echo "$SITES_JSON" | jq -r ".[$idx].ocContext")
  out=$(KUBECONFIG="$KUBE" oc get secret "$SECRET" -n "$ns" --context "$ctx" -o jsonpath='{.data.plain-users\.json}' 2>&1)
  code=$?
  if [[ $code -eq 0 && -n "$out" ]]; then
    echo "[PASS] Site $name ($ctx) — oc get secret ได้ (plain-users.json ความยาว ${#out})"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] Site $name ($ctx) — oc get secret ไม่ผ่าน"
    echo "   $(echo "$out" | head -3 | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
    FAILED_SITES+=("$name")
  fi
  idx=$((idx + 1))
done

echo ""
echo "--- Result: $PASS passed, $FAIL failed ---"
if [[ $FAIL -gt 0 ]]; then
  echo "   แก้: บน host รัน oc login ใหม่ให้ครบทุก context ที่ใช้ แล้วรันสคริปต์นี้ซ้ำ (ดู ADD-USER-TROUBLESHOOT.md § provide credentials)"
fi
if [[ $PASS -gt 0 ]]; then
  echo "   ถ้า deploy/restart container โดย mount kubeconfig นี้ GET /api/users ควรได้ (อย่างน้อยจาก site ที่ PASS)"
  exit 0
fi
exit 1
