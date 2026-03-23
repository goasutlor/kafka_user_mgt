#!/usr/bin/env bash
# =============================================================================
# Go-Live readiness verification — OC, Kafka, every configured namespace, optional Portal HTTP
# =============================================================================
# Detailed output: each line [PASS] / [FAIL] / [WARN] with remediation hints
#
# Usage:
#   1) From project dir (with master.config.json):
#        ./scripts/verify-golive.sh --config deploy/config/master.config.json
#        ./scripts/verify-golive.sh --config /path/to/master.config.json --portal-url https://host:3443
#
#   2) From gen.sh (menu [7] or GEN_MODE=7) — uses env already set by gen:
#        ./scripts/verify-golive.sh --from-gen-env
#
#   3) Set env yourself (same helper node as gen.sh):
#        export GEN_BASE_DIR=/opt/kafka-usermgmt GEN_OCP_SITES=cwdc:ns1,tls2:ns2
#        export GEN_CLIENT_CONFIG=... GEN_ADMIN_CONFIG=... GEN_K8S_SECRET_NAME=...
#        ./scripts/verify-golive.sh
#
# Options:
#   --json              NDJSON lines (id, level, message) + final summary line
#   --quick             Fast mode: skip kafka-acls --list (large output) and some extra checks
#   --npm-audit         Run npm audit --omit=dev (webapp) if npm exists
#   --with-api-smoke    POST cleanup-acl (verify backend can invoke gen)
#   --no-portal         Do not call HTTP even if --portal-url is set
#   --portal-url URL    Parallel API tests + HTTP security headers + path traversal + validation POSTs
#
# Exit code: 0 = no FAIL (WARN allowed), 1 = at least one FAIL
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
  echo "        → Fix: oc login --server=... ; check KUBECONFIG ; context must match oc config get-contexts"
}

