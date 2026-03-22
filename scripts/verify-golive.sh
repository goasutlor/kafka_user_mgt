#!/usr/bin/env bash
# =============================================================================
# Go-Live readiness verification — OC, Kafka, every configured namespace, optional Portal HTTP
# =============================================================================
# รายงานแบบละเอียด: แต่ละบรรทัด [PASS] / [FAIL] / [WARN] พร้อมคำแนะนำแก้ไข
#
# วิธีใช้:
#   1) จากโฟลเดอร์โปรเจกต์ (มี master.config.json):
#        ./scripts/verify-golive.sh --config deploy/config/master.config.json
#        ./scripts/verify-golive.sh --config /path/to/master.config.json --portal-url https://host:3443
#
#   2) ส่งต่อจาก gen.sh (เมนู [7] หรือ GEN_MODE=7) — ใช้ env ที่ gen ตั้งแล้ว:
#        ./scripts/verify-golive.sh --from-gen-env
#
#   3) ตั้ง env เอง (helper node เดียวกับที่รัน gen.sh):
#        export GEN_BASE_DIR=/opt/kafka-usermgmt GEN_OCP_SITES=cwdc:ns1,tls2:ns2
#        export GEN_CLIENT_CONFIG=... GEN_ADMIN_CONFIG=... GEN_K8S_SECRET_NAME=...
#        ./scripts/verify-golive.sh
#
# ตัวเลือก:
#   --json              พิมพ์บรรทัด NDJSON (id, level, message) + บรรทัดสุดท้าย summary
#   --quick             โหมดเร็ว: ข้าม kafka-acls --list (ผลลัพธ์ใหญ่) และบางเช็คเสริม
#   --npm-audit         รัน npm audit --omit=dev (webapp) ถ้ามี npm
#   --with-api-smoke    เรียก POST cleanup-acl (ตรวจว่า backend เรียก gen ได้)
#   --no-portal         ไม่เรียก HTTP แม้มี --portal-url
#   --portal-url URL    ทดสอบ API แบบขนาน + HTTP security headers + path traversal + validation POSTs
#
# Exit code: 0 = ไม่มี FAIL (อาจมี WARN), 1 = มีอย่างน้อยหนึ่ง FAIL
# =============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JSON_MODE=false
FROM_GEN=false
MASTER_CONFIG=""
PORTAL_URL=""
NO_PORTAL=false
QUICK_MODE=false
NPM_AUDIT=false
API_SMOKE=false
TIMEOUT_SEC="${GOLIVE_TIMEOUT_SEC:-25}"
OCP_TIMEOUT="${GOLIVE_OCP_TIMEOUT:-20}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_MODE=true; shift ;;
    --from-gen-env) FROM_GEN=true; shift ;;
    --config) MASTER_CONFIG="$2"; shift 2 ;;
    --portal-url) PORTAL_URL="$2"; shift 2 ;;
    --no-portal) NO_PORTAL=true; shift ;;
    --quick) QUICK_MODE=true; shift ;;
    --npm-audit) NPM_AUDIT=true; shift ;;
    --with-api-smoke) API_SMOKE=true; shift ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | head -40
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$NO_PORTAL" == true ]]; then
  PORTAL_URL=""
fi

