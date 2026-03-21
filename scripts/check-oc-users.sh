#!/bin/bash
# เช็คสั้นๆ ว่า oc + kubeconfig + context พร้อมสำหรับ GET /api/users หรือยัง
# รันบนเครื่องที่จะรัน container (หรือเครื่องที่มี oc) ก่อนรัน check-deployment.sh
#
# ใช้:
#   ./scripts/check-oc-users.sh
#   ./scripts/check-oc-users.sh /opt/kafka-usermgmt/.kube/config
#   KUBECONFIG=/opt/kafka-usermgmt/.kube/config ./scripts/check-oc-users.sh
#
# ถ้าใช้ kubeconfig ของ user2 ให้ส่ง path มา หรือ set KUBECONFIG แล้วรัน
# ถ้า PASS ทั้งหมด แปลว่า config (gen.sites หรือ namespace/ocContext, kubeconfigPath) กับ kubeconfig ตรงกัน
# สำหรับหลาย cluster: ตั้ง GEN_SITES_JSON หรือรันเช็คต่อ context (สคริปต์นี้เช็คแค่ 1 context ตาม GEN_NAMESPACE/GEN_OC_CONTEXT)

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
  echo "[FAIL] ไฟล์ kubeconfig อ่านไม่ได้หรือไม่มี: $KUBE"
  echo "   ถ้ารัน container ด้วย root แต่ใช้ kubeconfig ของ user2 ให้รัน:"
  echo "     ./scripts/check-oc-users.sh /opt/kafka-usermgmt/.kube/config"
  echo "   และตอนรัน container เมื่อ .kube อยู่ใต้ ROOT ไม่ต้อง mount แยก; ถ้าอยู่นอก ROOT ใช้ -v KUBE_DIR:ROOT/.kube-external:z"
  exit 1
fi
echo "[PASS] ไฟล์ kubeconfig อ่านได้"
PASS=$((PASS + 1))

# บาง oc เวอร์ชัน -o name อาจไม่มีหรือ format ต่างกัน เลยเช็คหลายแบบ
ctx_found=
if names=$(KUBECONFIG="$KUBE" oc config get-contexts -o name 2>/dev/null); then
  if echo "$names" | grep -Fxq "$CTX"; then
    ctx_found=1
  fi
fi
if [[ -z "$ctx_found" ]]; then
  # Fallback: จาก output ปกติ (คอลัมน์ NAME คือคอลัมน์ที่ 2)
  if KUBECONFIG="$KUBE" oc config get-contexts --no-headers 2>/dev/null | awk '{print $2}' | grep -Fxq "$CTX"; then
    ctx_found=1
  fi
fi
if [[ -z "$ctx_found" ]]; then
  echo "[FAIL] ใน kubeconfig นี้ไม่มี context ชื่อ \"$CTX\""
  echo "   รายการ context ที่เห็น (oc config get-contexts -o name):"
  KUBECONFIG="$KUBE" oc config get-contexts -o name 2>/dev/null | sed 's/^/     /' || true
  echo "   หรือรัน: KUBECONFIG=$KUBE oc config get-contexts"
  echo "   แล้วแก้ web.config.json ให้ gen.sites (หรือ gen.ocContext) ตรงกับชื่อ context ใน list ด้านบน"
  echo ""
  echo "   ถ้าไฟล์นี้เป็นของ user2 แต่คุณรันสคริปต์ด้วย root: oc อาจ merge กับ /root/.kube/config ทำให้รายการไม่ตรง."
  echo "   แนะนำ: รันสคริปต์เป็น user2 หรือให้ user2 รัน container (ดู RUN-AFTER-LOAD.md § ให้ user2 รัน container บนพอร์ต 443)"
  FAIL=$((FAIL + 1))
else
  echo "[PASS] มี context \"$CTX\""
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
  echo "[FAIL] oc get secret ไม่ผ่าน (exit $code)"
  echo "   $out"
  echo "   แก้ namespace/context/secret หรือสิทธิ์ oc ใน cluster"
  FAIL=$((FAIL + 1))
elif [[ -z "$out" ]]; then
  echo "[FAIL] secret มีแต่ค่า plain-users.json ว่างหรือไม่มี key"
  FAIL=$((FAIL + 1))
else
  echo "[PASS] oc get secret ... plain-users.json ได้ (ความยาว ${#out} ตัวอักษร)"
  PASS=$((PASS + 1))
fi

echo ""
echo "--- Result: $PASS passed, $FAIL failed ---"
if [[ $FAIL -eq 0 ]]; then
  echo "ถ้า container mount kubeconfig นี้และ config มี kubeconfigPath + gen.sites (หรือ namespace/ocContext) ตรงนี้ GET /api/users ควรผ่าน"
  exit 0
fi
exit 1