remediate_kafka() {
  echo "        → Fix: bootstrap in config, admin .properties (SASL/TLS), ssl.truststore.location must point to a file visible on container/host, network must reach brokers"
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
  kc_tpl=$(jq -r '.oc.kubeconfig // "{runtimeRoot}/.kube/config"' "$MASTER_CONFIG")
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

# Merge pairs from environments.json (every environment / every site)
if [[ -f "$ENV_JSON_PATH" ]] && command -v jq >/dev/null 2>&1; then
  jq -r '.. | objects | select(has("ocContext") and has("namespace")) | "\(.ocContext)|\(.namespace)"' "$ENV_JSON_PATH" 2>/dev/null >> "$ALL_PAIRS_FILE" || true
fi

sort -u "$ALL_PAIRS_FILE" -o "$ALL_PAIRS_FILE"
PAIR_LINES=$(wc -l < "$ALL_PAIRS_FILE" 2>/dev/null | tr -d ' \r\n')
PAIR_LINES=${PAIR_LINES:-0}
[[ "${PAIR_LINES:-0}" -gt 0 ]] || warn "pairs_none" "No context|namespace pairs in config — set GEN_OCP_SITES or use --config master.config.json with fallbackSites/environments"

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
section "1) Core tools (jq, oc, timeout)"
if command -v jq >/dev/null 2>&1; then pass "tool_jq" "jq available"; else fail "tool_jq" "jq not found — install jq and re-run"; fi
if command -v oc >/dev/null 2>&1; then pass "tool_oc" "oc CLI available ($(oc version --client 2>/dev/null | head -1 || echo ok))"; else fail "tool_oc" "oc not found — install OpenShift CLI"; fi
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then pass "tool_timeout" "timeout command available"; else warn "tool_timeout" "No timeout (macOS: brew install coreutils) — some checks may hang"; fi

# --- Section: files ---
section "2) Config files and Kafka binaries"
[[ -f "$CLIENT_CONFIG" ]] && pass "file_client_props" "Client properties: $CLIENT_CONFIG" || fail "file_client_props" "Missing client properties: $CLIENT_CONFIG — place file under configs/ per runtime root"
[[ -f "$ADMIN_CONFIG" ]] && pass "file_admin_props" "Admin properties: $ADMIN_CONFIG" || fail "file_admin_props" "Missing admin properties: $ADMIN_CONFIG — required for kafka-topics / kafka-acls"
[[ -f "$TOPICS_SH" ]] && pass "file_kafka_topics_sh" "kafka-topics.sh: $TOPICS_SH" || fail "file_kafka_topics_sh" "Not found: $TOPICS_SH — install Kafka under BASE_DIR or set GEN_KAFKA_BIN"
[[ -f "$ACLS_SH" ]] && pass "file_kafka_acls_sh" "kafka-acls.sh: $ACLS_SH" || warn "file_kafka_acls_sh" "kafka-acls.sh not found — menu ACL checks will not work"

if [[ -n "${KUBECONFIG:-}" ]]; then
  [[ -f "$KUBECONFIG" ]] && pass "file_kubeconfig" "Kubeconfig: $KUBECONFIG" || fail "file_kubeconfig" "KUBECONFIG points to missing file: $KUBECONFIG"
else
  warn "file_kubeconfig" "KUBECONFIG unset — oc will use default ~/.kube/config"
fi

# Truststore from admin props
if [[ -f "$ADMIN_CONFIG" ]]; then
  ts_line=$(grep -E '^[[:space:]]*ssl\.truststore\.location[[:space:]]*=' "$ADMIN_CONFIG" | head -1 || true)
  if [[ -n "$ts_line" ]]; then
    ts_path="${ts_line#*=}"
    ts_path=$(echo "$ts_path" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')
    [[ -f "$ts_path" ]] && pass "truststore_file" "Truststore present: $ts_path" || fail "truststore_file" "Truststore missing at $ts_path (from admin properties) — copy .jks to a path visible on container"
  else
    warn "truststore_prop" "ssl.truststore.location not found in admin properties (may be PLAINTEXT or other config)"
  fi
fi

# --- Section: Kafka ---
section "3) Kafka — bootstrap and admin permissions"
if [[ -z "$BOOTSTRAP_PRIMARY" ]]; then
  fail "kafka_bootstrap_empty" "bootstrap servers empty — set in master.config / GEN_VERIFY_BOOTSTRAP_CWDC"
elif [[ -f "$TOPICS_SH" && -f "$ADMIN_CONFIG" ]]; then
  list_out=$(timeout "$TIMEOUT_SEC" "$TOPICS_SH" --bootstrap-server "$BOOTSTRAP_PRIMARY" --command-config "$ADMIN_CONFIG" --list 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    n=$(echo "$list_out" | grep -c . || true)
    pass "kafka_topics_list" "kafka-topics --list OK (bootstrap: $BOOTSTRAP_PRIMARY, ~$n lines)"
  else
    fail "kafka_topics_list" "kafka-topics --list failed (exit $rc): $(echo "$list_out" | head -c 400 | tr '\n' ' ')"
    remediate_kafka
  fi
  # kafka-acls: heavy when many ACLs — skip in --quick
  if [[ "$QUICK_MODE" == true ]]; then
    warn "kafka_acls_skipped" "Quick mode: skipping kafka-acls --list (full run without --quick)"
  elif [[ -f "$ACLS_SH" ]]; then
    acl_out=$(timeout "$TIMEOUT_SEC" "$ACLS_SH" --bootstrap-server "$BOOTSTRAP_PRIMARY" --command-config "$ADMIN_CONFIG" --list 2>&1)
    rc2=$?
    if [[ $rc2 -eq 0 ]]; then
      pass "kafka_acls_list" "kafka-acls --list OK (admin can read ACLs)"
    else
      warn "kafka_acls_list" "kafka-acls --list failed (exit $rc2): $(echo "$acl_out" | head -c 300 | tr '\n' ' ')"
      remediate_kafka
    fi
  fi
else
  warn "kafka_skip" "Skipping Kafka live tests — missing script or admin config"
fi

# --- Section: OpenShift — whoami/nodes once per context; secret for each ctx|ns pair ---
section "4) OpenShift — (optimized) whoami+nodes per context, then secret per namespace"
if ! command -v oc >/dev/null 2>&1; then
  fail "oc_section_skip" "oc missing — skipping all-namespace checks (install oc and re-run)"
else
  cut -d'|' -f1 "$ALL_PAIRS_FILE" 2>/dev/null | sort -u > "$CTX_UNIQUE"
  while IFS= read -r ctx; do
    [[ -z "$ctx" ]] && continue
    who_out=$(timeout "$OCP_TIMEOUT" oc whoami --context "$ctx" 2>&1)
    rcw=$?
    if [[ $rcw -eq 0 ]]; then
      pass "oc_ctx_${ctx}_whoami" "oc whoami OK (context=$ctx) → $who_out"
    else
      fail "oc_ctx_${ctx}_whoami" "oc whoami failed context=$ctx: $(echo "$who_out" | head -c 350 | tr '\n' ' ')"
      remediate_oc
    fi
    nodes_out=$(timeout "$OCP_TIMEOUT" oc get nodes --context "$ctx" -o name 2>&1)
    rcn=$?
    if [[ $rcn -eq 0 ]]; then
      pass "oc_ctx_${ctx}_nodes" "oc get nodes OK (context=$ctx)"
    else
      fail "oc_ctx_${ctx}_nodes" "oc get nodes failed context=$ctx: $(echo "$nodes_out" | head -c 300 | tr '\n' ' ')"
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
      pass "${id_base}_secret" "Secret $K8S_SECRET_NAME exists in namespace $ns (context=$ctx)"
      pdata=$(timeout "$OCP_TIMEOUT" oc get secret "$K8S_SECRET_NAME" -n "$ns" --context "$ctx" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d 2>/dev/null)
      if [[ -n "$pdata" ]] && echo "$pdata" | jq empty 2>/dev/null; then
        nu=$(echo "$pdata" | jq 'keys | length' 2>/dev/null || echo "?")
        pass "${id_base}_plain_users" "plain-users.json readable and valid JSON (~$nu keys)"
      else
        warn "${id_base}_plain_users" "secret exists but plain-users.json could not be fetched/decoded — check key plain-users.json and RBAC"
      fi
    else
      fail "${id_base}_secret" "Secret $K8S_SECRET_NAME not found in namespace $ns (context=$ctx): $(echo "$sec_out" | head -c 300 | tr '\n' ' ')"
      echo "        → Fix: check secret name (k8sSecretName), namespace per environment, and that Confluent created this secret"
    fi
  done < "$ALL_PAIRS_FILE"
fi

# --- Section: Portal HTTP (parallel JSON APIs + security probes) ---
if [[ -n "$PORTAL_URL" ]]; then
  section "5) Web Portal — parallel API + HTTP security + validation routes — $PORTAL_URL"
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
      fail "http_setup_status" "GET /api/setup/status → HTTP ${_stc} or missing ok:true"
    fi
    read -r _tc < "$PORTAL_WORK/t.code"
    if [[ "$_tc" == "200" ]] && grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$PORTAL_WORK/t.json" 2>/dev/null; then
      pass "http_topics" "GET /api/topics → 200 ok:true"
    else
      fail "http_topics" "GET /api/topics → HTTP ${_tc} or ok not true"
    fi
    read -r _uc < "$PORTAL_WORK/u.code"
    if [[ "$_uc" == "200" ]] && grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$PORTAL_WORK/u.json" 2>/dev/null; then
      pass "http_users" "GET /api/users → 200 ok:true"
    else
      fail "http_users" "GET /api/users → HTTP ${_uc} or ok not true"
    fi

    if [[ "$QUICK_MODE" != true ]]; then
      section "5b) HTTP security headers (home page)"
      hdr=$(curl -sI -m 15 $CURL_K "$base/" 2>/dev/null || true)
      echo "$hdr" | grep -qi 'x-frame-options:' && pass "sec_x_frame" "X-Frame-Options present on /" || warn "sec_x_frame" "X-Frame-Options missing on / — clickjacking risk"
      echo "$hdr" | grep -qi 'x-content-type-options:' && pass "sec_nosniff" "X-Content-Type-Options present" || warn "sec_nosniff" "X-Content-Type-Options missing — MIME sniffing risk"
      echo "$hdr" | grep -qi 'referrer-policy:' && pass "sec_referrer" "Referrer-Policy present" || warn "sec_referrer" "Referrer-Policy missing"

      section "5c) Input / path safety (API)"
      pt=$(curl -sS -m 15 $CURL_K -o /dev/null -w "%{http_code}" "$base/api/download/../x" 2>/dev/null || echo 000)
      if [[ "$pt" == "400" || "$pt" == "404" ]]; then pass "sec_path_traversal" "GET /api/download path traversal → $pt (rejected as expected)"; else fail "sec_path_traversal" "GET /api/download/../x → HTTP $pt (expected 400 or 404)"; fi
      pv=$(curl -sS -m 15 $CURL_K -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{}' "$base/api/add-user" 2>/dev/null || echo 000)
      [[ "$pv" == "400" ]] && pass "sec_add_user_validate" "POST /api/add-user {} → 400 validation" || warn "sec_add_user_validate" "POST /api/add-user {} → HTTP $pv (expected 400)"
      ptst=$(curl -sS -m 15 $CURL_K -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{}' "$base/api/test-user" 2>/dev/null || echo 000)
      [[ "$ptst" == "400" ]] && pass "sec_test_user_validate" "POST /api/test-user {} → 400" || warn "sec_test_user_validate" "POST /api/test-user {} → HTTP $ptst"
    else
      warn "sec_skipped" "Quick mode: skipping security header and path/validation probes"
    fi

    if [[ "$API_SMOKE" == true ]]; then
      section "5d) API smoke (backend → gen.sh)"
      sc=$(curl -sS -m 60 $CURL_K -o "$PORTAL_WORK/cl.json" -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{}' "$base/api/cleanup-acl" 2>/dev/null || echo 000)
      if [[ "$sc" == "200" || "$sc" == "500" ]]; then
        if grep -qE 'ENOENT|spawn bash|gen\.sh not found' "$PORTAL_WORK/cl.json" 2>/dev/null; then
          fail "api_gen_cleanup" "cleanup-acl: backend cannot invoke gen/bash — check image and scriptPath"
        else
          pass "api_gen_cleanup" "POST /api/cleanup-acl → $sc (backend received request and invoked script)"
        fi
      else
        warn "api_gen_cleanup" "POST /api/cleanup-acl → HTTP $sc"
      fi
    fi
  else
    warn "http_curl" "curl missing — skipping Portal HTTP tests"
  fi
else
  section "5) Web Portal"
  warn "http_skip" "No --portal-url — skipping HTTP (recommended: --portal-url + ./scripts/check-deployment.sh)"
fi

if [[ "$NPM_AUDIT" == true ]]; then
  section "6) npm audit (webapp — production deps)"
  WP="$PROJECT_ROOT/webapp"
  if command -v npm >/dev/null 2>&1 && [[ -f "$WP/package.json" ]]; then
    if npm audit --omit=dev --audit-level=high -C "$WP" >/dev/null 2>&1; then
      pass "npm_audit" "npm audit --omit=dev: no high/critical (or npm clean)"
    else
      warn "npm_audit" "npm audit found high+ issues — run: cd webapp && npm audit (fix with npm audit fix or upgrade packages)"
      npm audit --omit=dev --audit-level=moderate -C "$WP" 2>&1 | head -n 40 | sed 's/^/   /' || true
    fi
  else
    warn "npm_audit_skip" "npm or webapp/package.json missing — skipping npm audit"
  fi
fi

# --- Summary ---
section "Summary"
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
  [[ "$JSON_MODE" != true ]] && echo "❌ Not ready for Go-Live — fix all FAIL items and run this script again"
  exit 1
fi

[[ "$JSON_MODE" != true ]] && echo "✅ No FAIL — minimum bar passed (review WARN before true production)"
[[ "$JSON_MODE" != true ]] && echo "   Recommended: run ./scripts/check-deployment.sh <portal-url> and E2E with real data (scripts/check-e2e.sh)"
exit 0