# --- output helpers ---
emit_json() {
  [[ "$JSON_MODE" != true ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -nc --arg id "$1" --arg level "$2" --arg msg "$3" '{id:$id,level:$level,message:$msg}'
}

pass() {
  local id="$1" msg="$2"
  echo "[PASS] $msg"
  PASS_COUNT=$((PASS_COUNT + 1))
  emit_json "$id" "pass" "$msg"
}

fail() {
  local id="$1" msg="$2"
  echo "[FAIL] $msg" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
  emit_json "$id" "fail" "$msg"
}

warn() {
  local id="$1" msg="$2"
  echo "[WARN] $msg"
  WARN_COUNT=$((WARN_COUNT + 1))
  emit_json "$id" "warn" "$msg"
}

section() {
  [[ "$JSON_MODE" == true ]] && return 0
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

remediate_oc() {
  echo "        → แก้: oc login --server=... ; ตรวจ KUBECONFIG ; context ต้องตรงกับ oc config get-contexts"
}

remediate_kafka() {
  echo "        → แก้: bootstrap ใน config, admin .properties (SASL/TLS), ssl.truststore.location ต้องชี้ไฟล์ที่ container/host เห็น, เครือข่ายถึง broker"
}

# --- load configuration ---
BASE_DIR=""
CLIENT_CONFIG=""
ADMIN_CONFIG=""
KAFKA_BIN=""
K8S_SECRET_NAME="kafka-server-side-credentials"
BOOTSTRAP_PRIMARY=""
BOOTSTRAP_BOTH=""
ENV_JSON_PATH=""
ALL_PAIRS_FILE="$(mktemp)"
CTX_UNIQUE="$(mktemp)"
PORTAL_WORK=""
cleanup_golive() {
  rm -f "$ALL_PAIRS_FILE" "$CTX_UNIQUE"
  [[ -n "${PORTAL_WORK}" && -d "${PORTAL_WORK}" ]] && rm -rf "${PORTAL_WORK}"
}
trap cleanup_golive EXIT

expand_rt() {
  local s="$1" rt="$2"
  echo "${s//\{runtimeRoot\}/$rt}"
}

if [[ -n "$MASTER_CONFIG" ]]; then
  [[ -f "$MASTER_CONFIG" ]] || { echo "Config file not found: $MASTER_CONFIG" >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "jq required for --config" >&2; exit 2; }
  RT=$(jq -r '.runtimeRoot // empty' "$MASTER_CONFIG")
  [[ -n "$RT" ]] || { echo "master.config.json missing runtimeRoot" >&2; exit 2; }
  cf=$(jq -r '.kafka.clientPropertiesFile // "kafka-client.properties"' "$MASTER_CONFIG")
  af=$(jq -r '.kafka.adminPropertiesFile // "kafka-client-master.properties"' "$MASTER_CONFIG")
  kd=$(jq -r '.kafka.clientInstallDir // "kafka_2.13-3.6.1"' "$MASTER_CONFIG")
  BASE_DIR="$RT"
  CLIENT_CONFIG="$RT/configs/$cf"
  ADMIN_CONFIG="$RT/configs/$af"
  KAFKA_BIN="$RT/$kd/bin"
  K8S_SECRET_NAME=$(jq -r '.kafka.k8sSecretName // "kafka-server-side-credentials"' "$MASTER_CONFIG")
  BOOTSTRAP_PRIMARY=$(jq -r '.kafka.bootstrapServers // empty' "$MASTER_CONFIG")
  BOOTSTRAP_BOTH="$BOOTSTRAP_PRIMARY"
  kc_tpl=$(jq -r '.oc.kubeconfig // "{runtimeRoot}/.kube/config-both"' "$MASTER_CONFIG")
  KUBECONFIG_DISCOVER=$(expand_rt "$kc_tpl" "$RT")
  [[ -n "${KUBECONFIG:-}" ]] || export KUBECONFIG="$KUBECONFIG_DISCOVER"
  jq -r '
    [ .fallbackSites[]? | select(.ocContext != null and .ocContext != "" and .namespace != null and .namespace != "") | "\(.ocContext)|\(.namespace)" ]
    + [ .environments.environments[]? | .sites[]? | select(.ocContext != null and .namespace != null) | "\(.ocContext)|\(.namespace)" ]
    | unique | .[]
  ' "$MASTER_CONFIG" 2>/dev/null > "$ALL_PAIRS_FILE" || true
  ENV_JSON_PATH="$RT/environments.json"
elif [[ "$FROM_GEN" == true ]]; then
  BASE_DIR="${GEN_BASE_DIR:-$PROJECT_ROOT}"
  CLIENT_CONFIG="${GEN_CLIENT_CONFIG:-$BASE_DIR/configs/kafka-client.properties}"
  ADMIN_CONFIG="${GEN_ADMIN_CONFIG:-$BASE_DIR/configs/kafka-client-master.properties}"
  KAFKA_BIN="${GEN_KAFKA_BIN:-$BASE_DIR/kafka_2.13-3.6.1/bin}"
  K8S_SECRET_NAME="${GEN_K8S_SECRET_NAME:-kafka-server-side-credentials}"
  BOOTSTRAP_PRIMARY="${GEN_VERIFY_BOOTSTRAP_CWDC:-${BOOTSTRAP_CWDC:-}}"
  BOOTSTRAP_BOTH="${GEN_VERIFY_BOOTSTRAP_BOTH:-$BOOTSTRAP_PRIMARY}"
  ENV_JSON_PATH="${GEN_ENVIRONMENTS_JSON:-$BASE_DIR/environments.json}"
  : > "$ALL_PAIRS_FILE"
  if [[ -n "${GEN_OCP_SITES:-}" ]]; then
    while IFS= read -r -d ',' chunk; do
      chunk=$(echo "$chunk" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -z "$chunk" ]] && continue
      c="${chunk%%:*}"; n="${chunk#*:}"
      echo "${c}|${n}" >> "$ALL_PAIRS_FILE"
    done <<< "${GEN_OCP_SITES},"
  fi
else
  BASE_DIR="${GEN_BASE_DIR:-$PROJECT_ROOT}"
  CLIENT_CONFIG="${GEN_CLIENT_CONFIG:-$BASE_DIR/configs/kafka-client.properties}"
  ADMIN_CONFIG="${GEN_ADMIN_CONFIG:-$BASE_DIR/configs/kafka-client-master.properties}"
  KAFKA_BIN="${GEN_KAFKA_BIN:-$BASE_DIR/kafka_2.13-3.6.1/bin}"
  K8S_SECRET_NAME="${GEN_K8S_SECRET_NAME:-kafka-server-side-credentials}"
  BOOTSTRAP_PRIMARY="${GEN_VERIFY_BOOTSTRAP_CWDC:-}"
  BOOTSTRAP_BOTH="${GEN_VERIFY_BOOTSTRAP_BOTH:-$BOOTSTRAP_PRIMARY}"
  ENV_JSON_PATH="${GEN_ENVIRONMENTS_JSON:-$BASE_DIR/environments.json}"
  : > "$ALL_PAIRS_FILE"
  if [[ -n "${GEN_OCP_SITES:-}" ]]; then
    while IFS= read -r -d ',' chunk; do
      chunk=$(echo "$chunk" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ -z "$chunk" ]] && continue
      c="${chunk%%:*}"; n="${chunk#*:}"
      echo "${c}|${n}" >> "$ALL_PAIRS_FILE"
    done <<< "${GEN_OCP_SITES},"
  fi
fi

# Merge pairs from environments.json (ทุก environment / ทุก site)
if [[ -f "$ENV_JSON_PATH" ]] && command -v jq >/dev/null 2>&1; then
  jq -r '.. | objects | select(has("ocContext") and has("namespace")) | "\(.ocContext)|\(.namespace)"' "$ENV_JSON_PATH" 2>/dev/null >> "$ALL_PAIRS_FILE" || true
fi

sort -u "$ALL_PAIRS_FILE" -o "$ALL_PAIRS_FILE"
PAIR_LINES=$(wc -l < "$ALL_PAIRS_FILE" 2>/dev/null | tr -d ' \r\n')
PAIR_LINES=${PAIR_LINES:-0}
[[ "${PAIR_LINES:-0}" -gt 0 ]] || warn "pairs_none" "ไม่พบคู่ context|namespace ใน config — ตั้ง GEN_OCP_SITES หรือใช้ --config master.config.json ที่มี fallbackSites/environments"

TOPICS_SH="$KAFKA_BIN/kafka-topics.sh"
ACLS_SH="$KAFKA_BIN/kafka-acls.sh"

[[ "$JSON_MODE" != true ]] && clear 2>/dev/null || true
[[ "$JSON_MODE" != true ]] && echo ""
[[ "$JSON_MODE" != true ]] && echo "╔══════════════════════════════════════════════════════════════════════╗"
[[ "$JSON_MODE" != true ]] && echo "║  Go-Live verification — Confluent Kafka User Management              ║"
[[ "$JSON_MODE" != true ]] && echo "╚══════════════════════════════════════════════════════════════════════╝"
[[ "$JSON_MODE" != true ]] && echo " BASE_DIR=$BASE_DIR"
[[ "$JSON_MODE" != true ]] && echo " K8S secret name: $K8S_SECRET_NAME"
[[ "$JSON_MODE" != true ]] && echo " Unique (context|namespace) pairs: ${PAIR_LINES:-0}"
[[ "$JSON_MODE" != true ]] && echo " KUBECONFIG=${KUBECONFIG:-<unset>}"

# --- Section: tools ---
section "1) เครื่องมือพื้นฐาน (jq, oc, timeout)"
if command -v jq >/dev/null 2>&1; then pass "tool_jq" "jq พร้อมใช้"; else fail "tool_jq" "ไม่พบ jq — ติดตั้ง jq แล้วรันใหม่"; fi
if command -v oc >/dev/null 2>&1; then pass "tool_oc" "oc CLI พร้อมใช้ ($(oc version --client 2>/dev/null | head -1 || echo ok))"; else fail "tool_oc" "ไม่พบ oc — ติดตั้ง OpenShift CLI"; fi
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then pass "tool_timeout" "timeout command พร้อม"; else warn "tool_timeout" "ไม่มี timeout (macOS: brew install coreutils) — บางเช็คอาจค้าง"; fi

# --- Section: files ---
section "2) ไฟล์ config และ Kafka binaries"
[[ -f "$CLIENT_CONFIG" ]] && pass "file_client_props" "Client properties: $CLIENT_CONFIG" || fail "file_client_props" "ไม่พบ client properties: $CLIENT_CONFIG — วางไฟล์ใต้ configs/ ตาม runtime root"
[[ -f "$ADMIN_CONFIG" ]] && pass "file_admin_props" "Admin properties: $ADMIN_CONFIG" || fail "file_admin_props" "ไม่พบ admin properties: $ADMIN_CONFIG — จำเป็นสำหรับ kafka-topics / kafka-acls"
[[ -f "$TOPICS_SH" ]] && pass "file_kafka_topics_sh" "kafka-topics.sh: $TOPICS_SH" || fail "file_kafka_topics_sh" "ไม่พบ $TOPICS_SH — ติดตั้ง Kafka ใต้ BASE_DIR หรือตั้ง GEN_KAFKA_BIN"
[[ -f "$ACLS_SH" ]] && pass "file_kafka_acls_sh" "kafka-acls.sh: $ACLS_SH" || warn "file_kafka_acls_sh" "ไม่พบ kafka-acls.sh — ตรวจ ACL จากเมนูจะใช้ไม่ได้"

if [[ -n "${KUBECONFIG:-}" ]]; then
  [[ -f "$KUBECONFIG" ]] && pass "file_kubeconfig" "Kubeconfig: $KUBECONFIG" || fail "file_kubeconfig" "KUBECONFIG ชี้ไฟล์ที่ไม่มี: $KUBECONFIG"
else
  warn "file_kubeconfig" "KUBECONFIG ยังไม่ตั้ง — oc จะใช้ default ~/.kube/config"
fi

# Truststore from admin props
if [[ -f "$ADMIN_CONFIG" ]]; then
  ts_line=$(grep -E '^[[:space:]]*ssl\.truststore\.location[[:space:]]*=' "$ADMIN_CONFIG" | head -1 || true)
  if [[ -n "$ts_line" ]]; then
    ts_path="${ts_line#*=}"
    ts_path=$(echo "$ts_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')
    [[ -f "$ts_path" ]] && pass "truststore_file" "Truststore มีอยู่: $ts_path" || fail "truststore_file" "Truststore ไม่พบที่ $ts_path (จาก admin properties) — คัดลอก .jks ให้ตรง path ที่ container เห็น"
  else
    warn "truststore_prop" "ไม่พบ ssl.truststore.location ใน admin properties (อาจเป็น PLAINTEXT หรือใช้ config อื่น)"
  fi
fi

# --- Section: Kafka ---
section "3) Kafka — bootstrap และสิทธิ์ admin"
if [[ -z "$BOOTSTRAP_PRIMARY" ]]; then
  fail "kafka_bootstrap_empty" "bootstrap servers ว่าง — ตั้งใน master.config / GEN_VERIFY_BOOTSTRAP_CWDC"
elif [[ -f "$TOPICS_SH" && -f "$ADMIN_CONFIG" ]]; then
  list_out=$(timeout "$TIMEOUT_SEC" "$TOPICS_SH" --bootstrap-server "$BOOTSTRAP_PRIMARY" --command-config "$ADMIN_CONFIG" --list 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    n=$(echo "$list_out" | grep -c . || true)
    pass "kafka_topics_list" "kafka-topics --list สำเร็จ (bootstrap: $BOOTSTRAP_PRIMARY, ~$n บรรทัด)"
  else
    fail "kafka_topics_list" "kafka-topics --list ล้มเหลว (exit $rc): $(echo "$list_out" | head -c 400 | tr '\n' ' ')"
    remediate_kafka
  fi
  # kafka-acls: หนักเมื่อ ACL เยอะ — ข้ามใน --quick
  if [[ "$QUICK_MODE" == true ]]; then
    warn "kafka_acls_skipped" "Quick mode: ข้าม kafka-acls --list (รันเต็มเมื่อไม่ใส่ --quick)"
  elif [[ -f "$ACLS_SH" ]]; then
    acl_out=$(timeout "$TIMEOUT_SEC" "$ACLS_SH" --bootstrap-server "$BOOTSTRAP_PRIMARY" --command-config "$ADMIN_CONFIG" --list 2>&1)
    rc2=$?
    if [[ $rc2 -eq 0 ]]; then
      pass "kafka_acls_list" "kafka-acls --list สำเร็จ (สิทธิ์อ่าน ACL ของ admin OK)"
    else
      warn "kafka_acls_list" "kafka-acls --list ล้มเหลว (exit $rc2): $(echo "$acl_out" | head -c 300 | tr '\n' ' ')"
      remediate_kafka
    fi
  fi
else
  warn "kafka_skip" "ข้าม Kafka live tests — ขาด script หรือ admin config"
fi

# --- Section: OpenShift — whoami/nodes ครั้งเดียวต่อ context; secret ทุกคู่ ctx|ns ---
section "4) OpenShift — (optimized) whoami+nodes ต่อ context แล้ว secret ทุก namespace"
if ! command -v oc >/dev/null 2>&1; then
  fail "oc_section_skip" "ไม่มี oc — ข้ามการตรวจทุก namespace (ติดตั้ง oc แล้วรันใหม่)"
else
  cut -d'|' -f1 "$ALL_PAIRS_FILE" 2>/dev/null | sort -u > "$CTX_UNIQUE"
  while IFS= read -r ctx; do
    [[ -z "$ctx" ]] && continue
    who_out=$(timeout "$OCP_TIMEOUT" oc whoami --context "$ctx" 2>&1)
    rcw=$?
    if [[ $rcw -eq 0 ]]; then
      pass "oc_ctx_${ctx}_whoami" "oc whoami OK (context=$ctx) → $who_out"
    else
      fail "oc_ctx_${ctx}_whoami" "oc whoami ล้มเหลว context=$ctx: $(echo "$who_out" | head -c 350 | tr '\n' ' ')"
      remediate_oc
    fi
    nodes_out=$(timeout "$OCP_TIMEOUT" oc get nodes --context "$ctx" -o name 2>&1)
    rcn=$?
    if [[ $rcn -eq 0 ]]; then
      pass "oc_ctx_${ctx}_nodes" "oc get nodes OK (context=$ctx)"
    else
      fail "oc_ctx_${ctx}_nodes" "oc get nodes ล้มเหลว context=$ctx: $(echo "$nodes_out" | head -c 300 | tr '\n' ' ')"
      remediate_oc
    fi
  done < "$CTX_UNIQUE"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ctx="${line%%|*}"
    ns="${line#*|}"
    [[ -z "$ctx" || -z "$ns" ]] && continue
    id_base="oc_${ctx}_${ns}"
    sec_out=$(timeout "$OCP_TIMEOUT" oc get secret "$K8S_SECRET_NAME" -n "$ns" --context "$ctx" -o name 2>&1)
    rcs=$?
    if [[ $rcs -eq 0 ]]; then
      pass "${id_base}_secret" "Secret $K8S_SECRET_NAME มีใน namespace $ns (context=$ctx)"
      pdata=$(timeout "$OCP_TIMEOUT" oc get secret "$K8S_SECRET_NAME" -n "$ns" --context "$ctx" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d 2>/dev/null)
      if [[ -n "$pdata" ]] && echo "$pdata" | jq empty 2>/dev/null; then
        nu=$(echo "$pdata" | jq 'keys | length' 2>/dev/null || echo "?")
        pass "${id_base}_plain_users" "plain-users.json อ่านได้และเป็น JSON (ประมาณ $nu keys)"
      else
        warn "${id_base}_plain_users" "secret มีแต่ดึง/แปลง plain-users.json ไม่ได้ — ตรวจ key plain-users.json และสิทธิ์"
      fi
    else
      fail "${id_base}_secret" "ไม่พบ secret $K8S_SECRET_NAME ใน namespace $ns (context=$ctx): $(echo "$sec_out" | head -c 300 | tr '\n' ' ')"
      echo "        → แก้: ตรวจชื่อ secret (k8sSecretName), namespace ต่อ environment, และว่า Confluent สร้าง secret นี้แล้ว"
    fi
  done < "$ALL_PAIRS_FILE"
fi

# --- Section: Portal HTTP (parallel JSON APIs + security probes) ---
if [[ -n "$PORTAL_URL" ]]; then
  section "5) Web Portal — API แบบขนาน + HTTP security + validation routes — $PORTAL_URL"
  CURL_K=""
  [[ "$PORTAL_URL" == https://* ]] && CURL_K="-k"
  if command -v curl >/dev/null 2>&1; then
    PORTAL_WORK=$(mktemp -d)
    base="${PORTAL_URL%/}"
    golive_fetch() {
      local path="$1" name="$2" maxt="$3" c
      c=$(curl -sS -m "$maxt" $CURL_K -o "$PORTAL_WORK/${name}.json" -w "%{http_code}" "${base}${path}" 2>/dev/null) || c=000
      echo "${c:-000}" > "$PORTAL_WORK/${name}.code"
    }
    golive_fetch /api/version v 22 &
    golive_fetch /api/config c 22 &
    golive_fetch /api/setup/status st 22 &
    golive_fetch /api/topics t 35 &
    golive_fetch /api/users u 35 &
    wait

    read -r _vc < "$PORTAL_WORK/v.code"
    if [[ "$_vc" == "200" ]]; then pass "http_version" "GET /api/version → 200 (parallel fetch)"; else fail "http_version" "GET /api/version → HTTP ${_vc}"; fi
    read -r _cc < "$PORTAL_WORK/c.code"
    if [[ "$_cc" == "200" ]]; then pass "http_config" "GET /api/config → 200"; else fail "http_config" "GET /api/config → HTTP ${_cc}"; fi
    read -r _stc < "$PORTAL_WORK/st.code"
    if [[ "$_stc" == "200" ]] && grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$PORTAL_WORK/st.json" 2>/dev/null; then
      pass "http_setup_status" "GET /api/setup/status → 200 ok:true"
    else
      fail "http_setup_status" "GET /api/setup/status → HTTP ${_stc} หรือไม่มี ok:true"
    fi
    read -r _tc < "$PORTAL_WORK/t.code"
    if [[ "$_tc" == "200" ]] && grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$PORTAL_WORK/t.json" 2>/dev/null; then
      pass "http_topics" "GET /api/topics → 200 ok:true"
    else
      fail "http_topics" "GET /api/topics → HTTP ${_tc} หรือ ok ไม่เป็น true"
    fi
    read -r _uc < "$PORTAL_WORK/u.code"
    if [[ "$_uc" == "200" ]] && grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$PORTAL_WORK/u.json" 2>/dev/null; then
      pass "http_users" "GET /api/users → 200 ok:true"
    else
      fail "http_users" "GET /api/users → HTTP ${_uc} หรือ ok ไม่เป็น true"
    fi

    if [[ "$QUICK_MODE" != true ]]; then
      section "5b) HTTP security headers (หน้าแรก)"
      hdr=$(curl -sI -m 15 $CURL_K "$base/" 2>/dev/null || true)
      echo "$hdr" | grep -qi 'x-frame-options:' && pass "sec_x_frame" "X-Frame-Options พร้อมบน /" || warn "sec_x_frame" "ไม่พบ X-Frame-Options บน / — ลด clickjacking risk"
      echo "$hdr" | grep -qi 'x-content-type-options:' && pass "sec_nosniff" "X-Content-Type-Options พร้อม" || warn "sec_nosniff" "ไม่พบ X-Content-Type-Options — MIME sniffing risk"
      echo "$hdr" | grep -qi 'referrer-policy:' && pass "sec_referrer" "Referrer-Policy พร้อม" || warn "sec_referrer" "ไม่พบ Referrer-Policy"

      section "5c) Input / path safety (API)"
      pt=$(curl -sS -m 15 $CURL_K -o /dev/null -w "%{http_code}" "$base/api/download/../x" 2>/dev/null || echo 000)
      if [[ "$pt" == "400" || "$pt" == "404" ]]; then pass "sec_path_traversal" "GET /api/download path traversal → $pt (ปฏิเสธตามคาด)"; else fail "sec_path_traversal" "GET /api/download/../x → HTTP $pt (คาด 400 หรือ 404)"; fi
      pv=$(curl -sS -m 15 $CURL_K -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{}' "$base/api/add-user" 2>/dev/null || echo 000)
      [[ "$pv" == "400" ]] && pass "sec_add_user_validate" "POST /api/add-user {} → 400 validation" || warn "sec_add_user_validate" "POST /api/add-user {} → HTTP $pv (คาด 400)"
      ptst=$(curl -sS -m 15 $CURL_K -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{}' "$base/api/test-user" 2>/dev/null || echo 000)
      [[ "$ptst" == "400" ]] && pass "sec_test_user_validate" "POST /api/test-user {} → 400" || warn "sec_test_user_validate" "POST /api/test-user {} → HTTP $ptst"
    else
      warn "sec_skipped" "Quick mode: ข้าม security header และ path/validation probes"
    fi

    if [[ "$API_SMOKE" == true ]]; then
      section "5d) API smoke (backend → gen.sh)"
      sc=$(curl -sS -m 60 $CURL_K -o "$PORTAL_WORK/cl.json" -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{}' "$base/api/cleanup-acl" 2>/dev/null || echo 000)
      if [[ "$sc" == "200" || "$sc" == "500" ]]; then
        if grep -qE 'ENOENT|spawn bash|gen\.sh not found' "$PORTAL_WORK/cl.json" 2>/dev/null; then
          fail "api_gen_cleanup" "cleanup-acl: backend เรียก gen/bash ไม่ได้ — ตรวจ image และ scriptPath"
        else
          pass "api_gen_cleanup" "POST /api/cleanup-acl → $sc (backend รับและเรียกสคริปต์ได้)"
        fi
      else
        warn "api_gen_cleanup" "POST /api/cleanup-acl → HTTP $sc"
      fi
    fi
  else
    warn "http_curl" "ไม่มี curl — ข้ามการทดสอบ Portal"
  fi
else
  section "5) Web Portal"
  warn "http_skip" "ไม่ได้ส่ง --portal-url — ข้าม HTTP (แนะนำ: --portal-url + ./scripts/check-deployment.sh)"
fi

if [[ "$NPM_AUDIT" == true ]]; then
  section "6) npm audit (webapp — production deps)"
  WP="$PROJECT_ROOT/webapp"
  if command -v npm >/dev/null 2>&1 && [[ -f "$WP/package.json" ]]; then
    if npm audit --omit=dev --audit-level=high -C "$WP" >/dev/null 2>&1; then
      pass "npm_audit" "npm audit --omit=dev: ไม่มี high/critical (หรือ npm ผ่าน)"
    else
      warn "npm_audit" "npm audit พบช่องโหว่ระดับ high+ — รัน: cd webapp && npm audit (แก้ด้วย npm audit fix หรืออัปเดตแพ็กเกจ)"
      npm audit --omit=dev --audit-level=moderate -C "$WP" 2>&1 | head -n 40 | sed 's/^/   /' || true
    fi
  else
    warn "npm_audit_skip" "ไม่มี npm หรือ webapp/package.json — ข้าม npm audit"
  fi
fi

# --- Summary ---
section "สรุปผล"
echo ""
echo "  PASS: $PASS_COUNT"
echo "  WARN: $WARN_COUNT"
echo "  FAIL: $FAIL_COUNT"
echo ""

if [[ "$JSON_MODE" == true ]]; then
  ok_json="true"
  [[ $FAIL_COUNT -gt 0 ]] && ok_json="false"
  printf '{"type":"summary","pass":%d,"warn":%d,"fail":%d,"ok":%s}\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$ok_json"
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  [[ "$JSON_MODE" != true ]] && echo "❌ ยังไม่ควร Go-Live — แก้ FAIL ทั้งหมดแล้วรันสคริปต์นี้อีกครั้ง"
  exit 1
fi

[[ "$JSON_MODE" != true ]] && echo "✅ ไม่มี FAIL — ผ่านเกณฑ์ขั้นต่ำ (ตรวจ WARN ก่อนปล่อย production จริง)"
[[ "$JSON_MODE" != true ]] && echo "   แนะนำ: รัน ./scripts/check-deployment.sh <portal-url> และทดสอบ E2E ด้วยข้อมูลจริง (scripts/check-e2e.sh)"
exit 0
