#!/bin/bash

# =====================================================
# [ADMIN NOTE]
# TARGET: plain-users.json (Key-Value JSON Format)
# LOGIC : Inject/Update user credentials inside JSON
#         without creating separate secret keys.
# OCP   : Always add to every site (context:namespace) — site count from GEN_OCP_SITES or default two sites
# KAFKA : Bootstrap uses both sites for resilience (same cluster)
# PLAIN : CFK hot-reloads plain-users.json (~30-60s). Script retries until auth succeeds (max 300s).
# ACL   : Script adds ACL (Read only or All) + consumer group ACL; validates.
#
# USAGE : Keep this script for both (1) Manual CLI (run interactively on Helper Node) and
#         (2) Web backend (call via non-interactive mode with args/env). Do not replace
#         with a rewrite; one script, two entry points.
# PARITY : Every feature/function must work in BOTH CLI and UI — 100% parity. When adding
#          a new feature (e.g. Create topic), add it here (interactive menu + GEN_MODE) and
#          in the Web API/UI so behaviour and options match.
# =====================================================
#
# CRITICAL OPERATIONS & ERROR HANDLING (Production)
# -------------------------------------------------
# Critical operations (must validate before acting; no partial commit):
#   - REMOVE user(s) + ACL  : Validate secrets readable, users exist in both; remove ACLs; then patch BOTH secrets; on second patch failure, REVERT first.
#   - CHANGE PASSWORD       : Validate user exists in both; patch BOTH; on second failure, REVERT first.
#   - CLEANUP ORPHANED ACLs : List and remove only ACLs for users not in secret (no secret write).
#   - ADD USER              : Validate topic, username, ACL; then add to both secrets + ACL; on failure do not leave half-applied state.
# Policy:
#   1. Validate as much as possible before any destructive action (read secrets, list ACLs, check user exists).
#   2. Do not commit (patch secret) until the full set of changes is validated; if any step fails mid-way, rollback and exit with clear error.
#   3. Use error_exit with step names and log_action so production issues are traceable (provisioning.log, stderr).
#
# CHANGELOG
# ---------
# 2026-03-22  Setup wizard: truststore can stay on runtime mount only — Web verifies path + keytool -list; GEN_MODE unchanged.
# 2026-03-22  Per-environment Kafka bootstrap: with GEN_ACTIVE_ENV_ID + environments.json, if the active env object has bootstrapServers, override BOOTSTRAP_CWDC/BOTH (parity with Web portal env switch).
# 2026-03-22  Init Kafka client .properties templates: menu [8] and GEN_MODE=8 — scripts/ensure-kafka-client-props.sh (parity with web setup save; GEN_KAFKA_BOOTSTRAP optional). Full PEM/JKS + SASL materialization (no CHANGE_ME) is via the web setup wizard only — use mount configs/ to adjust later.
# 2026-03-21  Go-Live verify: menu [7] and GEN_NONINTERACTIVE=1 GEN_MODE=7 — scripts/verify-golive.sh (all namespaces from master/environments, Kafka, optional Portal). Env: GOLIVE_PORTAL_URL, GOLIVE_JSON=1.
# 2026-03-21  Preflight / Kafka admin list: menu [6] and GEN_NONINTERACTIVE=1 GEN_MODE=6 — kafka-topics.sh --list (parity with web setup Verify deep check). Web setup: deep verify runs same + oc whoami.
# 2026-03-18  Add ACL for existing user: GEN_MODE=5 (CLI menu [5] + non-interactive). No new credential; add topic ACL + consumer group for user already in secret. Web: Add ACL to existing user (summary + confirm). Audit: create-topic label + add-acl-existing.
# 2026-03-15  Create topic: use broker default for partitions and replication factor (rack-aware placement). No GEN_PARTITIONS/GEN_REPLICATION_FACTOR; kafka-topics.sh --create without --partitions/--replication-factor so broker default.num.partitions and default.replication.factor apply. CLI and Web parity.
# 2026-03-15  Create topic (CLI + Web parity): GEN_MODE=4 — interactive menu [4] Create new topic; non-interactive env GEN_TOPIC_NAME (or GEN_TOPIC) only. validate_topic_name(); kafka-topics.sh --create; log CREATE_TOPIC to provisioning.log.
# 2026-03-15  PARITY note in header: every feature must exist in both CLI (gen.sh) and GUI/API (100%).
# 2026-02-xx  Multi-site (names not fixed): GEN_OCP_SITES="ctx1:ns1,ctx2:ns2" for multiple OCP clusters; if unset use OCP_CTX_CWDC/NS_CWDC + OCP_CTX_TLS2/NS_TLS2. All flows (Add/Remove/Change password/Verify) iterate SITE_CTX/SITE_NS; revert previous site if a patch fails.
# 2026-02-xx  All script output files (.enc packs) go to user_output in the same path as the script (USER_OUTPUT_DIR=$SCRIPT_DIR/user_output). Override with GEN_USER_OUTPUT_DIR. GEN_PACK_DIR echoes this so Web/download can find files.
# 2026-02-19  Non-interactive Add user / Change password: GEN_PASSPHRASE for .enc file; script echoes GEN_PACK_FILE= and GEN_PACK_NAME= for Web download and decrypt instructions.
# 2026-02-19  Non-interactive (Web): GEN_MODE=2 (Test user), GEN_MODE=3 with GEN_ACTION=1|2|3 (Remove, Change password, Cleanup ACL). Env: GEN_KAFKA_USER, GEN_TEST_PASS, GEN_TOPIC_NAME; GEN_USERS; GEN_CHANGE_USER, GEN_NEW_PASSWORD.
# 2026-02-19  Add new user: check username already exists (block duplicate to avoid human error). Lock remains file-based in /tmp.
# 2026-02-19  Phase 1 Production Readiness (PRODUCTION_READINESS_AUDIT.md)
#             - Lock file: prevent concurrent runs (gen_kafka_user.lock)
#             - Temp cleanup: cleanup_temp_files() + trap EXIT INT TERM
#             - Username validation: validate_username() (length, charset, system-user collision)
#             - Exit codes: 0=success/cancel, 1=error (error_exit)
#             - Verify after secret patch: confirm user present/absent per site
#             - Logging: DELETE and CHANGE_PASSWORD written to provisioning.log
# 2026-02-19  Review follow-up: Remove-user jq single-call (no loop); strong warning when removing ALL users.
# =====================================================

# 1. FIXED CONFIGURATION (overridable by env for Web/non-interactive: GEN_BASE_DIR, GEN_KAFKA_BIN, GEN_OC_PATH)
# Output directory: all generated .enc and pack files go here (same path as this script, easy to find)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Go-Live verify script: repo = scripts/verify-golive.sh; Docker image = /opt/kafka-usermgmt/verify-golive.sh
GOLIVE_VERIFY_SCRIPT="${GOLIVE_VERIFY_SCRIPT:-$SCRIPT_DIR/scripts/verify-golive.sh}"
[ ! -f "$GOLIVE_VERIFY_SCRIPT" ] && [ -f /opt/kafka-usermgmt/verify-golive.sh ] && GOLIVE_VERIFY_SCRIPT=/opt/kafka-usermgmt/verify-golive.sh
USER_OUTPUT_DIR="${GEN_USER_OUTPUT_DIR:-$SCRIPT_DIR/user_output}"
mkdir -p "$USER_OUTPUT_DIR"

BASE_DIR="${GEN_BASE_DIR:-$SCRIPT_DIR}"
# Default dir name matches Docker symlink; override with GEN_KAFKA_BIN or install newer tarball under BASE_DIR (see master.config kafka.clientInstallDir).
KAFKA_BIN="${GEN_KAFKA_BIN:-$BASE_DIR/kafka_2.13-3.6.1/bin}"
# Host bind-mount on /opt/kafka-usermgmt hides image Kafka — use bundled CLI (Dockerfile: /opt/apache-kafka, env KAFKA_TOOLS_BIN).
if [ ! -f "$KAFKA_BIN/kafka-topics.sh" ] && [ -n "${KAFKA_TOOLS_BIN:-}" ] && [ -f "${KAFKA_TOOLS_BIN}/kafka-topics.sh" ]; then
    KAFKA_BIN="$KAFKA_TOOLS_BIN"
fi
CLIENT_CONFIG="${GEN_CLIENT_CONFIG:-$BASE_DIR/configs/kafka-client.properties}"
ADMIN_CONFIG="${GEN_ADMIN_CONFIG:-$BASE_DIR/configs/kafka-client-master.properties}"

K8S_SECRET_NAME="${GEN_K8S_SECRET_NAME:-kafka-server-side-credentials}"
LOG_FILE="${GEN_LOG_FILE:-$BASE_DIR/provisioning.log}"
ENCRYPT_OUTPUT=true

# Timeout Settings
TIMEOUT_SEC=20
VALIDATE_CONSUME_TIMEOUT_MS=8000
OCP_CHECK_TIMEOUT=15
CONSUME_TIMEOUT_SEC=20
CONSUME_TIMEOUT_MS=15000
# ACL remove: Kafka AdminClient can timeout or wait for (y/n); use longer timeout and pipe multiple 'y'
ACL_REMOVE_TIMEOUT_SEC=120
ACL_REMOVE_REQUEST_TIMEOUT_MS=120000
ACL_REMOVE_RETRY_DELAY_SEC=5

# Retry Settings (for hot-reload authentication)
AUTH_RETRY_INTERVAL=5
AUTH_MAX_RETRY_SEC=300
# Consume test: delay after auth (brokers may reload at different times), then retry on auth failure
CONSUME_DELAY_AFTER_AUTH=10
CONSUME_AUTH_RETRY_COUNT=3
CONSUME_AUTH_RETRY_INTERVAL=10

# Password Settings
PASSWORD_LENGTH=32

# Consumer Settings
CONSUME_MAX_MESSAGES=5

# Temporary Directory
TMP_DIR="/tmp"
LOCK_FILE="$TMP_DIR/gen_kafka_user.lock"

# System Users (excluded from user management operations)
# Note: These are Confluent/Kafka system users that should NOT be managed via this script
# - kafka, schema_registry, kafka_connect, control_center: Confluent Platform components
# - client, admin: Common admin/service accounts
# - user1, user2: TODO - Verify if these are actual system users or can be removed
# - an-api-key: API key user (verify if system or custom)
# To customize: Edit this regex pattern to match your environment's system users
SYSTEM_USERS="^(kafka|schema_registry|kafka_connect|control_center|client|admin|user1|user2|an-api-key)$"

# Kafka Bootstrap (both sites - same cluster, resilience if one site down)
BOOTSTRAP_CWDC="kafka.apps.cwdc.esb-kafka-prod.intra.ais:443"
BOOTSTRAP_TLS2="kafka.apps.tls2.esb-kafka-prod.intra.ais:443"
BOOTSTRAP_BOTH="${BOOTSTRAP_CWDC},${BOOTSTRAP_TLS2}"

# OCP Context (for oc commands — add secret to every site). Default two sites; override with GEN_OCP_SITES="ctx1:ns1,ctx2:ns2" (context names are not fixed)
OCP_CTX_CWDC="${OCP_CTX_CWDC:-cwdc}"
OCP_CTX_TLS2="${OCP_CTX_TLS2:-tls2}"
NS_CWDC="${NS_CWDC:-esb-prod-cwdc}"
NS_TLS2="${NS_TLS2:-esb-prod-tls2}"
KAFKA_CR_NAME="kafka"

# Multi-environment (parity with Web portal): GEN_ACTIVE_ENV_ID + environments.json under BASE_DIR (or GEN_ENVIRONMENTS_JSON).
# ocContext = exact NAME from `oc config get-contexts` in the kubeconfig you use (app does not create contexts). One OCP cluster may use different contexts per namespace (e.g. cwdc-dev / cwdc-sit / cwdc-uat).
# File shape: { "environments": [ { "id": "dev", "sites": [ { "ocContext": "cwdc-dev", "namespace": "esb-dev-cwdc" }, ... ] } ] } — multiple sites = multi-region for that environment (GEN_OCP_SITES becomes ctx1:ns1,ctx2:ns2).
ENV_JSON="${GEN_ENVIRONMENTS_JSON:-$BASE_DIR/environments.json}"
if [ -z "${GEN_OCP_SITES:-}" ] && [ -n "${GEN_ACTIVE_ENV_ID:-}" ] && [ -f "$ENV_JSON" ] && command -v jq >/dev/null 2>&1; then
    _pairs=$(jq -r --arg id "$GEN_ACTIVE_ENV_ID" '
      ([.environments[]? | select(.enabled != false) | select(.id == $id)] | first) as $e
      | if $e == null then ""
        elif ($e.sites | type) == "array" and ($e.sites | length) > 0 then
          $e.sites | map(select(.namespace != null and .ocContext != null) | "\(.ocContext):\(.namespace)") | join(",")
        elif ($e.namespace != null and $e.namespace != "") and ($e.ocContext != null and $e.ocContext != "") then
          "\($e.ocContext):\($e.namespace)"
        else "" end
    ' "$ENV_JSON" 2>/dev/null)
    if [ -n "$_pairs" ]; then
        export GEN_OCP_SITES="$_pairs"
    fi
fi
# Per-environment Kafka bootstrap (parity with Web session env): if active env defines bootstrapServers in environments.json, use it for CLI Kafka tools.
if [ -n "${GEN_ACTIVE_ENV_ID:-}" ] && [ -f "$ENV_JSON" ] && command -v jq >/dev/null 2>&1; then
    _eboot=$(jq -r --arg id "$GEN_ACTIVE_ENV_ID" '
      ([.environments[]? | select(.enabled != false) | select(.id == $id)] | first) as $e
      | if $e == null then "" else ($e.bootstrapServers // "") end
    ' "$ENV_JSON" 2>/dev/null || true)
    _eboot=$(echo "$_eboot" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$_eboot" ]; then
        BOOTSTRAP_CWDC="$_eboot"
        BOOTSTRAP_TLS2="$_eboot"
        BOOTSTRAP_BOTH="$_eboot"
    fi
fi

# Build site arrays (used throughout script). If GEN_OCP_SITES is unset, use CWDC/TLS2 values above
if [ -n "${GEN_OCP_SITES}" ]; then
    SITE_CTX=()
    SITE_NS=()
    while IFS= read -r -d ',' pair; do
        pair=$(echo "$pair" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$pair" ] && continue
        c="${pair%%:*}"
        n="${pair#*:}"
        c=$(echo "$c" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        n=$(echo "$n" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$c" ] || [ -z "$n" ] && continue
        SITE_CTX+=("$c")
        SITE_NS+=("$n")
    done <<< "${GEN_OCP_SITES},"
else
    SITE_CTX=("$OCP_CTX_CWDC" "$OCP_CTX_TLS2")
    SITE_NS=("$NS_CWDC" "$NS_TLS2")
fi
NUM_SITES=${#SITE_CTX[@]}
[ "$NUM_SITES" -lt 1 ] && { echo "ERROR: At least one OCP site (context:namespace) required. Set GEN_OCP_SITES or OCP_CTX_/NS_ vars." >&2; exit 1; }

# Dual-OCP / cross-region Confluent: same logical cluster, two OpenShift clusters — set GEN_OCP_SITES="ctx1:ns1,ctx2:ns2"
# and one kubeconfig listing every context (often ~/.kube/config; optional merged file e.g. config-both). Web: /setup.html.

# Kubeconfig: single-region default is `config` from `oc login` — try that before optional `config-both` (merged multi-cluster file).
# - If KUBECONFIG is set to old path (/app/user2) or single-cluster file, prefer BASE_DIR/.kube (single source of truth)
# - If unset, try BASE_DIR/SCRIPT_DIR .kube/config then config-both
# - If still fails for first site context, try ~/.kube/config (so "oc get node" working in shell => gen.sh can use it)
if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG}" ]; then
  case "${KUBECONFIG}" in
    *config-cwdc|*config-tls2)
      kube_dir="${KUBECONFIG%/*}"
      if [ -f "${kube_dir}/config-both" ]; then
        export KUBECONFIG="${kube_dir}/config-both"
      fi
      ;;
    */app/user2/*)
      # Old path: prefer kubeconfig under BASE_DIR (single source of truth, e.g. /opt/kafka-usermgmt)
      for candidate in "$BASE_DIR/.kube/config" "$BASE_DIR/.kube/config-both" "$SCRIPT_DIR/.kube/config" "$SCRIPT_DIR/.kube/config-both"; do
        if [ -f "$candidate" ]; then
          export KUBECONFIG="$candidate"
          break
        fi
      done
      ;;
  esac
elif [ -z "${KUBECONFIG:-}" ]; then
  for candidate in "$BASE_DIR/.kube/config" "$BASE_DIR/.kube/config-both" "$SCRIPT_DIR/.kube/config" "$SCRIPT_DIR/.kube/config-both"; do
    if [ -f "$candidate" ]; then
      export KUBECONFIG="$candidate"
      break
    fi
  done
fi
# If KUBECONFIG is set but fails for cwdc, try BASE_DIR/.kube then default ~/.kube/config
if [ -n "${KUBECONFIG:-}" ]; then
  if ! timeout 5 oc get nodes --context "${SITE_CTX[0]}" &>/dev/null; then
    for fallback in "$BASE_DIR/.kube/config" "$BASE_DIR/.kube/config-both" "${HOME:-/tmp}/.kube/config"; do
      [ -f "$fallback" ] || continue
      if timeout 5 env KUBECONFIG="$fallback" oc get nodes --context "${SITE_CTX[0]}" &>/dev/null; then
        export KUBECONFIG="$fallback"
        break
      fi
    done
  fi
fi

# Formatting Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# UI Functions
spinner() {
    local pid=$1; local delay=0.1; local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}; printf " [%c] " "$spinstr"; local spinstr=$temp${spinstr%"$temp"}; sleep $delay; printf "\b\b\b\b\b"
    done; printf "    \b\b\b\b"
}

status_msg() { echo -ne " ${CYAN}[PROCESSING]${NC} $1..."; }
done_msg() { echo -e " ${GREEN}✅ DONE${NC}"; }
# Trim leading/trailing whitespace (avoids kafka-acls.sh failures from " LITERAL " etc.)
trim_ws() { echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
# Temp admin config with longer timeouts for ACL remove (avoids TimeoutException / DisconnectException)
get_acl_remove_config() {
  local f="$TMP_DIR/gen_acl_remove_config_$$.properties"
  if [ ! -f "$f" ] && [ -f "$ADMIN_CONFIG" ]; then
    { cat "$ADMIN_CONFIG"; printf '%s\n' "request.timeout.ms=$ACL_REMOVE_REQUEST_TIMEOUT_MS" "default.api.timeout.ms=$ACL_REMOVE_REQUEST_TIMEOUT_MS" "retries=3"; } > "$f" 2>/dev/null || true
  fi
  [ -f "$f" ] && echo "$f" || echo "$ADMIN_CONFIG"
}
# stdin for kafka-acls --remove (y/n): use a file so when run from Web (no TTY) input is available and pipe doesn't close early
ACL_YES_FILE="$TMP_DIR/gen_acl_yes_$$.txt"
# Run kafka-acls --remove with confirm + timeout; on failure retry once after delay
run_acl_remove() {
  local bootstrap="$1" cfg="$2" principal="$3" op_cli="$4" res_type="$5" res_name="$6" pattern_type="$7"
  local out rc
  if [ ! -f "$ACL_YES_FILE" ]; then n=0; while [ $n -lt 50 ]; do echo y; n=$((n+1)); done > "$ACL_YES_FILE"; fi
  out=$(timeout $ACL_REMOVE_TIMEOUT_SEC $KAFKA_BIN/kafka-acls.sh --bootstrap-server "$bootstrap" --command-config "$cfg" --remove --allow-principal "$principal" --operation "$op_cli" "$res_type" "$res_name" --resource-pattern-type "$pattern_type" < "$ACL_YES_FILE" 2>&1)
  rc=$?
  if [ $rc -ne 0 ] && [ $ACL_REMOVE_RETRY_DELAY_SEC -gt 0 ]; then
    sleep $ACL_REMOVE_RETRY_DELAY_SEC
    [ -f "$ACL_YES_FILE" ] || { n=0; while [ $n -lt 50 ]; do echo y; n=$((n+1)); done > "$ACL_YES_FILE"; }
    out=$(timeout $ACL_REMOVE_TIMEOUT_SEC $KAFKA_BIN/kafka-acls.sh --bootstrap-server "$bootstrap" --command-config "$cfg" --remove --allow-principal "$principal" --operation "$op_cli" "$res_type" "$res_name" --resource-pattern-type "$pattern_type" < "$ACL_YES_FILE" 2>&1)
    rc=$?
  fi
  echo "$out"
  return $rc
}
# Map ACL list operation names (e.g. DESCRIBE_CONFIGS) to kafka-acls.sh --operation names (e.g. DescribeConfigs)
acl_operation_for_remove() {
    case "$(echo "$1" | tr '[:lower:]' '[:upper:]')" in
        DESCRIBE_CONFIGS) echo "DescribeConfigs" ;;
        ALTER_CONFIGS)    echo "AlterConfigs" ;;
        DESCRIBE)         echo "Describe" ;;
        READ)             echo "Read" ;;
        WRITE)            echo "Write" ;;
        ALL)              echo "All" ;;
        ALTER)            echo "Alter" ;;
        DELETE)           echo "Delete" ;;
        CREATE)           echo "Create" ;;
        IDEMPOTENT_WRITE) echo "IdempotentWrite" ;;
        CLUSTER_ACTION)   echo "ClusterAction" ;;
        CREATE_TOKENS)    echo "CreateTokens" ;;
        DESCRIBE_TOKENS)  echo "DescribeTokens" ;;
        *)               echo "$1" ;;  # pass through if already correct or unknown
    esac
}
# error_exit [step_name] message  — log, print, exit 1 (step_name optional, for tracing)
error_exit() {
    local step="$1" msg="$2"
    if [ -n "$msg" ]; then
        [ -n "$step" ] && log_action "ERROR | step=$step | $msg" || log_action "ERROR | $step"
        echo -e "\n ${RED}❌ ERROR${NC}${step:+ ${CYAN}[$step]${NC}} $msg"
    else
        msg="$step"
        log_action "ERROR | $msg"
        echo -e "\n ${RED}❌ ERROR: $msg${NC}"
    fi
    exit $EXIT_ERROR
}

# Structured log: [timestamp] action= | operator= | host= | ... (easy to grep/tag)
log_action() {
    local ts now who host rest
    now=$(date +"%Y-%m-%d %H:%M:%S")
    who=$(whoami)
    host=$(hostname 2>/dev/null || echo "localhost")
    rest="$*"
    echo "[$now] action=$rest | operator=$who | host=$host" >> "$LOG_FILE"
}

# Exit codes: 0=success/cancel, 1=error (used by error_exit)
EXIT_SUCCESS=0
EXIT_ERROR=1

# Cleanup temp files and lock on exit/signal (Phase 1)
cleanup_temp_files() {
    rm -f "$TMP_DIR"/gen_*.properties "$TMP_DIR"/gen_acl_remove_config_*.properties "$TMP_DIR"/gen_acl_yes_*.txt "$TMP_DIR"/topics.list "$TMP_DIR"/topic_out "$TMP_DIR"/*_temp.txt "$TMP_DIR"/acl_list_*.txt 2>/dev/null
    [ -n "$LOCK_FILE" ] && [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE" 2>/dev/null
}
on_exit() {
    local exit_code=$?
    [ $exit_code -ne $EXIT_SUCCESS ] && [ -n "$LOG_FILE" ] && log_action "SCRIPT_EXIT | exit_code=$exit_code"
    cleanup_temp_files
}
trap on_exit EXIT INT TERM

# Acquire single-instance lock (Phase 1)
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            error_exit "Another instance is running (PID: $pid). If not, remove $LOCK_FILE and retry."
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

# Username validation: length, charset, no system-user collision (Phase 1)
validate_username() {
    local user="$1"
    [ -z "$user" ] && error_exit "Username is required."
    [ ${#user} -lt 1 ] && error_exit "Username too short."
    [ ${#user} -gt 64 ] && error_exit "Username too long (max 64)."
    [[ "$user" =~ [^a-zA-Z0-9._-] ]] && error_exit "Username may only contain letters, numbers, dots, underscores, and hyphens."
    echo "$user" | grep -qE "$SYSTEM_USERS" && error_exit "Username conflicts with system user: $user"
}

# Topic name validation (for create topic — same charset as UI/API)
validate_topic_name() {
    local topic="$1"
    [ -z "$topic" ] && error_exit "Topic name is required."
    topic=$(trim_ws "$topic")
    [ -z "$topic" ] && error_exit "Topic name is required."
    [ ${#topic} -gt 512 ] && error_exit "Topic name too long (max 512)."
    [[ "$topic" =~ [^a-zA-Z0-9._-] ]] && error_exit "Topic may only contain letters, numbers, dots, underscores, and hyphens."
}

# Verify user present in secret after patch (Phase 1)
verify_user_in_secret() {
    local ctx=$1 ns=$2 user=$3
    local json
    json=$(oc get secret $K8S_SECRET_NAME -n "$ns" --context "$ctx" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
    echo "$json" | jq -e --arg u "$user" '.[$u]' >/dev/null 2>&1 || { echo -e "\n   ${RED}❌ Verification failed: user $user not found in secret at $ctx after patch.${NC}"; return 1; }
    return 0
}

# Verify user absent from secret after remove (Phase 1)
verify_user_absent_from_secret() {
    local ctx=$1 ns=$2 user=$3
    local json
    json=$(oc get secret $K8S_SECRET_NAME -n "$ns" --context "$ctx" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
    if echo "$json" | jq -e --arg u "$user" '.[$u]' >/dev/null 2>&1; then
        echo -e "\n   ${RED}❌ Verification failed: user $user still present in secret at $ctx after remove.${NC}"
        return 1
    fi
    return 0
}

# Non-interactive Mode 7: full Go-Live verify (before PRE-CHECK — single pass: missing files / oc / kafka)
if [ "${GEN_NONINTERACTIVE}" = "1" ] && [ "${GEN_MODE}" = "7" ]; then
    _vsites=""
    for ((i=0;i<NUM_SITES;i++)); do
        [ -n "$_vsites" ] && _vsites="${_vsites},"
        _vsites="${_vsites}${SITE_CTX[$i]}:${SITE_NS[$i]}"
    done
    export GEN_OCP_SITES="$_vsites"
    export GEN_BASE_DIR="$BASE_DIR"
    export GEN_CLIENT_CONFIG="$CLIENT_CONFIG"
    export GEN_ADMIN_CONFIG="$ADMIN_CONFIG"
    export GEN_KAFKA_BIN="$KAFKA_BIN"
    export GEN_K8S_SECRET_NAME="$K8S_SECRET_NAME"
    export GEN_ENVIRONMENTS_JSON="$ENV_JSON"
    export GEN_VERIFY_BOOTSTRAP_CWDC="${BOOTSTRAP_CWDC}"
    export GEN_VERIFY_BOOTSTRAP_BOTH="${BOOTSTRAP_BOTH}"
    if [ "${GOLIVE_JSON:-}" = "1" ]; then
        if [ -n "${GOLIVE_PORTAL_URL:-}" ]; then
            bash "$GOLIVE_VERIFY_SCRIPT" --from-gen-env --json --portal-url "${GOLIVE_PORTAL_URL}"
        else
            bash "$GOLIVE_VERIFY_SCRIPT" --from-gen-env --json
        fi
    else
        if [ -n "${GOLIVE_PORTAL_URL:-}" ]; then
            bash "$GOLIVE_VERIFY_SCRIPT" --from-gen-env --portal-url "${GOLIVE_PORTAL_URL}"
        else
            bash "$GOLIVE_VERIFY_SCRIPT" --from-gen-env
        fi
    fi
    exit $?
fi

# Non-interactive Mode 8: create kafka-client*.properties templates under BASE_DIR/configs/ if missing (parity with web /api/setup/apply)
if [ "${GEN_NONINTERACTIVE}" = "1" ] && [ "${GEN_MODE}" = "8" ]; then
    _BOOT8="${GEN_KAFKA_BOOTSTRAP:-$BOOTSTRAP_CWDC}"
    _ENSURE="${SCRIPT_DIR}/scripts/ensure-kafka-client-props.sh"
    [ ! -f "$_ENSURE" ] && [ -f /opt/kafka-usermgmt/ensure-kafka-client-props.sh ] && _ENSURE=/opt/kafka-usermgmt/ensure-kafka-client-props.sh
    [ ! -f "$_ENSURE" ] && error_exit "ensure-kafka-client-props.sh not found (expected scripts/ or /opt/kafka-usermgmt/)"
    bash "$_ENSURE" "$BASE_DIR" "$_BOOT8"
    exit 0
fi

# PRE-CHECK
[ ! -f "$CLIENT_CONFIG" ] && error_exit "Config file not found at $CLIENT_CONFIG"
[ ! -f "$ADMIN_CONFIG" ] && error_exit "Admin config not found at $ADMIN_CONFIG (needed for kafka-acls)"
command -v jq >/dev/null 2>&1 || error_exit "jq tool is required but not installed."
command -v oc >/dev/null 2>&1 || error_exit "oc (OpenShift CLI) is required but not installed."

clear
echo -e "${YELLOW}+-------------------------------------------------------+" 
echo -e "|      KAFKA PROVISIONING TOOL - JSON VERSION           |"
echo -e "|      (Target: plain-users.json Injection)             |"
echo -e "+-------------------------------------------------------+${NC}"

# OCP CONNECTIVITY CHECK (fail fast before any work)
echo -e "\n${CYAN}[PRE-CHECK] Verifying OCP connectivity...${NC}"
for ((i=0;i<NUM_SITES;i++)); do
    status_msg "OCP site ${SITE_CTX[$i]} (${SITE_NS[$i]})"
    oc_out=$(timeout $OCP_CHECK_TIMEOUT oc get nodes --context "${SITE_CTX[$i]}" 2>&1) || {
        echo -e "\n   ${RED}oc get nodes --context ${SITE_CTX[$i]} failed.${NC}"
        echo -e "   KUBECONFIG=${KUBECONFIG:-<not set, using default ~/.kube/config>}"
        echo -e "   Ensure: (1) KUBECONFIG points to a file with valid login for context '${SITE_CTX[$i]}'; (2) context name matches (e.g. oc config get-contexts)."
        [ -n "$oc_out" ] && echo "$oc_out" | sed 's/^/   /'
        error_exit "Cannot connect to OCP (context: ${SITE_CTX[$i]}, namespace: ${SITE_NS[$i]}). Check network/credentials."
    }
    done_msg
done
echo -e " ${GREEN}All OCP sites are reachable ($NUM_SITES site(s)).${NC}\n"

# Non-interactive Mode 6: Kafka admin preflight (parity with web /api/setup/preview deepVerify)
if [ "${GEN_NONINTERACTIVE}" = "1" ] && [ "${GEN_MODE}" = "6" ]; then
    echo -e "\n${CYAN}[PREFLIGHT] kafka-topics.sh --list (bootstrap: $BOOTSTRAP_CWDC)${NC}"
    list_out=$(timeout "$TIMEOUT_SEC" "$KAFKA_BIN/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP_CWDC" --command-config "$ADMIN_CONFIG" --list 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo -e " ${GREEN}OK — kafka-topics --list succeeded.${NC}"
        exit 0
    fi
    echo "$list_out" | sed 's/^/   /'
    error_exit "kafka-topics --list failed (exit $rc). Fix bootstrap, admin properties, truststore, or credentials."
fi

acquire_lock

echo -e "${CYAN}Info: User/secret will be added to OCP secrets in all $NUM_SITES site(s).${NC}"
echo -e "${CYAN}      Kafka bootstrap uses configured endpoints for resilience.${NC}"

# Non-interactive (Web): set vars from env and run Add user once then exit
if [ "${GEN_NONINTERACTIVE}" = "1" ] && [ "${GEN_MODE}" = "1" ]; then
    SYSTEM_NAME="${GEN_SYSTEM_NAME:?GEN_SYSTEM_NAME required for non-interactive}"
    TOPIC_NAME="${GEN_TOPIC_NAME:?GEN_TOPIC_NAME required for non-interactive}"
    KAFKA_USER="${GEN_KAFKA_USER:?GEN_KAFKA_USER required for non-interactive}"
    ACL_CHOICE="${GEN_ACL:-2}"
    status_msg "Validating Topic '$TOPIC_NAME'"
    timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config $ADMIN_CONFIG --describe --topic "$TOPIC_NAME" > $TMP_DIR/topic_out 2>/dev/null || true
    [ -s $TMP_DIR/topic_out ] || error_exit "Topic '$TOPIC_NAME' not found or no permission."
    done_msg
    validate_username "$KAFKA_USER"
    status_msg "Checking if username already exists"
    JSON_CWDC=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[0]}" --context "${SITE_CTX[0]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
    [ -z "$JSON_CWDC" ] && error_exit "Could not fetch user list from site ${SITE_CTX[0]} to check for duplicate."
    exists=$(echo "$JSON_CWDC" | jq -r --arg u "$KAFKA_USER" 'if has($u) then "yes" else "no" end')
    [ "$exists" = "yes" ] && error_exit "User '$KAFKA_USER' already exists."
    done_msg
    GEN_ADD_ONCE=1
fi

# Non-interactive Mode 2: Test existing user (auth only), then exit
if [ "${GEN_NONINTERACTIVE}" = "1" ] && [ "${GEN_MODE}" = "2" ]; then
    KAFKA_USER="${GEN_KAFKA_USER:?GEN_KAFKA_USER required}"
    TEST_PASS="${GEN_TEST_PASS:?GEN_TEST_PASS required}"
    TOPIC_NAME="${GEN_TOPIC_NAME:-}"
    [ -z "$TOPIC_NAME" ] && TOPIC_NAME="${GEN_TOPIC_NAME:?GEN_TOPIC_NAME required for test}"
    validate_username "$KAFKA_USER"
    SSL_LINES=$(grep -E '^ssl\.truststore\.(location|password)' "$ADMIN_CONFIG" 2>/dev/null)
    [ -z "$SSL_LINES" ] && SSL_LINES=$(grep -E '^ssl\.truststore\.(location|password)' "$CLIENT_CONFIG" 2>/dev/null)
    [ -z "$SSL_LINES" ] && error_exit "Could not find ssl.truststore in config."
    SAFE_PASS="${TEST_PASS//\"/\\\"}"
    TEMP_CFG="$TMP_DIR/gen_test_$$.properties"
    echo -e "\n   ${CYAN}Testing auth with User:$KAFKA_USER on each bootstrap...${NC}"
    for entry in "$BOOTSTRAP_CWDC:1" "$BOOTSTRAP_TLS2:2"; do
        label="site${entry##*:}"
        bootstrap="${entry%:*}"
        { echo "bootstrap.servers=$bootstrap"; echo "security.protocol=SASL_SSL"; echo "sasl.mechanism=PLAIN"; echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$KAFKA_USER\" password=\"$SAFE_PASS\";"; echo "$SSL_LINES"; } > "$TEMP_CFG"
        status_msg "Auth test ($label)"
        out=$(timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server "$bootstrap" --command-config "$TEMP_CFG" --describe --topic "$TOPIC_NAME" 2>&1)
        rc=$?
        if [ $rc -eq 0 ]; then done_msg; echo -e "   ${GREEN}User $KAFKA_USER: AUTH OK on $label${NC}"; else echo -e "\n   ${RED}AUTH FAILED on $label (exit $rc)${NC}"; echo "$out" | sed 's/^/   /'; fi
    done
    acl_list=$($KAFKA_BIN/kafka-acls.sh --bootstrap-server $BOOTSTRAP_CWDC --command-config $ADMIN_CONFIG --list --principal "User:$KAFKA_USER" </dev/null 2>&1)
    [ -n "$acl_list" ] && echo "$acl_list" | sed 's/^/   /'
    echo -e "\n${CYAN}Test complete.${NC}"
    exit 0
fi

# Non-interactive Mode 3: Remove / Change password / Cleanup - set vars and enter loop once
if [ "${GEN_NONINTERACTIVE}" = "1" ] && [ "${GEN_MODE}" = "3" ]; then
    GEN_ACTION="${GEN_ACTION:-1}"
    if [ "$GEN_ACTION" = "1" ]; then
        GEN_USERS="${GEN_USERS:?GEN_USERS required (comma-separated) for remove}"
        JSON_CWDC=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[0]}" --context "${SITE_CTX[0]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
        [ -z "$JSON_CWDC" ] && error_exit "Could not retrieve users from site ${SITE_CTX[0]} secret."
        USER_LIST=$(echo "$JSON_CWDC" | jq -r 'keys[]' | grep -vE "$SYSTEM_USERS" | sort)
        SELECTED_USERS=()
        IFS=',' read -ra UARR <<< "$GEN_USERS"
        for u in "${UARR[@]}"; do
            u=$(echo "$u" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$u" ] && continue
            echo "$USER_LIST" | grep -q "^${u}$" && SELECTED_USERS+=("$u") || echo -e "   ${YELLOW}Skip (not in secret): $u${NC}"
        done
        [ ${#SELECTED_USERS[@]} -eq 0 ] && error_exit "No valid users to remove from GEN_USERS."
        GEN_MANAGE_ONCE=1
    elif [ "$GEN_ACTION" = "2" ]; then
        GEN_CHANGE_USER="${GEN_CHANGE_USER:?GEN_CHANGE_USER required}"
        GEN_NEW_PASSWORD="${GEN_NEW_PASSWORD:?GEN_NEW_PASSWORD required}"
        JSON_CWDC=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[0]}" --context "${SITE_CTX[0]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
        [ -z "$JSON_CWDC" ] && error_exit "Could not retrieve users from site ${SITE_CTX[0]} secret."
        USER_LIST=$(echo "$JSON_CWDC" | jq -r 'keys[]' | grep -vE "$SYSTEM_USERS" | sort)
        echo "$USER_LIST" | grep -q "^${GEN_CHANGE_USER}$" || error_exit "User $GEN_CHANGE_USER not found in secret."
        CHANGE_USER="$GEN_CHANGE_USER"
        NEW_PASS="$GEN_NEW_PASSWORD"
        GEN_MANAGE_ONCE=1
    elif [ "$GEN_ACTION" = "3" ]; then
        GEN_MANAGE_ONCE=1
    fi
    GEN_RUN_MODE3=1
fi

# Non-interactive Mode 4: Create Kafka topic (broker default partitions/replication — rack-aware)
if [ "${GEN_NONINTERACTIVE}" = "1" ] && [ "${GEN_MODE}" = "4" ]; then
    CREATE_TOPIC_NAME="${GEN_TOPIC_NAME:-${GEN_TOPIC}}"
    [ -z "$CREATE_TOPIC_NAME" ] && error_exit "GEN_TOPIC_NAME or GEN_TOPIC required for create-topic."
    CREATE_TOPIC_NAME=$(trim_ws "$CREATE_TOPIC_NAME")
    validate_topic_name "$CREATE_TOPIC_NAME"
    status_msg "Creating topic '$CREATE_TOPIC_NAME' (broker default partitions/replication)"
    create_out=$($KAFKA_BIN/kafka-topics.sh --create \
        --topic "$CREATE_TOPIC_NAME" \
        --bootstrap-server "$BOOTSTRAP_BOTH" \
        --command-config "$ADMIN_CONFIG" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        done_msg
        echo -e "   ${GREEN}Topic '$CREATE_TOPIC_NAME' created.${NC}"
        log_action "CREATE_TOPIC | topic=$CREATE_TOPIC_NAME"
    else
        echo "$create_out" | sed 's/^/   /'
        error_exit "CREATE_TOPIC" "Create topic failed (exit $rc). Topic may already exist."
    fi
    exit 0
fi

# Non-interactive Mode 5: Add ACL for existing user (no secret change, no new credential)
if [ "${GEN_NONINTERACTIVE}" = "1" ] && [ "${GEN_MODE}" = "5" ]; then
    KAFKA_USER="${GEN_KAFKA_USER:?GEN_KAFKA_USER required for add-acl-existing}"
    TOPIC_NAME="${GEN_TOPIC_NAME:?GEN_TOPIC_NAME required for add-acl-existing}"
    KAFKA_USER=$(trim_ws "$KAFKA_USER")
    TOPIC_NAME=$(trim_ws "$TOPIC_NAME")
    validate_username "$KAFKA_USER"
    validate_topic_name "$TOPIC_NAME"
    status_msg "Checking user exists in all sites"
    for ((i=0;i<NUM_SITES;i++)); do
        _j=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[$i]}" --context "${SITE_CTX[$i]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
        [ -z "$_j" ] && error_exit "Could not read secret from site ${SITE_CTX[$i]}."
        echo "$_j" | jq -e --arg u "$KAFKA_USER" '.[$u]' >/dev/null 2>&1 || error_exit "User '$KAFKA_USER' not in site ${SITE_CTX[$i]} secret. Add user first."
    done
    done_msg
    status_msg "Validating topic '$TOPIC_NAME'"
    timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config "$ADMIN_CONFIG" --describe --topic "$TOPIC_NAME" > "$TMP_DIR/topic_out" 2>/dev/null || true
    [ -s "$TMP_DIR/topic_out" ] || error_exit "Topic '$TOPIC_NAME' not found or no permission."
    done_msg
    ACL_CHOICE="${GEN_ACL:-2}"
    case "$ACL_CHOICE" in
        1) ACL_OPS="Read,Describe,DescribeConfigs"; NEED_CONSUMER_GROUP=true ;;
        2) ACL_OPS="Read,Write,Describe,DescribeConfigs"; NEED_CONSUMER_GROUP=true ;;
        3|*) ACL_OPS="All"; NEED_CONSUMER_GROUP=true ;;
    esac
    status_msg "Adding ACL for User:$KAFKA_USER on topic $TOPIC_NAME"
    if [ "$ACL_OPS" = "All" ]; then
        acl_out=$($KAFKA_BIN/kafka-acls.sh --bootstrap-server $BOOTSTRAP_CWDC --command-config "$ADMIN_CONFIG" --add --allow-principal "User:$KAFKA_USER" --operation All --topic "$TOPIC_NAME" </dev/null 2>&1)
    else
        IFS=',' read -ra OPS <<< "$ACL_OPS"
        ACL_ARGS=()
        for op in "${OPS[@]}"; do ACL_ARGS+=("--operation" "$(echo "$op" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"); done
        acl_out=$($KAFKA_BIN/kafka-acls.sh --bootstrap-server $BOOTSTRAP_CWDC --command-config "$ADMIN_CONFIG" --add --allow-principal "User:$KAFKA_USER" "${ACL_ARGS[@]}" --topic "$TOPIC_NAME" </dev/null 2>&1)
    fi
    [ $? -ne 0 ] && { echo "$acl_out" | sed 's/^/   /'; error_exit "ADD_ACL_EXISTING" "ACL add failed."; }
    done_msg
    if [ "$NEED_CONSUMER_GROUP" = "true" ]; then
        status_msg "Adding consumer group Read for User:$KAFKA_USER"
        cg_acl_out=$($KAFKA_BIN/kafka-acls.sh --bootstrap-server $BOOTSTRAP_CWDC --command-config "$ADMIN_CONFIG" --add --allow-principal "User:$KAFKA_USER" --operation Read --group '*' 2>&1)
        [ $? -ne 0 ] && echo "$cg_acl_out" | sed 's/^/   /' || true
        done_msg
    fi
    log_action "ADD_ACL_EXISTING | user=$KAFKA_USER | topic=$TOPIC_NAME"
    echo -e "   ${GREEN}ACL added for User:$KAFKA_USER on topic $TOPIC_NAME${NC}"
    exit 0
fi

# Main menu loop
while true; do
    if [ "${GEN_NONINTERACTIVE}" = "1" ] && [ "${GEN_ADD_ONCE}" = "1" ]; then
        SCRIPT_MODE=1
        GEN_ADD_ONCE=""
    elif [ "${GEN_NONINTERACTIVE}" = "1" ] && [ "${GEN_RUN_MODE3}" = "1" ]; then
        SCRIPT_MODE=3
        GEN_RUN_MODE3=""
    else
        echo -e "\n${CYAN}MODE:${NC}"
        echo "   [1] Add new user (patch secret, ACL, validate, pack)"
        echo "   [2] Test existing user (auth only - verify user/pass without patch/restart)"
        echo "   [3] User management (remove user(s) + ACL, or change password)"
        echo "   [4] Create new topic (Kafka topic only; then use [1] to onboard user)"
        echo "   [5] Add ACL for existing user (add topic permission only; no new credential)"
        echo "   [6] Preflight — list Kafka topics (admin config; same check as web setup Verify)"
        echo "   [7] Go-Live verify — full check (OC+Kafka+all namespaces+optional Portal URL)"
        echo "   [8] Create Kafka client .properties templates (configs/; same as web setup save)"
        echo "   [Q] Quit"
        read -p "   Select mode [1-8/Q]: " SCRIPT_MODE
        [[ "$SCRIPT_MODE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit 0; }
        [[ "$SCRIPT_MODE" != "2" && "$SCRIPT_MODE" != "3" && "$SCRIPT_MODE" != "4" && "$SCRIPT_MODE" != "5" && "$SCRIPT_MODE" != "6" && "$SCRIPT_MODE" != "7" && "$SCRIPT_MODE" != "8" ]] && SCRIPT_MODE="1"
    fi

    if [ "$SCRIPT_MODE" == "5" ]; then
    # ADD ACL FOR EXISTING USER (no secret change)
    echo -e "\n-------------------------------------------------------"
    echo "  ADD ACL FOR EXISTING USER"
    echo "-------------------------------------------------------"
    read -p "   Enter username (must exist in secret): " KAFKA_USER
    KAFKA_USER=$(trim_ws "$KAFKA_USER")
    [ -z "$KAFKA_USER" ] && { echo -e "   ${YELLOW}Cancelled.${NC}"; continue; }
    validate_username "$KAFKA_USER"
    read -p "   Enter topic name: " TOPIC_NAME
    TOPIC_NAME=$(trim_ws "$TOPIC_NAME")
    [ -z "$TOPIC_NAME" ] && { echo -e "   ${YELLOW}Cancelled.${NC}"; continue; }
    validate_topic_name "$TOPIC_NAME"
    echo "   [1] Read  [2] Client (R+W+Describe)  [3] All"
    read -p "   ACL [1-3] (default 2): " ACL_CHOICE
    [[ -z "$ACL_CHOICE" ]] && ACL_CHOICE="2"
    status_msg "Checking user exists in all sites"
    for ((i=0;i<NUM_SITES;i++)); do
        _j=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[$i]}" --context "${SITE_CTX[$i]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
        [ -z "$_j" ] && { echo -e "   ${RED}Cannot read secret ${SITE_CTX[$i]}${NC}"; continue 2; }
        echo "$_j" | jq -e --arg u "$KAFKA_USER" '.[$u]' >/dev/null 2>&1 || { echo -e "   ${RED}User '$KAFKA_USER' not in ${SITE_CTX[$i]}.${NC}"; continue 2; }
    done
    done_msg
    status_msg "Validating topic '$TOPIC_NAME'"
    timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config "$ADMIN_CONFIG" --describe --topic "$TOPIC_NAME" > "$TMP_DIR/topic_out" 2>/dev/null || true
    [ -s "$TMP_DIR/topic_out" ] || { echo -e "   ${RED}Topic not found.${NC}"; continue; }
    done_msg
    case "$ACL_CHOICE" in
        1) ACL_OPS="Read,Describe,DescribeConfigs"; NEED_CONSUMER_GROUP=true ;;
        2) ACL_OPS="Read,Write,Describe,DescribeConfigs"; NEED_CONSUMER_GROUP=true ;;
        3|*) ACL_OPS="All"; NEED_CONSUMER_GROUP=true ;;
    esac
    status_msg "Adding ACL for User:$KAFKA_USER on topic $TOPIC_NAME"
    if [ "$ACL_OPS" = "All" ]; then
        acl_out=$($KAFKA_BIN/kafka-acls.sh --bootstrap-server $BOOTSTRAP_CWDC --command-config "$ADMIN_CONFIG" --add --allow-principal "User:$KAFKA_USER" --operation All --topic "$TOPIC_NAME" </dev/null 2>&1)
    else
        IFS=',' read -ra OPS <<< "$ACL_OPS"
        ACL_ARGS=()
        for op in "${OPS[@]}"; do ACL_ARGS+=("--operation" "$(echo "$op" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"); done
        acl_out=$($KAFKA_BIN/kafka-acls.sh --bootstrap-server $BOOTSTRAP_CWDC --command-config "$ADMIN_CONFIG" --add --allow-principal "User:$KAFKA_USER" "${ACL_ARGS[@]}" --topic "$TOPIC_NAME" </dev/null 2>&1)
    fi
    [ $? -ne 0 ] && { echo "$acl_out" | sed 's/^/   /'; echo -e "   ${RED}ACL add failed.${NC}"; continue; }
    done_msg
    if [ "$NEED_CONSUMER_GROUP" = "true" ]; then
        status_msg "Adding consumer group Read"
        $KAFKA_BIN/kafka-acls.sh --bootstrap-server $BOOTSTRAP_CWDC --command-config "$ADMIN_CONFIG" --add --allow-principal "User:$KAFKA_USER" --operation Read --group '*' 2>&1 | sed 's/^/   /'
        done_msg
    fi
    log_action "ADD_ACL_EXISTING | user=$KAFKA_USER | topic=$TOPIC_NAME"
    echo -e "   ${GREEN}ACL added for User:$KAFKA_USER on topic $TOPIC_NAME${NC}"
    echo -e "\n   ${CYAN}[M] Main menu  [Q] Quit${NC}"
    read -p "   Your choice [M/Q]: " ADD_ACL_CHOICE
    [[ "$ADD_ACL_CHOICE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit 0; }
    continue
    fi

    if [ "$SCRIPT_MODE" == "6" ]; then
    echo -e "\n-------------------------------------------------------"
    echo "  PREFLIGHT — Kafka admin (list topics)"
    echo "-------------------------------------------------------"
    echo "   Bootstrap: $BOOTSTRAP_CWDC"
    echo "   Admin config: $ADMIN_CONFIG"
    status_msg "kafka-topics.sh --list"
    list_out=$(timeout "$TIMEOUT_SEC" "$KAFKA_BIN/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP_CWDC" --command-config "$ADMIN_CONFIG" --list 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        done_msg
        echo "$list_out" | head -n 40 | sed 's/^/   /'
        echo -e "\n   ${GREEN}Preflight OK.${NC}"
    else
        echo "$list_out" | sed 's/^/   /'
        echo -e "\n   ${RED}Preflight failed (exit $rc).${NC}"
    fi
    echo -e "\n   ${CYAN}[M] Main menu  [Q] Quit${NC}"
    read -p "   Your choice [M/Q]: " PF6_CHOICE
    [[ "$PF6_CHOICE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit 0; }
    continue
    fi

    if [ "$SCRIPT_MODE" == "7" ]; then
    echo -e "\n-------------------------------------------------------"
    echo "  GO-LIVE VERIFY (scripts/verify-golive.sh)"
    echo "-------------------------------------------------------"
    _vsites=""
    for ((i=0;i<NUM_SITES;i++)); do
        [ -n "$_vsites" ] && _vsites="${_vsites},"
        _vsites="${_vsites}${SITE_CTX[$i]}:${SITE_NS[$i]}"
    done
    export GEN_OCP_SITES="$_vsites"
    export GEN_BASE_DIR="$BASE_DIR"
    export GEN_CLIENT_CONFIG="$CLIENT_CONFIG"
    export GEN_ADMIN_CONFIG="$ADMIN_CONFIG"
    export GEN_KAFKA_BIN="$KAFKA_BIN"
    export GEN_K8S_SECRET_NAME="$K8S_SECRET_NAME"
    export GEN_ENVIRONMENTS_JSON="$ENV_JSON"
    export GEN_VERIFY_BOOTSTRAP_CWDC="${BOOTSTRAP_CWDC}"
    export GEN_VERIFY_BOOTSTRAP_BOTH="${BOOTSTRAP_BOTH}"
    read -p "   Portal base URL for HTTP checks (optional, Enter=skip): " _golive_url
    _golive_url=$(trim_ws "${_golive_url:-}")
    if [ -n "$_golive_url" ]; then
        bash "$GOLIVE_VERIFY_SCRIPT" --from-gen-env --portal-url "$_golive_url"
    else
        bash "$GOLIVE_VERIFY_SCRIPT" --from-gen-env
    fi
    _golive_rc=$?
    echo -e "\n   ${CYAN}[M] Main menu  [Q] Quit${NC}"
    read -p "   Your choice [M/Q]: " GL_CHOICE
    [[ "$GL_CHOICE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit "${_golive_rc}"; }
    continue
    fi

    if [ "$SCRIPT_MODE" == "8" ]; then
    echo -e "\n-------------------------------------------------------"
    echo "  KAFKA CLIENT .PROPERTIES TEMPLATES (under \$BASE_DIR/configs/)"
    echo "-------------------------------------------------------"
    echo "   Creates kafka-client.properties + kafka-client-master.properties if missing."
    echo "   Default bootstrap: $BOOTSTRAP_CWDC"
    read -p "   Bootstrap servers (Enter=default): " _boot8
    _boot8=$(trim_ws "${_boot8:-}")
    [ -z "$_boot8" ] && _boot8="$BOOTSTRAP_CWDC"
    _ENSURE="${SCRIPT_DIR}/scripts/ensure-kafka-client-props.sh"
    [ ! -f "$_ENSURE" ] && [ -f /opt/kafka-usermgmt/ensure-kafka-client-props.sh ] && _ENSURE=/opt/kafka-usermgmt/ensure-kafka-client-props.sh
    if [ ! -f "$_ENSURE" ]; then
        echo -e "   ${RED}ensure-kafka-client-props.sh not found.${NC}"
    else
        bash "$_ENSURE" "$BASE_DIR" "$_boot8"
    fi
    echo -e "\n   ${CYAN}[M] Main menu  [Q] Quit${NC}"
    read -p "   Your choice [M/Q]: " P8_CHOICE
    [[ "$P8_CHOICE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit 0; }
    continue
    fi

    if [ "$SCRIPT_MODE" == "4" ]; then
    # CREATE NEW TOPIC (broker default partitions/replication — rack-aware placement)
    echo -e "\n-------------------------------------------------------"
    echo "  CREATE NEW KAFKA TOPIC"
    echo "-------------------------------------------------------"
    echo "   Partitions and replication factor use broker default (rack-aware)."
    read -p "   Enter Topic Name: " CREATE_TOPIC_INPUT
    CREATE_TOPIC_NAME=$(trim_ws "$CREATE_TOPIC_INPUT")
    validate_topic_name "$CREATE_TOPIC_NAME"
    status_msg "Creating topic '$CREATE_TOPIC_NAME' (broker default)"
    create_out=$($KAFKA_BIN/kafka-topics.sh --create \
        --topic "$CREATE_TOPIC_NAME" \
        --bootstrap-server "$BOOTSTRAP_BOTH" \
        --command-config "$ADMIN_CONFIG" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        done_msg
        echo -e "   ${GREEN}Topic '$CREATE_TOPIC_NAME' created. Use mode [1] to add a user for this topic.${NC}"
        log_action "CREATE_TOPIC | topic=$CREATE_TOPIC_NAME"
    else
        echo "$create_out" | sed 's/^/   /'
        echo -e "   ${RED}Create topic failed (exit $rc). Topic may already exist.${NC}"
    fi
    echo -e "\n   ${CYAN}Options: [M] Main menu  [Q] Quit${NC}"
    read -p "   Your choice [M/Q]: " CREATE_CHOICE
    [[ "$CREATE_CHOICE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit 0; }
    continue
    fi

    if [ "$SCRIPT_MODE" == "2" ]; then
    # TEST EXISTING USER - no patch, no restart, no ACL
    echo -e "\n-------------------------------------------------------"
    echo "  TEST EXISTING USER (auth only)"
    echo "-------------------------------------------------------"
    if [ "${GEN_NONINTERACTIVE}" != "1" ]; then
        read -p "   Enter Kafka Username: " KAFKA_USER
        validate_username "$KAFKA_USER"
        read -s -p "   Enter Password: " TEST_PASS; echo
        [ -z "$TEST_PASS" ] && error_exit "Password is required."
        echo -e "\n   ${CYAN}Select topic for validation (or 'L' to list):${NC}"
        status_msg "Fetching topics"
        $KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config $ADMIN_CONFIG --list > $TMP_DIR/topics.list 2>/dev/null
        done_msg
        cat $TMP_DIR/topics.list
        read -p "   Enter Topic Name: " TOPIC_NAME
        [ -z "$TOPIC_NAME" ] && error_exit "Topic is required."
    fi

    echo -e "\n   ${CYAN}Testing auth with User:$KAFKA_USER on each bootstrap...${NC}"
    SSL_LINES=$(grep -E '^ssl\.truststore\.(location|password)' "$ADMIN_CONFIG" 2>/dev/null)
    [ -z "$SSL_LINES" ] && SSL_LINES=$(grep -E '^ssl\.truststore\.(location|password)' "$CLIENT_CONFIG" 2>/dev/null)
    [ -z "$SSL_LINES" ] && error_exit "Could not find ssl.truststore in config."
    SAFE_PASS="${TEST_PASS//\"/\\\"}"
    TEMP_CFG="$TMP_DIR/gen_test_$$.properties"

    for entry in "$BOOTSTRAP_CWDC:1" "$BOOTSTRAP_TLS2:2"; do
        label="bootstrap${entry##*:}"
        bootstrap="${entry%:*}"
        {
            echo "bootstrap.servers=$bootstrap"
            echo "security.protocol=SASL_SSL"
            echo "sasl.mechanism=PLAIN"
            echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$KAFKA_USER\" password=\"$SAFE_PASS\";"
            echo "$SSL_LINES"
        } > "$TEMP_CFG"
        status_msg "Auth test ($label)"
        out=$(timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server "$bootstrap" --command-config "$TEMP_CFG" --describe --topic "$TOPIC_NAME" 2>&1)
        rc=$?
        if [ $rc -eq 0 ]; then
            done_msg
            echo -e "   ${GREEN}User $KAFKA_USER: AUTH OK on $label${NC}"
        else
            echo -e "\n   ${RED}User $KAFKA_USER: AUTH FAILED on $label (exit $rc)${NC}"
            echo "$out" | sed 's/^/   /'
        fi
    done

    # List ACLs for this user (requires admin config)
    echo -e "\n-------------------------------------------------------"
    echo "  ACL LIST for User:$KAFKA_USER"
    echo "-------------------------------------------------------"
    acl_list=$($KAFKA_BIN/kafka-acls.sh --bootstrap-server $BOOTSTRAP_CWDC --command-config $ADMIN_CONFIG --list --principal "User:$KAFKA_USER" </dev/null 2>&1)
    if [ $? -eq 0 ] && [ -n "$acl_list" ]; then
        echo "$acl_list" | sed 's/^/   /'
    else
        echo -e "   ${YELLOW}(No ACLs found or cannot list - user may have no explicit permissions)${NC}"
        [ -n "$acl_list" ] && echo "$acl_list" | sed 's/^/   /'
    fi

    # Optional: Describe topic or Consume messages (skip in non-interactive)
    if [ "${GEN_NONINTERACTIVE}" != "1" ]; then
        echo -e "\n-------------------------------------------------------"
        echo "  ADDITIONAL TEST (topic: $TOPIC_NAME)"
        echo "-------------------------------------------------------"
        echo "   [1] Describe topic (show partitions, config)"
        echo "   [2] Consume sample (up to 5 msgs from topic)"
        echo "   [3] Skip / Done"
        read -p "   Select [1-3]: " EXTRA_CHOICE
    else
        EXTRA_CHOICE=3
    fi
    if [[ "$EXTRA_CHOICE" == "1" ]]; then
        {
            echo "bootstrap.servers=$BOOTSTRAP_BOTH"
            echo "security.protocol=SASL_SSL"
            echo "sasl.mechanism=PLAIN"
            echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$KAFKA_USER\" password=\"$SAFE_PASS\";"
            echo "$SSL_LINES"
        } > "$TEMP_CFG"
        echo -e "\n   ${CYAN}--- Topic: $TOPIC_NAME ---${NC}"
        $KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config "$TEMP_CFG" --describe --topic "$TOPIC_NAME" 2>&1 | sed 's/^/   /'
        echo -e "   ${CYAN}-------------------${NC}"
    elif [[ "$EXTRA_CHOICE" == "2" ]]; then
        {
            echo "bootstrap.servers=$BOOTSTRAP_BOTH"
            echo "security.protocol=SASL_SSL"
            echo "sasl.mechanism=PLAIN"
            echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$KAFKA_USER\" password=\"$SAFE_PASS\";"
            echo "$SSL_LINES"
        } > "$TEMP_CFG"
        echo -e "\n   ${CYAN}--- Last 5 messages from $TOPIC_NAME ---${NC}"
        $KAFKA_BIN/kafka-console-consumer.sh --bootstrap-server $BOOTSTRAP_BOTH --topic "$TOPIC_NAME" --consumer.config "$TEMP_CFG" --from-beginning --max-messages $CONSUME_MAX_MESSAGES --timeout-ms $VALIDATE_CONSUME_TIMEOUT_MS 2>&1 | sed 's/^/   /'
        echo -e "   ${CYAN}-------------------${NC}"
    fi

        echo -e "\n${CYAN}Test complete.${NC}"
        [ "${GEN_NONINTERACTIVE}" = "1" ] && exit 0
        echo -e "\n   ${CYAN}Options:${NC}"
        echo "   [M] Main menu"
        echo "   [Q] Quit"
        read -p "   Your choice [M/Q]: " TEST_CHOICE
        [[ "$TEST_CHOICE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit 0; }
        [[ "$TEST_CHOICE" =~ ^[Mm]$ ]] && continue
        continue  # Default: go back to main menu
    fi

    if [ "$SCRIPT_MODE" == "3" ]; then
    # USER MANAGEMENT (Remove or Change Password) - Loop until user chooses to exit
    while true; do
        if [ "${GEN_MANAGE_ONCE}" != "1" ]; then
            echo -e "\n-------------------------------------------------------"
            echo "  USER MANAGEMENT"
            echo "-------------------------------------------------------"
            echo "   [1] Remove user(s) and ACL (multi-select allowed)"
            echo "   [2] Change password (single user only)"
            echo "   [3] Cleanup orphaned ACLs (users deleted but ACLs remain)"
            echo "   [M] Main menu"
            echo "   [Q] Quit"
            read -p "   Select action [1-3/M/Q]: " ACTION_CHOICE
            [[ "$ACTION_CHOICE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit 0; }
            [[ "$ACTION_CHOICE" =~ ^[Mm]$ ]] && break
        else
            ACTION_CHOICE="${GEN_ACTION:-1}"
        fi
        [[ "$ACTION_CHOICE" != "2" && "$ACTION_CHOICE" != "3" ]] && ACTION_CHOICE="1"
        
        # Handle Cleanup Orphaned ACLs separately (doesn't need users in secret)
        if [ "$ACTION_CHOICE" == "3" ]; then
            :
        else
            # For actions 1 and 2, we need users in secret (skip fetch if already set by non-interactive)
            if [ -z "$USER_LIST" ]; then
                echo -e "   ${CYAN}Fetching existing users from secret...${NC}"
                JSON_CWDC=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[0]}" --context "${SITE_CTX[0]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
                if [ -z "$JSON_CWDC" ]; then
                    error_exit "Could not retrieve users from site ${SITE_CTX[0]} secret"
                fi
                USER_LIST=$(echo "$JSON_CWDC" | jq -r 'keys[]' | grep -vE "$SYSTEM_USERS" | sort)
            fi
            if [ -z "$USER_LIST" ]; then
                echo -e "   ${YELLOW}No manageable users found (only system users exist).${NC}"
                [ "${GEN_MANAGE_ONCE}" = "1" ] && exit 1
                echo -e "   ${CYAN}Press Enter to continue...${NC}"
                read
                continue
            fi
        fi
        
        if [ "$ACTION_CHOICE" == "1" ]; then
            # ========== REMOVE USER(S) AND ACL ==========
            if [ ${#SELECTED_USERS[@]} -eq 0 ]; then
            USER_ARRAY=()
            SELECTED_USERS=()
            idx=1
            while IFS= read -r user; do
                USER_ARRAY+=("$user")
                idx=$((idx + 1))
            done <<< "$USER_LIST"
            TOTAL_USERS=$((idx - 1))
            
            # Selection loop
            while true; do
                echo -e "\n   ${CYAN}--- Select Users to Remove (multiple selection) ---${NC}"
                idx=1
                for user in "${USER_ARRAY[@]}"; do
                    if [[ " ${SELECTED_USERS[@]} " =~ " ${user} " ]]; then
                        echo -e "   ${GREEN}[x]${NC} [$idx] $user"
                    else
                        echo "   [ ] [$idx] $user"
                    fi
                    idx=$((idx + 1))
                done
                echo ""
                echo "   Commands:"
                echo "   - Enter number(s) to toggle: 1,3,5 or 1-5 or all"
                echo "   - [D] Done (proceed with selected)"
                echo "   - [C] Clear all"
                echo "   - [Q] Quit"
                echo -e "   ${CYAN}-------------------------------------------${NC}"
                [ ${#SELECTED_USERS[@]} -gt 0 ] && echo -e "   ${YELLOW}Selected: ${SELECTED_USERS[*]}${NC}"
                read -p "   Your choice: " SELECTION
                
                [[ "$SELECTION" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Cancelled.${NC}"; exit 0; }
                [[ "$SELECTION" =~ ^[Dd]$ ]] && break
                [[ "$SELECTION" =~ ^[Cc]$ ]] && { SELECTED_USERS=(); continue; }
                
                # Handle "all"
                if [[ "$SELECTION" =~ ^[Aa][Ll][Ll]$ ]]; then
                    SELECTED_USERS=("${USER_ARRAY[@]}")
                    continue
                fi
                
                # Handle range (e.g., 1-5)
                if [[ "$SELECTION" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    start="${BASH_REMATCH[1]}"
                    end="${BASH_REMATCH[2]}"
                    if [ "$start" -ge 1 ] && [ "$end" -le "$TOTAL_USERS" ] && [ "$start" -le "$end" ]; then
                        for i in $(seq $start $end); do
                            user="${USER_ARRAY[$((i-1))]}"
                            if [[ " ${SELECTED_USERS[@]} " =~ " ${user} " ]]; then
                                SELECTED_USERS=("${SELECTED_USERS[@]/$user}")
                            else
                                SELECTED_USERS+=("$user")
                            fi
                        done
                        # Remove empty elements
                        SELECTED_USERS=("${SELECTED_USERS[@]// /}")
                    fi
                    continue
                fi
                
                # Handle comma-separated or single numbers
                IFS=',' read -ra NUMS <<< "$SELECTION"
                for num in "${NUMS[@]}"; do
                    num=$(echo "$num" | tr -d ' ')
                    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$TOTAL_USERS" ]; then
                        user="${USER_ARRAY[$((num-1))]}"
                        if [[ " ${SELECTED_USERS[@]} " =~ " ${user} " ]]; then
                            # Toggle off
                            SELECTED_USERS=("${SELECTED_USERS[@]/$user}")
                            SELECTED_USERS=("${SELECTED_USERS[@]// /}")
                        else
                            # Toggle on
                            SELECTED_USERS+=("$user")
                        fi
                    fi
                done
            done
            fi
            
            # Check if any users selected
            if [ ${#SELECTED_USERS[@]} -eq 0 ]; then
                echo -e "   ${YELLOW}No users selected. Cancelled.${NC}"
                [ "${GEN_MANAGE_ONCE}" = "1" ] && exit 1
                exit 0
            fi
            
            TOTAL_USERS=$(echo "$USER_LIST" | wc -l)
            # Confirm removal (skip in non-interactive)
            echo -e "\n   ${YELLOW}⚠️  WARNING: This will remove ${#SELECTED_USERS[@]} user(s):${NC}"
            for user in "${SELECTED_USERS[@]}"; do
                echo -e "   ${YELLOW}   - User: $user${NC}"
            done
            echo -e "   ${YELLOW}   Actions (in order):${NC}"
            echo -e "   ${YELLOW}   1. Delete ALL ACLs first (topics + consumer groups)${NC}"
            echo -e "   ${YELLOW}   2. Then remove from secrets (all $NUM_SITES site(s))${NC}"
            echo -e "   ${CYAN}   Note: ACLs are removed first to ensure user still exists during ACL deletion.${NC}"
            if [ ${#SELECTED_USERS[@]} -eq "$TOTAL_USERS" ] && [ "$TOTAL_USERS" -gt 0 ]; then
                echo -e "   ${RED}   ⚠️  WARNING: You are about to remove ALL $TOTAL_USERS user(s) in the secret!${NC}"
                echo -e "   ${RED}   This will leave only system users. Confirm only if intentional.${NC}"
            fi
            if [ "${GEN_MANAGE_ONCE}" != "1" ]; then
                read -p "   Continue? [y/N]: " confirm
                [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "   ${CYAN}Cancelled.${NC}"; exit 0; }
            fi
            
            # ---------- VALIDATION PHASE (no destructive action yet) ----------
            echo -e "\n-------------------------------------------------------"
            echo "  REMOVE: VALIDATION (pre-check before any change)"
            echo "-------------------------------------------------------"
            for ((i=0;i<NUM_SITES;i++)); do
                status_msg "Reading secret from ${SITE_CTX[$i]} (${SITE_NS[$i]})"
                _j=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[$i]}" --context "${SITE_CTX[$i]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
                [ -z "$_j" ] && error_exit "REMOVE_VALIDATE" "Could not read secret from site ${SITE_CTX[$i]} (${SITE_NS[$i]}). Aborting without changes."
                SITE_JSON_ORIG[$i]="$_j"
                done_msg
            done
            for REMOVE_USER in "${SELECTED_USERS[@]}"; do
                for ((i=0;i<NUM_SITES;i++)); do
                    echo "${SITE_JSON_ORIG[$i]}" | jq -e --arg u "$REMOVE_USER" '.[$u]' >/dev/null 2>&1 || error_exit "REMOVE_VALIDATE" "User '$REMOVE_USER' not found in site ${SITE_CTX[$i]} secret. Aborting without changes."
                done
            done
            echo -e "   ${GREEN}✅ All selected users present in all $NUM_SITES secret(s). Proceeding.${NC}"
            
            # Remove ACLs FIRST (before removing user from secret)
            # This ensures user still exists when removing ACLs, avoiding potential issues
            echo -e "\n-------------------------------------------------------"
            echo "  REMOVING ACLs FOR SELECTED USERS (STEP 1/2)"
            echo "-------------------------------------------------------"
            
            for REMOVE_USER in "${SELECTED_USERS[@]}"; do
                echo -e "   ${CYAN}Processing User: $REMOVE_USER${NC}"
                
                # Step 1: List all ACLs for this user
                status_msg "Listing ACLs for User:$REMOVE_USER"
                acl_list=$($KAFKA_BIN/kafka-acls.sh \
                  --bootstrap-server $BOOTSTRAP_CWDC \
                  --command-config "$ADMIN_CONFIG" \
                  --list \
                  --principal "User:$REMOVE_USER" </dev/null 2>&1)
                
                if [ $? -ne 0 ] || [ -z "$acl_list" ]; then
                    echo -e "   ${YELLOW}No ACLs found or cannot list ACLs for User:$REMOVE_USER${NC}"
                    done_msg
                    continue
                fi
                done_msg
                
                # Step 2: Parse ACL list and remove each ACL individually
                # Parse format: Current ACLs for resource `ResourcePattern(resourceType=TYPE, name=NAME, patternType=TYPE)`
                # Then: (principal=User:xxx, host=*, operation=OP, permissionType=ALLOW)
                
                status_msg "Removing ACLs for User:$REMOVE_USER"
                acl_removed_count=0
                acl_failed_count=0
                current_resource_type=""
                current_resource_name=""
                current_pattern_type=""
                
                # Save ACL list to temp file for processing
                acl_temp_file="$TMP_DIR/acl_list_${REMOVE_USER}_$$.txt"
                echo "$acl_list" > "$acl_temp_file"
                
                # Parse and remove ACLs
                while IFS= read -r line; do
                    # Check for resource header line: Current ACLs for resource `ResourcePattern(...)`
                    # Use string matching and sed for extraction (more compatible than grep -oP)
                    if echo "$line" | grep -q "ResourcePattern"; then
                        # Extract resource type
                        if echo "$line" | grep -q "resourceType=TOPIC"; then
                            current_resource_type="TOPIC"
                        elif echo "$line" | grep -q "resourceType=GROUP"; then
                            current_resource_type="GROUP"
                        else
                            current_resource_type=""
                            continue
                        fi
                        
                        # Extract resource name (between name= and comma or closing paren)
                        resource_name_match=$(echo "$line" | sed -n 's/.*name=\([^,)]*\).*/\1/p')
                        resource_name_match=$(trim_ws "$resource_name_match")
                        if [ -n "$resource_name_match" ]; then
                            current_resource_name="$resource_name_match"
                        else
                            current_resource_name=""
                            continue
                        fi
                        
                        # Extract pattern type (trim to avoid "LITERAL " etc.)
                        pattern_type_match=$(echo "$line" | sed -n 's/.*patternType=\([^)]*\).*/\1/p')
                        pattern_type_match=$(trim_ws "$pattern_type_match")
                        if [ -n "$pattern_type_match" ]; then
                            current_pattern_type="$pattern_type_match"
                        else
                            current_pattern_type="LITERAL"  # Default
                        fi
                        continue
                    fi
                    
                    # Check for ACL entry line with our user: (principal=User:xxx, ...)
                    # Match exact user - next char must be comma, closing paren, or space (so "kokoko" doesn't match "kokoko2")
                    if echo "$line" | grep -qE "principal=User:${REMOVE_USER}(,|\)|[[:space:]])"; then
                        # Extract operation (trim in case of trailing space)
                        operation_match=$(echo "$line" | sed -n 's/.*operation=\([^,]*\).*/\1/p')
                        operation_match=$(trim_ws "$operation_match")
                        if [ -n "$operation_match" ]; then
                            operation="$operation_match"
                        else
                            continue
                        fi
                        
                        if [ -z "$current_resource_type" ] || [ -z "$current_resource_name" ] || [ -z "$operation" ]; then
                            continue
                        fi
                        
                        # Remove ACL based on resource type (with retry on timeout/disconnect)
                        op_cli=$(acl_operation_for_remove "$operation")
                        acl_remove_cfg=$(get_acl_remove_config)
                        if [ "$current_resource_type" == "TOPIC" ]; then
                            remove_out=$(run_acl_remove "$BOOTSTRAP_CWDC" "$acl_remove_cfg" "User:$REMOVE_USER" "$op_cli" "--topic" "$current_resource_name" "$current_pattern_type")
                            rc=$?
                            if [ $rc -eq 0 ]; then
                                acl_removed_count=$((acl_removed_count + 1))
                            else
                                acl_failed_count=$((acl_failed_count + 1))
                                echo -e "   ${YELLOW}⚠️  Failed to remove: topic=$current_resource_name, op=$operation${NC}"
                                [ -n "$remove_out" ] && echo -e "   ${YELLOW}   $remove_out${NC}"
                            fi
                        elif [ "$current_resource_type" == "GROUP" ]; then
                            remove_out=$(run_acl_remove "$BOOTSTRAP_CWDC" "$acl_remove_cfg" "User:$REMOVE_USER" "$op_cli" "--group" "$current_resource_name" "$current_pattern_type")
                            rc=$?
                            if [ $rc -eq 0 ]; then
                                acl_removed_count=$((acl_removed_count + 1))
                            else
                                acl_failed_count=$((acl_failed_count + 1))
                                echo -e "   ${YELLOW}⚠️  Failed to remove: group=$current_resource_name, op=$operation${NC}"
                                [ -n "$remove_out" ] && echo -e "   ${YELLOW}   $remove_out${NC}"
                            fi
                        fi
                    fi
                done < "$acl_temp_file"
                
                rm -f "$acl_temp_file"
                
                if [ $acl_removed_count -gt 0 ]; then
                    echo -e "   ${GREEN}✅ Removed $acl_removed_count ACL(s)${NC}"
                    [ $acl_failed_count -gt 0 ] && echo -e "   ${YELLOW}⚠️  Failed to remove $acl_failed_count ACL(s)${NC}"
                else
                    echo -e "   ${YELLOW}⚠️  No ACLs removed (may already be deleted)${NC}"
                fi
                done_msg
            done
            
            # Remove from secrets AFTER ACLs are removed — commit BOTH or NONE (rollback on second failure)
            echo -e "\n-------------------------------------------------------"
            echo "  REMOVING USERS FROM SECRETS (STEP 2/2)"
            echo "-------------------------------------------------------"
            for ((i=0;i<NUM_SITES;i++)); do
                NEW_JSON[$i]=$(echo "${SITE_JSON_ORIG[$i]}" | jq --argjson users "$(printf '%s\n' "${SELECTED_USERS[@]}" | jq -R . | jq -s .)" 'reduce $users[] as $u (.; del(.[$u]))' 2>/dev/null)
                [ $? -ne 0 ] && error_exit "REMOVE_SECRET" "jq failed building new JSON for site ${SITE_CTX[$i]}. No changes applied."
            done
            for ((i=0;i<NUM_SITES;i++)); do
                status_msg "Patching ${SITE_CTX[$i]} (${SITE_NS[$i]})"
                _b64=$(echo -n "${NEW_JSON[$i]}" | base64 | tr -d '\n')
                if ! oc patch secret $K8S_SECRET_NAME -n "${SITE_NS[$i]}" --context "${SITE_CTX[$i]}" --type='merge' -p "{\"data\":{\"plain-users.json\":\"$_b64\"}}" &>/dev/null; then
                    [ $i -gt 0 ] && echo -e "\n   ${RED}❌ Patch failed for site ${SITE_CTX[$i]}. Reverting previous site(s).${NC}"
                    for ((j=0;j<i;j++)); do
                        _orig_b64=$(echo -n "${SITE_JSON_ORIG[$j]}" | base64 | tr -d '\n')
                        oc patch secret $K8S_SECRET_NAME -n "${SITE_NS[$j]}" --context "${SITE_CTX[$j]}" --type='merge' -p "{\"data\":{\"plain-users.json\":\"$_orig_b64\"}}" &>/dev/null
                    done
                    error_exit "REMOVE_SECRET" "Patch failed for site ${SITE_CTX[$i]}. Previous site(s) reverted. No partial commit."
                fi
                done_msg
            done
            status_msg "Verifying remove (users absent from all secrets)"
            for REMOVE_USER in "${SELECTED_USERS[@]}"; do
                for ((i=0;i<NUM_SITES;i++)); do
                    verify_user_absent_from_secret "${SITE_CTX[$i]}" "${SITE_NS[$i]}" "$REMOVE_USER" || error_exit "Site ${SITE_CTX[$i]} verify remove failed for $REMOVE_USER."
                done
            done
            done_msg
            log_action "DELETE | what=remove_users_and_ACLs | users=${SELECTED_USERS[*]} | namespaces=${SITE_NS[*]} | secret=$K8S_SECRET_NAME"
            
            echo -e "\n${GREEN}✅ ${#SELECTED_USERS[@]} user(s) and all ACLs removed successfully!${NC}"
            echo -e "   ${CYAN}Removed users: ${SELECTED_USERS[*]}${NC}"
            echo -e "   ${CYAN}Note: CFK will hot-reload credentials (~30-60s). Users will be inaccessible after reload.${NC}"
            
            # Rescan and show remaining users
            echo -e "\n-------------------------------------------------------"
            echo "  RESCAN: REMAINING USERS"
            echo "-------------------------------------------------------"
            status_msg "Fetching updated user list"
            JSON_CWDC=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[0]}" --context "${SITE_CTX[0]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
            if [ -n "$JSON_CWDC" ]; then
                done_msg
                REMAINING_USERS=$(echo "$JSON_CWDC" | jq -r 'keys[]' | grep -vE "$SYSTEM_USERS" | sort)
                if [ -n "$REMAINING_USERS" ]; then
                    echo -e "\n   ${CYAN}Remaining manageable users:${NC}"
                    idx=1
                    while IFS= read -r user; do
                        echo "   [$idx] $user"
                        idx=$((idx + 1))
                    done <<< "$REMAINING_USERS"
                else
                    echo -e "\n   ${YELLOW}No remaining manageable users (only system users exist).${NC}"
                fi
            else
                echo -e "\n   ${YELLOW}Could not fetch updated user list.${NC}"
            fi
            
            [ "${GEN_MANAGE_ONCE}" = "1" ] && { GEN_MANAGE_ONCE=""; exit 0; }
            echo -e "\n   ${CYAN}Options:${NC}"
            echo "   [1] Remove more users (back to selection menu)"
            echo "   [M] Main menu"
            echo "   [Q] Quit"
            read -p "   Your choice [1/M/Q]: " CONTINUE_CHOICE
            [[ "$CONTINUE_CHOICE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit 0; }
            [[ "$CONTINUE_CHOICE" =~ ^[Mm]$ ]] && break
            # [1] Remove more: clear selection and force re-fetch user list so we don't repeat the same remove
            if [[ "$CONTINUE_CHOICE" =~ ^[1]$ ]]; then
                SELECTED_USERS=()
                USER_LIST=""
                continue
            fi
        fi
        
        if [ "$ACTION_CHOICE" == "2" ]; then
            # ========== CHANGE PASSWORD (SINGLE USER ONLY) ==========
            if [ -z "$CHANGE_USER" ]; then
            echo -e "\n   ${CYAN}--- Select User to Change Password (single selection) ---${NC}"
            USER_ARRAY=()
            idx=1
            while IFS= read -r user; do
                echo "   [$idx] $user"
                USER_ARRAY+=("$user")
                idx=$((idx + 1))
            done <<< "$USER_LIST"
            echo "   [Q] Quit"
            echo -e "   ${CYAN}-------------------------------------------${NC}"
            read -p "   Select user [1-$((idx-1))] or Q: " SELECTION
            [[ "$SELECTION" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Cancelled.${NC}"; exit 0; }
            if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le $((idx-1)) ]; then
                CHANGE_USER="${USER_ARRAY[$((SELECTION-1))]}"
            else
                error_exit "Invalid selection"
            fi
            fi
            echo -e "\n-------------------------------------------------------"
            echo "  CHANGE PASSWORD FOR User:$CHANGE_USER"
            echo "-------------------------------------------------------"
            if [ -z "$NEW_PASS" ]; then
            status_msg "Generating ${PASSWORD_LENGTH}-character Secure Password"
            NEW_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c $PASSWORD_LENGTH)
            done_msg
            fi
            
            # ---------- VALIDATION: user must exist in both secrets before we patch ----------
            echo -e "\n-------------------------------------------------------"
            echo "  CHANGE PASSWORD: VALIDATION (pre-check)"
            echo "-------------------------------------------------------"
            for ((i=0;i<NUM_SITES;i++)); do
                status_msg "Reading secret from ${SITE_CTX[$i]} (${SITE_NS[$i]})"
                _j=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[$i]}" --context "${SITE_CTX[$i]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
                [ -z "$_j" ] && error_exit "CHANGE_PW_VALIDATE" "Could not read secret from site ${SITE_CTX[$i]} (${SITE_NS[$i]}). Aborting without changes."
                CHG_SITE_JSON_ORIG[$i]="$_j"
                done_msg
            done
            for ((i=0;i<NUM_SITES;i++)); do
                echo "${CHG_SITE_JSON_ORIG[$i]}" | jq -e --arg u "$CHANGE_USER" '.[$u]' >/dev/null 2>&1 || error_exit "CHANGE_PW_VALIDATE" "User '$CHANGE_USER' not in site ${SITE_CTX[$i]} secret. Aborting without changes."
            done
            echo -e "   ${GREEN}✅ User present in all $NUM_SITES secret(s). Proceeding.${NC}"
            
            # Update secrets — commit all or none (rollback previous on any failure)
            echo -e "\n-------------------------------------------------------"
            echo "  UPDATING SECRETS (all $NUM_SITES site(s))"
            echo "-------------------------------------------------------"
            for ((i=0;i<NUM_SITES;i++)); do
                CHG_UPDATED[$i]=$(echo "${CHG_SITE_JSON_ORIG[$i]}" | jq -c --arg user "$CHANGE_USER" --arg pass "$NEW_PASS" '.[$user] = $pass' 2>/dev/null)
                [ $? -ne 0 ] && error_exit "CHANGE_PW_SECRET" "jq failed for site ${SITE_CTX[$i]}. No changes applied."
            done
            for ((i=0;i<NUM_SITES;i++)); do
                status_msg "Patching ${SITE_CTX[$i]} (${SITE_NS[$i]})"
                _b64=$(echo -n "${CHG_UPDATED[$i]}" | base64 | tr -d '\n')
                if ! oc patch secret $K8S_SECRET_NAME -n "${SITE_NS[$i]}" --context "${SITE_CTX[$i]}" --type='merge' -p "{\"data\":{\"plain-users.json\":\"$_b64\"}}" &>/dev/null; then
                    [ $i -gt 0 ] && echo -e "\n   ${RED}❌ Patch failed for site ${SITE_CTX[$i]}. Reverting previous site(s).${NC}"
                    for ((j=0;j<i;j++)); do
                        _orig_b64=$(echo -n "${CHG_SITE_JSON_ORIG[$j]}" | base64 | tr -d '\n')
                        oc patch secret $K8S_SECRET_NAME -n "${SITE_NS[$j]}" --context "${SITE_CTX[$j]}" --type='merge' -p "{\"data\":{\"plain-users.json\":\"$_orig_b64\"}}" &>/dev/null
                    done
                    error_exit "CHANGE_PW_SECRET" "Patch failed for site ${SITE_CTX[$i]}. Previous site(s) reverted. No partial commit."
                fi
                done_msg
            done
            status_msg "Verifying patch (user present in all secrets)"
            for ((i=0;i<NUM_SITES;i++)); do
                verify_user_in_secret "${SITE_CTX[$i]}" "${SITE_NS[$i]}" "$CHANGE_USER" || error_exit "Site ${SITE_CTX[$i]} verification failed after password change."
            done
            done_msg
            
            # Ask if user wants to add Topic + ACL
            echo -e "\n-------------------------------------------------------"
            echo "  ADD TOPIC + ACL (OPTIONAL)"
            echo "-------------------------------------------------------"
            if [ "${GEN_MANAGE_ONCE}" != "1" ]; then
                read -p "   Do you want to add Topic + ACL for this user? [y/N]: " ADD_TOPIC_ACL
            else
                ADD_TOPIC_ACL="n"
            fi
            TOPIC_NAME=""
            ACL_DESC=""
            ACL_OPS=""
            NEED_CONSUMER_GROUP=false
            if [[ "$ADD_TOPIC_ACL" =~ ^[Yy]$ ]]; then
                # Topic validation (same as Add new user)
                echo -e "\n2. TOPIC VALIDATION"
                while true; do
                    read -p "   Enter Topic Name (or 'L' to list all, 'Q' to quit): " TOPIC_INPUT
                    [[ "$TOPIC_INPUT" =~ ^[Qq]$ ]] && break
                    if [[ "$TOPIC_INPUT" =~ ^[Ll]$ ]]; then
                        status_msg "Fetching All Topics from Cluster"
                        ($KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config $ADMIN_CONFIG --list > $TMP_DIR/topics.list 2> $TMP_DIR/topics.list.err) &
                        spinner $!
                        wait $!
                        echo -e "\n${CYAN}--- Available Topics ---${NC}"
                        if [ -s $TMP_DIR/topics.list ]; then
                            cat $TMP_DIR/topics.list
                        else
                            echo "   (none or error)"
                            [ -s $TMP_DIR/topics.list.err ] && echo -e "   ${RED}Error:${NC}" && cat $TMP_DIR/topics.list.err | sed 's/^/   /'
                            echo "   Check: KAFKA_BIN=$KAFKA_BIN, ADMIN_CONFIG=$ADMIN_CONFIG, bootstrap=$BOOTSTRAP_BOTH"
                        fi
                        echo -e "${CYAN}------------------------${NC}"; continue
                    fi
                    status_msg "Validating Topic '$TOPIC_INPUT'"
                    timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config $ADMIN_CONFIG --describe --topic $TOPIC_INPUT > $TMP_DIR/topic_out 2>/dev/null &
                    PID=$!; spinner $PID; wait $PID
                    if [ $? -eq 0 ] && [ -s $TMP_DIR/topic_out ]; then
                        done_msg; TOPIC_NAME=$TOPIC_INPUT; break
                    else
                        echo -e "\n   ${RED}❌ NOT FOUND: Topic '$TOPIC_INPUT' doesn't exist (or no permission).${NC}"
                    fi
                done
                
                if [ -n "$TOPIC_NAME" ]; then
                    # ACL selection (same as Add new user)
                    echo -e "\n-------------------------------------------------------"
                    echo "  ADD ACL (for topic: $TOPIC_NAME)"
                    echo "-------------------------------------------------------"
                    echo "   Select permission level:"
                    echo "   [1] Read (R) - consume only"
                    echo "   [2] Client - Produce + Consume + Describe (recommended)"
                    echo "   [3] All - full access"
                    read -p "   Select [1-3] (default: 2): " ACL_CHOICE
                    [[ -z "$ACL_CHOICE" ]] && ACL_CHOICE="2"
                    
                    case "$ACL_CHOICE" in
                        1)
                            ACL_OPS="Read,Describe,DescribeConfigs"
                            ACL_DESC="Read (R)"
                            ACL_WHAT="consume only"
                            NEED_CONSUMER_GROUP=true
                            ;;
                        2)
                            ACL_OPS="Read,Write,Describe,DescribeConfigs"
                            ACL_DESC="Client (Produce + Consume + Describe)"
                            ACL_WHAT="produce, consume, describe (no admin)"
                            NEED_CONSUMER_GROUP=true
                            ;;
                        3|*)
                            ACL_OPS="All"
                            ACL_DESC="All"
                            ACL_WHAT="full access"
                            NEED_CONSUMER_GROUP=true
                            ;;
                    esac
                    
                    echo -e "   ${CYAN}Selected: $ACL_DESC${NC}"
                    status_msg "Adding ACL for User:$CHANGE_USER on topic $TOPIC_NAME ($ACL_DESC)"
                    
                    if [ "$ACL_OPS" == "All" ]; then
                        acl_out=$($KAFKA_BIN/kafka-acls.sh \
                          --bootstrap-server $BOOTSTRAP_CWDC \
                          --command-config "$ADMIN_CONFIG" \
                          --add \
                          --allow-principal "User:$CHANGE_USER" \
                          --operation All \
                          --topic "$TOPIC_NAME" </dev/null 2>&1)
                    else
                        IFS=',' read -ra OPS <<< "$ACL_OPS"
                        ACL_ARGS=()
                        for op in "${OPS[@]}"; do
                            ACL_ARGS+=("--operation" "$op")
                        done
                        acl_out=$($KAFKA_BIN/kafka-acls.sh \
                          --bootstrap-server $BOOTSTRAP_CWDC \
                          --command-config "$ADMIN_CONFIG" \
                          --add \
                          --allow-principal "User:$CHANGE_USER" \
                          "${ACL_ARGS[@]}" \
                          --topic "$TOPIC_NAME" </dev/null 2>&1)
                    fi
                    [ $? -ne 0 ] && { echo -e "\n   ${RED}❌ ACL add failed:${NC}"; echo "$acl_out" | sed 's/^/   /'; } || done_msg
                    
                    # Consumer group ACL (wait so validation [2] can use it)
                    if [ "$NEED_CONSUMER_GROUP" == "true" ]; then
                        status_msg "Adding ACL for consumer group * (Read)"
                        cg_acl_out=$($KAFKA_BIN/kafka-acls.sh \
                          --bootstrap-server $BOOTSTRAP_CWDC \
                          --command-config "$ADMIN_CONFIG" \
                          --add \
                          --allow-principal "User:$CHANGE_USER" \
                          --operation Read \
                          --group '*' 2>&1)
                        cg_rc=$?
                        done_msg
                        if [ $cg_rc -ne 0 ]; then
                            echo -e "   ${YELLOW}⚠️  Consumer group ACL add failed${NC}"
                            echo "$cg_acl_out" | sed 's/^/   /'
                        else
                            echo -e "   ${GREEN}✓ Consumer group ACL in effect.${NC} User:$CHANGE_USER has Read on consumer group \`*\` (any group)."
                            echo -e "   ${CYAN}   (host=* = allowed from any client IP; not related to topic)${NC}"
                        fi
                    fi
                fi
            fi
            
            # Credential validation (same as Add new user)
            echo -e "\n-------------------------------------------------------"
            echo "  CREDENTIAL VALIDATION (auth + ACL test)"
            echo "-------------------------------------------------------"
            echo -e "   ${CYAN}Note: CFK hot-reload takes ~30-60s. Script will retry until auth succeeds.${NC}"
            echo ""
            echo "   Method: SASL_PLAIN via sasl.jaas.config (temp config with new user/pass)"
            echo "   [1] Auth only (kafka-topics --describe) - zero message impact"
            if [ -n "$TOPIC_NAME" ]; then
                echo "   [2] Auth + Consume 5 msgs - minimal impact, unique group"
            fi
            echo "   [3] Skip validation"
            read -p "   Validate credential? [1-3]: " VAL_CHOICE
            
            VALIDATE_PASSED=false
            if [[ "$VAL_CHOICE" =~ ^[12]$ ]]; then
                SSL_LINES=$(grep -E '^ssl\.truststore\.(location|password)' "$ADMIN_CONFIG" 2>/dev/null)
                [ -z "$SSL_LINES" ] && SSL_LINES=$(grep -E '^ssl\.truststore\.(location|password)' "$CLIENT_CONFIG" 2>/dev/null)
                [ -z "$SSL_LINES" ] && error_exit "Could not find ssl.truststore in config."
                SAFE_PASS="${NEW_PASS//\"/\\\"}"
                TEMP_VALIDATE_CONFIG="$TMP_DIR/gen_validate_$$.properties"
                
                # Auth test with retry (same as Add new user)
                for entry in "$BOOTSTRAP_CWDC:1" "$BOOTSTRAP_TLS2:2"; do
                    bootstrap="${entry%:*}"
                    label="bootstrap${entry##*:}"
                    {
                        echo "bootstrap.servers=$bootstrap"
                        echo "security.protocol=SASL_SSL"
                        echo "sasl.mechanism=PLAIN"
                        echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$CHANGE_USER\" password=\"$SAFE_PASS\";"
                        echo "$SSL_LINES"
                    } > "$TEMP_VALIDATE_CONFIG"
                    
                    status_msg "Testing auth ($label) - will retry until success (max ${AUTH_MAX_RETRY_SEC}s)"
                    start_time=$(date +%s)
                    retry_count=0
                    while true; do
                        elapsed=$(($(date +%s) - start_time))
                        if [ $elapsed -ge $AUTH_MAX_RETRY_SEC ]; then
                            echo -e "\n   ${RED}❌ Auth FAILED for $label after ${AUTH_MAX_RETRY_SEC}s (timeout)${NC}"
                            read -p "   Continue to pack anyway? [y/N]: " cont
                            [[ ! "$cont" =~ ^[Yy]$ ]] && error_exit "Validation failed. Aborted."
                            break
                        fi
                        
                        retry_count=$((retry_count + 1))
                        if [ -n "$TOPIC_NAME" ]; then
                            auth_out=$(timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server "$bootstrap" --command-config "$TEMP_VALIDATE_CONFIG" --describe --topic "$TOPIC_NAME" 2>&1)
                        else
                            auth_out=$(timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server "$bootstrap" --command-config "$TEMP_VALIDATE_CONFIG" --list 2>&1)
                        fi
                        auth_rc=$?
                        
                        if [ $auth_rc -eq 0 ]; then
                            elapsed=$(($(date +%s) - start_time))
                            echo -e "   ${GREEN}✅ Auth OK on $label after ${elapsed}s (${retry_count} attempts)${NC}"
                            done_msg
                            break
                        else
                            if echo "$auth_out" | grep -qiE "SaslAuthenticationException|Authentication failed"; then
                                echo -e "   ${YELLOW}[${elapsed}s] Retry ${retry_count}: Auth failed, waiting ${AUTH_RETRY_INTERVAL}s for broker reload...${NC}"
                                sleep $AUTH_RETRY_INTERVAL
                            else
                                echo -e "\n   ${RED}❌ Auth FAILED for $label (exit code: $auth_rc, elapsed: ${elapsed}s)${NC}"
                                echo -e "   ${RED}--- Error output ---${NC}"
                                echo "$auth_out" | sed 's/^/   /'
                                echo -e "   ${RED}-------------------${NC}"
                                read -p "   Continue to pack anyway? [y/N]: " cont
                                [[ ! "$cont" =~ ^[Yy]$ ]] && error_exit "Validation failed. Aborted."
                                break
                            fi
                        fi
                    done
                done
                
                if [[ "$VAL_CHOICE" == "2" ]] && [ -n "$TOPIC_NAME" ]; then
                    echo -e "   ${CYAN}Waiting ${CONSUME_DELAY_AFTER_AUTH}s for all brokers to pick up new password...${NC}"
                    sleep $CONSUME_DELAY_AFTER_AUTH
                    {
                        echo "bootstrap.servers=$BOOTSTRAP_BOTH"
                        echo "security.protocol=SASL_SSL"
                        echo "sasl.mechanism=PLAIN"
                        echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$CHANGE_USER\" password=\"$SAFE_PASS\";"
                        echo "$SSL_LINES"
                    } > "$TEMP_VALIDATE_CONFIG"
                    consume_ok=false
                    for consume_attempt in $(seq 1 $CONSUME_AUTH_RETRY_COUNT); do
                        UNIQUE_GROUP="validate-$$-$(date +%s)-$consume_attempt"
                        status_msg "Consume test (5 msgs) attempt $consume_attempt/$CONSUME_AUTH_RETRY_COUNT"
                        consume_output=$(timeout $CONSUME_TIMEOUT_SEC $KAFKA_BIN/kafka-console-consumer.sh --bootstrap-server $BOOTSTRAP_BOTH --topic "$TOPIC_NAME" --consumer.config "$TEMP_VALIDATE_CONFIG" --from-beginning --max-messages $CONSUME_MAX_MESSAGES --timeout-ms $CONSUME_TIMEOUT_MS --group "$UNIQUE_GROUP" 2>&1)
                        exitcode=$?
                        if echo "$consume_output" | grep -qiE 'authentication|auth.*fail|sasl|GroupAuthorizationException'; then
                            echo -e "\n   ${YELLOW}Attempt $consume_attempt: broker auth failed.${NC}"
                            [ $consume_attempt -lt $CONSUME_AUTH_RETRY_COUNT ] && echo -e "   ${CYAN}Retrying in ${CONSUME_AUTH_RETRY_INTERVAL}s...${NC}" && sleep $CONSUME_AUTH_RETRY_INTERVAL
                            continue
                        fi
                        consume_ok=true
                        done_msg
                        if echo "$consume_output" | grep -qvE '^\[|^Processed|^Error' && [ -n "$consume_output" ]; then
                            msg_count=$(echo "$consume_output" | grep -vE '^\[|^Processed|^Error' | wc -l)
                            echo -e "   ${GREEN}(Consumed ${msg_count} message(s) - credential OK)${NC}"
                            echo -e "   ${CYAN}--- Messages (first 5) ---${NC}"
                            echo "$consume_output" | grep -vE '^\[|^Processed|^Error' | head -5 | sed 's/^/   /'
                            echo -e "   ${CYAN}------------------------${NC}"
                        elif [ $exitcode -eq 0 ]; then
                            echo -e "   ${CYAN}(Consume succeeded - auth OK)${NC}"
                        else
                            echo -e "   ${CYAN}(No messages or timeout - auth OK, exit=$exitcode)${NC}"
                        fi
                        break
                    done
                    if [ "$consume_ok" = false ]; then
                        echo -e "\n   ${RED}❌ Consume auth FAILED after $CONSUME_AUTH_RETRY_COUNT attempts${NC}"
                        echo -e "   ${RED}--- Last error output ---${NC}"
                        echo "$consume_output" | sed 's/^/   /'
                        echo -e "   ${RED}-------------------${NC}"
                        read -p "   Continue to pack anyway? [y/N]: " cont
                        [[ ! "$cont" =~ ^[Yy]$ ]] && error_exit "Consume validation failed. Aborted."
                    fi
                fi
                VALIDATE_PASSED=true
            fi
            
            # Generate secure output (same loop as Add new user)
            echo -e "\n-------------------------------------------------------"
            echo "  SECURE OUTPUT GENERATION"
            echo "-------------------------------------------------------"
            if [ "${GEN_MANAGE_ONCE}" = "1" ] && [ -n "${GEN_PASSPHRASE:-}" ]; then
                PASS1="${GEN_PASSPHRASE}"
                echo -e "   ${GREEN}✅ Passphrase set (non-interactive).${NC}"
            else
                while true; do
                    read -s -p "   Set Passphrase for .enc file: " PASS1; echo
                    read -s -p "   Confirm Passphrase: " PASS2; echo
                    if [ "$PASS1" == "$PASS2" ] && [ ! -z "$PASS1" ]; then
                        echo -e "   ${GREEN}✅ Passphrase matched.${NC}"
                        break
                    else
                        echo -e "   ${RED}❌ Mismatch or empty! Please try again.${NC}"
                    fi
                done
            fi
            
            TIMESTAMP=$(date +"%Y%m%d_%H%M")
            RAW_FILE="$TMP_DIR/${CHANGE_USER}_password_change_temp.txt"
            ENC_FILE="${USER_OUTPUT_DIR}/${CHANGE_USER}_password_change_${TIMESTAMP}.enc"
            SAFE_PASS_CHG="${NEW_PASS//\\/\\\\}"
            SAFE_PASS_CHG="${SAFE_PASS_CHG//\"/\\\"}"
            SAFE_PASS_CHG="${SAFE_PASS_CHG//\$/\\$}"
            cat <<EOF > $RAW_FILE
=========================================
KAFKA USER PASSWORD CHANGE
=========================================
User        : $CHANGE_USER
New Password: $NEW_PASS
Mechanism   : SASL_PLAIN

[BOOTSTRAP] (use both for resilience)
$BOOTSTRAP_BOTH

EOF
            if [ -n "$TOPIC_NAME" ] && [ -n "$ACL_DESC" ]; then
                ACL_WHAT_P="${ACL_WHAT:-}"
                [ -z "$ACL_WHAT_P" ] && ACL_WHAT_P="see ACL"
                cat <<EOF >> $RAW_FILE
Topic       : $TOPIC_NAME
ACL         : $ACL_DESC — $ACL_WHAT_P

EOF
            fi
            cat <<EOF >> $RAW_FILE
Generated   : $(date)
=========================================

[EXAMPLE CLIENT PROPERTIES]
Username and password below are the new values above — copy as-is. Only adjust ssl.truststore.location and ssl.truststore.password to your path and password.

security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$CHANGE_USER" password="$SAFE_PASS_CHG";
ssl.truststore.location=/path/to/your/kafka-truststore.jks
ssl.truststore.password=your_truststore_password

Note: Replace ssl.truststore.location and ssl.truststore.password with your actual path and password.
=========================================
EOF
            
            echo -n "$PASS1" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass stdin -in "$RAW_FILE" -out "$ENC_FILE"
            rm -f "$RAW_FILE"
            log_action "CHANGE_PASSWORD | what=change_password_pack | user=$CHANGE_USER | file=$ENC_FILE | namespaces=${SITE_NS[*]} | secret=$K8S_SECRET_NAME"
            
            echo -e "\n${GREEN}✔ PASSWORD CHANGE SUCCESSFUL!${NC}"
            echo -e "-------------------------------------------------------"
            echo -e " User       : $CHANGE_USER"
            echo -e " OCP Sites  : $NUM_SITES site(s)"
            [ -n "$TOPIC_NAME" ] && [ -n "$ACL_DESC" ] && echo -e " Topic      : $TOPIC_NAME ($ACL_DESC)"
            [ "$VALIDATE_PASSED" = "true" ] && echo -e " Validated  : ${GREEN}Yes (auth tested before pack)${NC}"
            echo -e " Secure File: ${YELLOW}$ENC_FILE${NC}"
            echo -e "-------------------------------------------------------"
            echo -e "\n${CYAN}HOW TO DECRYPT:${NC}"
            echo -e " ${YELLOW}openssl enc -d -aes-256-cbc -salt -pbkdf2 -in $ENC_FILE -out decrypted_creds.txt${NC}"
            echo -e "\n${CYAN}Note: CFK will hot-reload credentials (~30-60s). Old password will stop working after reload.${NC}"
            
            [ "${GEN_MANAGE_ONCE}" = "1" ] && { echo "GEN_PACK_DIR=$USER_OUTPUT_DIR"; echo "GEN_PACK_FILE=$(basename "$ENC_FILE")"; GEN_MANAGE_ONCE=""; exit 0; }
            echo -e "\n   ${CYAN}Options:${NC}"
            echo "   [1] Change another user's password"
            echo "   [M] Main menu"
            echo "   [Q] Quit"
            read -p "   Your choice [1/M/Q]: " CONTINUE_CHOICE
            [[ "$CONTINUE_CHOICE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit 0; }
            [[ "$CONTINUE_CHOICE" =~ ^[Mm]$ ]] && break
        fi
        
        if [ "$ACTION_CHOICE" == "3" ]; then
            # ========== CLEANUP ORPHANED ACLs ==========
            # Find users that have ACLs but don't exist in secret
            echo -e "\n-------------------------------------------------------"
            echo "  CLEANUP ORPHANED ACLs"
            echo "-------------------------------------------------------"
            echo -e "   ${CYAN}This will find users with ACLs in Kafka but not in secret,${NC}"
            echo -e "   ${CYAN}then remove their ACLs.${NC}"
            echo ""
            
            # Get users from secret
            status_msg "Fetching users from secret"
            JSON_CWDC=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[0]}" --context "${SITE_CTX[0]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
            if [ -z "$JSON_CWDC" ]; then
                error_exit "Could not retrieve users from site ${SITE_CTX[0]} secret"
            fi
            SECRET_USERS=$(echo "$JSON_CWDC" | jq -r 'keys[]' | sort)
            done_msg
            
            # Get all users from ACLs
            status_msg "Fetching all users from ACLs"
            ALL_ACL_LIST=$($KAFKA_BIN/kafka-acls.sh --bootstrap-server $BOOTSTRAP_CWDC --command-config "$ADMIN_CONFIG" --list </dev/null 2>&1)
            if [ $? -ne 0 ] || [ -z "$ALL_ACL_LIST" ]; then
                error_exit "Could not list ACLs from Kafka"
            fi
            done_msg
            
            # Extract unique user principals from ACL list
            # Improved extraction: handle both formats (principal=User:xxx, and principal=User:xxx)
            ACL_USERS=$(echo "$ALL_ACL_LIST" | grep -o "principal=User:[^,)]*" | sed 's/principal=User://' | sort -u)
            
            # Debug: Show extracted users (if any)
            if [ -z "$ACL_USERS" ]; then
                echo -e "   ${YELLOW}⚠️  Warning: No users extracted from ACL list${NC}"
                [ "${GEN_MANAGE_ONCE}" = "1" ] && { GEN_MANAGE_ONCE=""; exit 0; }
                echo -e "   ${CYAN}Press Enter to continue...${NC}"
                read
                continue
            fi
            
            # Find orphaned users (in ACLs but not in secret, excluding system users)
            ORPHANED_USERS=()
            while IFS= read -r acl_user; do
                if [ -z "$acl_user" ]; then
                    continue
                fi
                # Skip system users
                if echo "$acl_user" | grep -qE "$SYSTEM_USERS"; then
                    continue
                fi
                # Check if user exists in secret
                if ! echo "$SECRET_USERS" | grep -q "^${acl_user}$"; then
                    ORPHANED_USERS+=("$acl_user")
                fi
            done <<< "$ACL_USERS"
            
            if [ ${#ORPHANED_USERS[@]} -eq 0 ]; then
                echo -e "\n   ${GREEN}✅ No orphaned ACLs found. All users with ACLs exist in secret.${NC}"
                [ "${GEN_MANAGE_ONCE}" = "1" ] && { GEN_MANAGE_ONCE=""; exit 0; }
                echo -e "   ${CYAN}Press Enter to continue...${NC}"
                read
                continue
            fi
            
            echo -e "\n   ${YELLOW}⚠️  Found ${#ORPHANED_USERS[@]} user(s) with ACLs but not in secret:${NC}"
            idx=1
            for orphan_user in "${ORPHANED_USERS[@]}"; do
                echo "   [$idx] $orphan_user"
                idx=$((idx + 1))
            done
            
            echo -e "\n   ${YELLOW}These users will have ALL their ACLs removed.${NC}"
            if [ "${GEN_MANAGE_ONCE}" != "1" ]; then
                read -p "   Continue? [y/N]: " confirm
                [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "   ${CYAN}Cancelled.${NC}"; continue; }
            fi
            # Remove ACLs for each orphaned user (reuse same logic as Remove User)
            ORPHAN_TOTAL_REMOVED=0
            ORPHAN_TOTAL_FAILED=0
            for ORPHAN_USER in "${ORPHANED_USERS[@]}"; do
                echo -e "\n   ${CYAN}Processing User: $ORPHAN_USER${NC}"
                
                # List all ACLs for this user
                status_msg "Listing ACLs for User:$ORPHAN_USER"
                acl_list=$($KAFKA_BIN/kafka-acls.sh \
                  --bootstrap-server $BOOTSTRAP_CWDC \
                  --command-config "$ADMIN_CONFIG" \
                  --list \
                  --principal "User:$ORPHAN_USER" </dev/null 2>&1)
                
                if [ $? -ne 0 ] || [ -z "$acl_list" ]; then
                    echo -e "   ${YELLOW}No ACLs found for User:$ORPHAN_USER${NC}"
                    done_msg
                    continue
                fi
                done_msg
                
                # Parse and remove ACLs (same logic as Remove User)
                status_msg "Removing ACLs for User:$ORPHAN_USER"
                acl_removed_count=0
                acl_failed_count=0
                current_resource_type=""
                current_resource_name=""
                current_pattern_type=""
                
                acl_temp_file="$TMP_DIR/acl_list_${ORPHAN_USER}_$$.txt"
                echo "$acl_list" > "$acl_temp_file"

                while IFS= read -r line; do
                    # Check for resource header line
                    if echo "$line" | grep -q "ResourcePattern"; then
                        # Extract resource type
                        if echo "$line" | grep -q "resourceType=TOPIC"; then
                            current_resource_type="TOPIC"
                        elif echo "$line" | grep -q "resourceType=GROUP"; then
                            current_resource_type="GROUP"
                        else
                            current_resource_type=""
                            continue
                        fi
                        
                        # Extract resource name (trim)
                        resource_name_match=$(echo "$line" | sed -n 's/.*name=\([^,)]*\).*/\1/p')
                        resource_name_match=$(trim_ws "$resource_name_match")
                        if [ -n "$resource_name_match" ]; then
                            current_resource_name="$resource_name_match"
                        else
                            current_resource_name=""
                            continue
                        fi
                        
                        # Extract pattern type (trim)
                        pattern_type_match=$(echo "$line" | sed -n 's/.*patternType=\([^)]*\).*/\1/p')
                        pattern_type_match=$(trim_ws "$pattern_type_match")
                        if [ -n "$pattern_type_match" ]; then
                            current_pattern_type="$pattern_type_match"
                        else
                            current_pattern_type="LITERAL"  # Default
                        fi
                        continue
                    fi
                    
                    # Check for ACL entry line with our user (comma, ), or space after name)
                    if echo "$line" | grep -qE "principal=User:${ORPHAN_USER}(,|\)|[[:space:]])"; then
                        # Extract operation (trim)
                        operation_match=$(echo "$line" | sed -n 's/.*operation=\([^,]*\).*/\1/p')
                        operation_match=$(trim_ws "$operation_match")
                        if [ -n "$operation_match" ]; then
                            operation="$operation_match"
                        else
                            continue
                        fi
                        
                        if [ -z "$current_resource_type" ] || [ -z "$current_resource_name" ] || [ -z "$operation" ]; then
                            continue
                        fi
                        
                        op_cli=$(acl_operation_for_remove "$operation")
                        acl_remove_cfg=$(get_acl_remove_config)
                        if [ "$current_resource_type" == "TOPIC" ]; then
                            remove_out=$(run_acl_remove "$BOOTSTRAP_CWDC" "$acl_remove_cfg" "User:$ORPHAN_USER" "$op_cli" "--topic" "$current_resource_name" "$current_pattern_type")
                            rc=$?
                            if [ $rc -eq 0 ]; then
                                acl_removed_count=$((acl_removed_count + 1))
                            else
                                acl_failed_count=$((acl_failed_count + 1))
                                echo -e "   ${YELLOW}⚠️  Failed: topic=$current_resource_name op=$operation${NC}"
                                [ -n "$remove_out" ] && echo -e "   ${YELLOW}   $remove_out${NC}"
                            fi
                        elif [ "$current_resource_type" == "GROUP" ]; then
                            remove_out=$(run_acl_remove "$BOOTSTRAP_CWDC" "$acl_remove_cfg" "User:$ORPHAN_USER" "$op_cli" "--group" "$current_resource_name" "$current_pattern_type")
                            rc=$?
                            if [ $rc -eq 0 ]; then
                                acl_removed_count=$((acl_removed_count + 1))
                            else
                                acl_failed_count=$((acl_failed_count + 1))
                                echo -e "   ${YELLOW}⚠️  Failed: group=$current_resource_name op=$operation${NC}"
                                [ -n "$remove_out" ] && echo -e "   ${YELLOW}   $remove_out${NC}"
                            fi
                        fi
                    fi
                done < "$acl_temp_file"
                
                rm -f "$acl_temp_file"
                
                ORPHAN_TOTAL_REMOVED=$((ORPHAN_TOTAL_REMOVED + acl_removed_count))
                ORPHAN_TOTAL_FAILED=$((ORPHAN_TOTAL_FAILED + acl_failed_count))
                if [ $acl_removed_count -gt 0 ]; then
                    echo -e "   ${GREEN}✅ Removed $acl_removed_count ACL(s) for User:$ORPHAN_USER${NC}"
                    [ $acl_failed_count -gt 0 ] && echo -e "   ${YELLOW}⚠️  Failed to remove $acl_failed_count ACL(s)${NC}"
                else
                    echo -e "   ${YELLOW}⚠️  No ACLs removed for User:$ORPHAN_USER${NC}"
                fi
                done_msg
            done
            
            if [ $ORPHAN_TOTAL_REMOVED -gt 0 ]; then
                echo -e "\n${GREEN}✅ Orphaned ACL cleanup completed. Removed $ORPHAN_TOTAL_REMOVED ACL(s) in total.${NC}"
                [ $ORPHAN_TOTAL_FAILED -gt 0 ] && echo -e "   ${YELLOW}⚠️  $ORPHAN_TOTAL_FAILED ACL(s) could not be removed (see above).${NC}"
            else
                echo -e "\n${YELLOW}⚠️  Orphaned ACL cleanup finished but no ACLs were removed.${NC}"
                echo -e "   ${CYAN}Some ACLs may still remain (e.g. check operation=ALL or broker errors above).${NC}"
            fi
            echo -e "   ${CYAN}Processed ${#ORPHANED_USERS[@]} user(s).${NC}"
            
            # Log cleanup operation
            log_action "CLEANUP_ORPHANED_ACLs | what=remove_orphaned_ACLs | users=${ORPHANED_USERS[*]} | count=${#ORPHANED_USERS[@]} | namespaces=${SITE_NS[*]} | secret=$K8S_SECRET_NAME"
            
            [ "${GEN_MANAGE_ONCE}" = "1" ] && { GEN_MANAGE_ONCE=""; exit 0; }
            echo -e "\n   ${CYAN}Press Enter to continue...${NC}"
            read
        fi
    done
    
        # If we break from the loop (user chose Main menu), continue main loop
        continue
    fi

    # Mode 1: Add new user
    # 1. IDENTIFICATION
    echo -e "\n1. IDENTIFICATION"
    if [ "${GEN_NONINTERACTIVE}" != "1" ] || [ -z "$SYSTEM_NAME" ]; then
        read -p "   Enter System Name (for tracking): " SYSTEM_NAME
    fi
    [ -z "$SYSTEM_NAME" ] && error_exit "System Name is required."

    # 2. TOPIC VALIDATION (use ADMIN_CONFIG - client may lack DESCRIBE on some topics)
    if [ "${GEN_NONINTERACTIVE}" != "1" ] || [ -z "$TOPIC_NAME" ]; then
        echo -e "\n2. TOPIC VALIDATION"
        while true; do
            read -p "   Enter Topic Name (or 'L' to list all, 'Q' to quit): " TOPIC_INPUT
            [[ "$TOPIC_INPUT" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Cancelled. Returning to main menu...${NC}"; continue 2; }
            if [[ "$TOPIC_INPUT" =~ ^[Ll]$ ]]; then
                status_msg "Fetching All Topics from Cluster"
                ($KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config $ADMIN_CONFIG --list > $TMP_DIR/topics.list 2> $TMP_DIR/topics.list.err) &
                spinner $!
                wait $!
                echo -e "\n${CYAN}--- Available Topics ---${NC}"
                if [ -s $TMP_DIR/topics.list ]; then
                    cat $TMP_DIR/topics.list
                else
                    echo "   (none or error)"
                    [ -s $TMP_DIR/topics.list.err ] && echo -e "   ${RED}Error:${NC}" && cat $TMP_DIR/topics.list.err | sed 's/^/   /'
                    echo "   Check: KAFKA_BIN=$KAFKA_BIN, ADMIN_CONFIG=$ADMIN_CONFIG, bootstrap=$BOOTSTRAP_BOTH"
                fi
                echo -e "${CYAN}------------------------${NC}"; continue
            fi
            status_msg "Validating Topic '$TOPIC_INPUT'"
            timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config $ADMIN_CONFIG --describe --topic $TOPIC_INPUT > $TMP_DIR/topic_out 2>/dev/null &
            PID=$!; spinner $PID; wait $PID
            if [ $? -eq 0 ] && [ -s $TMP_DIR/topic_out ]; then
                done_msg; TOPIC_NAME=$TOPIC_INPUT; break
            else
                echo -e "\n   ${RED}❌ NOT FOUND: Topic '$TOPIC_INPUT' doesn't exist (or no permission).${NC}"
            fi
        done
    fi

# 3. CREDENTIAL SETUP
echo -e "\n3. CREDENTIAL SETUP"
if [ "${GEN_NONINTERACTIVE}" != "1" ] || [ -z "$KAFKA_USER" ]; then
    read -p "   Enter Kafka Username: " KAFKA_USER
fi
validate_username "$KAFKA_USER"

# Prevent human error: block adding a username that already exists
status_msg "Checking if username already exists"
JSON_CWDC=$(oc get secret $K8S_SECRET_NAME -n "${SITE_NS[0]}" --context "${SITE_CTX[0]}" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
[ -z "$JSON_CWDC" ] && error_exit "Could not fetch user list from site ${SITE_CTX[0]} to check for duplicate."
exists=$(echo "$JSON_CWDC" | jq -r --arg u "$KAFKA_USER" 'if has($u) then "yes" else "no" end')
[ "$exists" = "yes" ] && error_exit "User '$KAFKA_USER' already exists. Use [2] Test existing user or [3] User management (e.g. Change password) instead of Add."
done_msg

# 4. EXECUTION (JSON Patch Logic)
echo -e "\n-------------------------------------------------------"
echo "  EXECUTING UPDATES..."
echo "-------------------------------------------------------"

status_msg "Generating ${PASSWORD_LENGTH}-character Secure Credential"
NEW_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c $PASSWORD_LENGTH)
done_msg

# Helper: patch one site (uses --context, no global switch)
patch_site() {
    local ctx=$1
    local ns=$2
    status_msg "Fetching Secret from $ctx ($ns)"
    local json
    json=$(oc get secret $K8S_SECRET_NAME -n "$ns" --context "$ctx" -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
    [ -z "$json" ] && { echo -e "\n   ${RED}❌ Could not retrieve plain-users.json from $ctx${NC}"; return 1; }
    done_msg
    status_msg "Patching OCP Secret in $ctx"
    local updated
    updated=$(echo "$json" | jq -c --arg user "$KAFKA_USER" --arg pass "$NEW_PASS" '.[$user] = $pass')
    [ $? -ne 0 ] && { echo -e "\n   ${RED}❌ jq failed for $ctx${NC}"; return 1; }
    local b64
    b64=$(echo -n "$updated" | base64 | tr -d '\n')
    oc patch secret $K8S_SECRET_NAME -n "$ns" --context "$ctx" --type='merge' -p "{\"data\":{\"plain-users.json\":\"$b64\"}}" &>/dev/null || { echo -e "\n   ${RED}❌ OCP Patch failed for $ctx${NC}"; return 1; }
    done_msg
    return 0
}

# Run patch every site in parallel (reduces wait time)
_pids=()
for ((i=0;i<NUM_SITES;i++)); do
    patch_site "${SITE_CTX[$i]}" "${SITE_NS[$i]}" & _pids+=($!)
done
_rc=0
for ((i=0;i<NUM_SITES;i++)); do
    wait ${_pids[$i]}; r=$?
    [ $r -ne 0 ] && error_exit "Site ${SITE_CTX[$i]} patch failed."
done
status_msg "Verifying patch (user present in all secrets)"
_vpids=()
for ((i=0;i<NUM_SITES;i++)); do
    verify_user_in_secret "${SITE_CTX[$i]}" "${SITE_NS[$i]}" "$KAFKA_USER" & _vpids+=($!)
done
for ((i=0;i<NUM_SITES;i++)); do
    wait ${_vpids[$i]}; r=$?
    [ $r -ne 0 ] && error_exit "Site ${SITE_CTX[$i]} verification failed."
done
done_msg

# -----------------------------------------------------------------------------
# 4b. ADD ACL — Kafka ACL options (comments for reference)
# -----------------------------------------------------------------------------
# Topic resource operations (--topic <name>):
#   Read             — Consume messages from the topic. Required for consumers.
#   Write            — Produce messages to the topic. Required for producers.
#   Describe         — View topic metadata (partitions, offsets). Usually needed with Read/Write.
#   DescribeConfigs  — View topic configuration. Often included with Describe.
#   Create           — Create new topics. Admin-level; do not grant to normal clients.
#   Alter            — Alter topic (e.g. add partitions). Admin-level.
#   AlterConfigs      — Change topic config. Admin-level.
#   Delete           — Delete topic. Admin-level.
#   All              — All of the above. Use only when full access is required.
#
# Consumer group resource operations (--group <pattern>). Required for consume/produce flows:
#   Read     — Join group and consume. Default: always added for client (auto-selected).
#   Describe — View consumer group metadata (members, offsets). Optional.
#   Delete   — Delete the consumer group. Optional; use only if client must delete groups.
# -----------------------------------------------------------------------------

echo -e "\n-------------------------------------------------------"
echo "  ADD ACL (for topic: $TOPIC_NAME)"
echo "-------------------------------------------------------"
if [ "${GEN_NONINTERACTIVE}" != "1" ] || [ -z "$ACL_CHOICE" ]; then
    echo "   Topic ACL presets:"
    echo "   [1] Read — consume only (Read, Describe, DescribeConfigs)"
    echo "   [2] Client — Produce + Consume + Describe (Read, Write, Describe, DescribeConfigs). Recommended for normal clients; no admin rights."
    echo "   [3] All — full access (includes Create, Alter, Delete topic; admin-level)."
    read -p "   Select [1-3] (default: 2): " ACL_CHOICE
fi
[[ -z "$ACL_CHOICE" ]] && ACL_CHOICE="2"

case "$ACL_CHOICE" in
    1)
        ACL_OPS="Read,Describe,DescribeConfigs"
        ACL_DESC="Read (R)"
        ACL_WHAT="consume only"
        NEED_CONSUMER_GROUP=true
        ;;
    2)
        ACL_OPS="Read,Write,Describe,DescribeConfigs"
        ACL_DESC="Client (Produce + Consume + Describe)"
        ACL_WHAT="produce, consume, describe (no admin)"
        NEED_CONSUMER_GROUP=true
        ;;
    3|*)
        ACL_OPS="All"
        ACL_DESC="All"
        ACL_WHAT="full access (includes Alter, Delete, Create, etc.)"
        NEED_CONSUMER_GROUP=true
        ;;
esac

# Optional: override topic operations from env (comma-separated, e.g. GEN_ACL_OPS=Read,Write,Describe)
if [ -n "$GEN_ACL_OPS" ]; then
    ACL_OPS="$GEN_ACL_OPS"
    ACL_DESC="Custom ($ACL_OPS)"
    ACL_WHAT="custom topic ops"
fi

echo -e "   ${CYAN}Selected: $ACL_DESC${NC}"
status_msg "Adding ACL for User:$KAFKA_USER on topic $TOPIC_NAME ($ACL_DESC)"

# Build kafka-acls command with multiple --operation flags for topic
if [ "$ACL_OPS" == "All" ]; then
    acl_out=$($KAFKA_BIN/kafka-acls.sh \
      --bootstrap-server $BOOTSTRAP_CWDC \
      --command-config "$ADMIN_CONFIG" \
      --add \
      --allow-principal "User:$KAFKA_USER" \
      --operation All \
      --topic "$TOPIC_NAME" </dev/null 2>&1)
else
    IFS=',' read -ra OPS <<< "$ACL_OPS"
    ACL_ARGS=()
    for op in "${OPS[@]}"; do
        ACL_ARGS+=("--operation" "$(echo "$op" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')")
    done
    acl_out=$($KAFKA_BIN/kafka-acls.sh \
      --bootstrap-server $BOOTSTRAP_CWDC \
      --command-config "$ADMIN_CONFIG" \
      --add \
      --allow-principal "User:$KAFKA_USER" \
      "${ACL_ARGS[@]}" \
      --topic "$TOPIC_NAME" </dev/null 2>&1)
fi
[ $? -ne 0 ] && { echo -e "\n   ${RED}❌ ACL add failed:${NC}"; echo "$acl_out" | sed 's/^/   /'; error_exit "Check admin credentials in $ADMIN_CONFIG."; }
done_msg

# 4b-2. Consumer Group ACL — Required for running a real consumer (e.g. commit offset).
#        Having only Topic READ is not enough; you must have READ on ResourceType=GROUP too, else commit offset fails.
#        We add Read on group '*' by default (auto-selected). Optional: GEN_ACL_GROUP_EXTRA=Describe,Delete.
if [ "$NEED_CONSUMER_GROUP" == "true" ]; then
    status_msg "Adding ACL for consumer group * (Read — required for consume / commit offset)"
    cg_acl_out=$($KAFKA_BIN/kafka-acls.sh \
      --bootstrap-server $BOOTSTRAP_CWDC \
      --command-config "$ADMIN_CONFIG" \
      --add \
      --allow-principal "User:$KAFKA_USER" \
      --operation Read \
      --group '*' 2>&1)
    cg_rc=$?
    done_msg
    if [ $cg_rc -ne 0 ]; then
        echo -e "   ${YELLOW}⚠️  Consumer group ACL add failed (consume test may fail)${NC}"
        echo "$cg_acl_out" | sed 's/^/   /'
    else
        echo -e "   ${GREEN}✓ Consumer group Read in effect.${NC} User:$KAFKA_USER can join consumer groups (required for consume)."
    fi
    # Optional: add extra consumer group operations (Describe, Delete) when requested via env
    if [ -n "$GEN_ACL_GROUP_EXTRA" ]; then
        IFS=',' read -ra CG_EXTRA <<< "$GEN_ACL_GROUP_EXTRA"
        for cg_op in "${CG_EXTRA[@]}"; do
            cg_op=$(echo "$cg_op" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$cg_op" ] && continue
            status_msg "Adding ACL for consumer group * ($cg_op)"
            cg_extra_out=$($KAFKA_BIN/kafka-acls.sh \
              --bootstrap-server $BOOTSTRAP_CWDC \
              --command-config "$ADMIN_CONFIG" \
              --add \
              --allow-principal "User:$KAFKA_USER" \
              --operation "$cg_op" \
              --group '*' 2>&1)
            if [ $? -ne 0 ]; then
                echo -e "   ${YELLOW}⚠️  Consumer group $cg_op failed${NC}"
                echo "$cg_extra_out" | sed 's/^/   /'
            else
                echo -e "   ${GREEN}✓ Consumer group $cg_op added.${NC}"
            fi
        done
    fi
fi

# 4c. CREDENTIAL VALIDATION - ensure client can use the creds
echo -e "\n-------------------------------------------------------"
echo "  CREDENTIAL VALIDATION (auth + ACL test)"
echo "-------------------------------------------------------"
echo -e "   ${CYAN}Note: CFK hot-reload takes ~30-60s. Script will retry until auth succeeds.${NC}"
echo -e "   ${CYAN}      If auth fails after retries, contact Support.${NC}"
echo ""
echo "   Method: SASL_PLAIN via sasl.jaas.config (temp config with new user/pass)"
echo "   [1] Auth only (kafka-topics --describe) - zero message impact"
echo "   [2] Auth + Consume 5 msgs - minimal impact, unique group"
echo "   [3] Skip validation"
if [ "${GEN_NONINTERACTIVE}" = "1" ]; then
    # Web: GEN_VALIDATE_CONSUME=1 = Auth + Consume (2), else Auth only (1)
    [ "${GEN_VALIDATE_CONSUME}" = "1" ] && VAL_CHOICE=2 || VAL_CHOICE=1
else
    read -p "   Validate credential? [1-3]: " VAL_CHOICE
fi

VALIDATE_PASSED=false
if [[ "$VAL_CHOICE" =~ ^[12]$ ]]; then
    # Build temp config from scratch (ADMIN_CONFIG has correct SSL; base config may have bootstrap without port)
    TEMP_VALIDATE_CONFIG="$TMP_DIR/gen_validate_$$.properties"
    SAFE_PASS="${NEW_PASS//\"/\\\"}"
    SSL_LINES=$(grep -E '^ssl\.truststore\.(location|password)' "$ADMIN_CONFIG" 2>/dev/null)
    [ -z "$SSL_LINES" ] && SSL_LINES=$(grep -E '^ssl\.truststore\.(location|password)' "$CLIENT_CONFIG" 2>/dev/null)
    [ -z "$SSL_LINES" ] && error_exit "Could not find ssl.truststore in $ADMIN_CONFIG or $CLIENT_CONFIG"

    # Auth test: CFK hot-reload ~30-60s; retry until auth succeeds (max AUTH_MAX_RETRY_SEC)
    echo -e "   ${CYAN}CFK hot-reload: will retry until auth succeeds (max ${AUTH_MAX_RETRY_SEC}s)${NC}"
    TEST_BOOTSTRAPS=("$BOOTSTRAP_CWDC:1" "$BOOTSTRAP_TLS2:2")
    for entry in "${TEST_BOOTSTRAPS[@]}"; do
        label="${entry##*:}"
        bootstrap="${entry%:$label}"
        {
            echo "bootstrap.servers=$bootstrap"
            echo "security.protocol=SASL_SSL"
            echo "sasl.mechanism=PLAIN"
            echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$KAFKA_USER\" password=\"$SAFE_PASS\";"
            echo "$SSL_LINES"
        } > "$TEMP_VALIDATE_CONFIG"
        
        # Continuous retry with timeout and elapsed time tracking
        auth_rc=1
        auth_out=""
        start_time=$(date +%s)
        retry_count=0
        
        echo -e "   ${CYAN}Testing auth ($label) - will retry until success (max ${AUTH_MAX_RETRY_SEC}s)...${NC}"
        while [ $auth_rc -ne 0 ]; do
            elapsed=$(($(date +%s) - start_time))
            if [ $elapsed -ge $AUTH_MAX_RETRY_SEC ]; then
                echo -e "\n   ${RED}❌ Auth FAILED for $label (timeout after ${AUTH_MAX_RETRY_SEC}s, tried ${retry_count} times)${NC}"
                echo -e "   ${RED}--- Error output ---${NC}"
                echo "$auth_out" | sed 's/^/   /'
                echo -e "   ${RED}-------------------${NC}"
                echo -e "   ${CYAN}Debug: Temp config at $TEMP_VALIDATE_CONFIG (removed on exit)${NC}"
                if [ "${GEN_NONINTERACTIVE}" = "1" ]; then VALIDATE_PASSED=false; break; fi
                read -p "   Continue to pack anyway? [y/N]: " cont
                [[ ! "$cont" =~ ^[Yy]$ ]] && error_exit "Validation failed. Aborted."
                break
            fi
            
            retry_count=$((retry_count + 1))
            auth_out=$(timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server "$bootstrap" --command-config "$TEMP_VALIDATE_CONFIG" --describe --topic "$TOPIC_NAME" 2>&1)
            auth_rc=$?
            
            if [ $auth_rc -eq 0 ]; then
                elapsed=$(($(date +%s) - start_time))
                echo -e "   ${GREEN}✅ Auth OK on $label after ${elapsed}s (${retry_count} attempts)${NC}"
                done_msg
                break
            else
                if echo "$auth_out" | grep -qiE "SaslAuthenticationException|Authentication failed"; then
                    echo -e "   ${YELLOW}[${elapsed}s] Retry ${retry_count}: Auth failed, waiting ${AUTH_RETRY_INTERVAL}s for broker reload...${NC}"
                    sleep $AUTH_RETRY_INTERVAL
                else
                    # Non-auth error (network, etc.) - fail immediately
                    echo -e "\n   ${RED}❌ Auth FAILED for $label (exit code: $auth_rc, elapsed: ${elapsed}s)${NC}"
                    echo -e "   ${RED}--- Error output ---${NC}"
                    echo "$auth_out" | sed 's/^/   /'
                    echo -e "   ${RED}-------------------${NC}"
                    if [ "${GEN_NONINTERACTIVE}" = "1" ]; then VALIDATE_PASSED=false; break; fi
                    read -p "   Continue to pack anyway? [y/N]: " cont
                    [[ ! "$cont" =~ ^[Yy]$ ]] && error_exit "Validation failed. Aborted."
                    break
                fi
            fi
        done
    done

    if [[ "$VAL_CHOICE" == "2" ]]; then
        # Brokers may reload credentials at different times; wait then retry consume on auth failure
        echo -e "   ${CYAN}Waiting ${CONSUME_DELAY_AFTER_AUTH}s for all brokers to pick up new user...${NC}"
        sleep $CONSUME_DELAY_AFTER_AUTH
        {
            echo "bootstrap.servers=$BOOTSTRAP_BOTH"
            echo "security.protocol=SASL_SSL"
            echo "sasl.mechanism=PLAIN"
            echo "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$KAFKA_USER\" password=\"$SAFE_PASS\";"
            echo "$SSL_LINES"
        } > "$TEMP_VALIDATE_CONFIG"
        consume_ok=false
        for consume_attempt in $(seq 1 $CONSUME_AUTH_RETRY_COUNT); do
            UNIQUE_GROUP="validate-$$-$(date +%s)-$consume_attempt"
            status_msg "Consume test (5 msgs, group=$UNIQUE_GROUP) attempt $consume_attempt/$CONSUME_AUTH_RETRY_COUNT"
            consume_output=$(timeout $CONSUME_TIMEOUT_SEC $KAFKA_BIN/kafka-console-consumer.sh --bootstrap-server $BOOTSTRAP_BOTH --topic "$TOPIC_NAME" --consumer.config "$TEMP_VALIDATE_CONFIG" --from-beginning --max-messages $CONSUME_MAX_MESSAGES --timeout-ms $CONSUME_TIMEOUT_MS --group "$UNIQUE_GROUP" 2>&1)
            exitcode=$?
            if echo "$consume_output" | grep -qiE 'authentication|auth.*fail|sasl|GroupAuthorizationException'; then
                echo -e "\n   ${YELLOW}Attempt $consume_attempt: broker auth failed (one broker may not have reloaded yet).${NC}"
                [ $consume_attempt -lt $CONSUME_AUTH_RETRY_COUNT ] && echo -e "   ${CYAN}Retrying in ${CONSUME_AUTH_RETRY_INTERVAL}s...${NC}" && sleep $CONSUME_AUTH_RETRY_INTERVAL
                continue
            fi
            consume_ok=true
            done_msg
            if echo "$consume_output" | grep -qvE '^\[|^Processed|^Error' && [ -n "$consume_output" ]; then
                msg_count=$(echo "$consume_output" | grep -vE '^\[|^Processed|^Error' | wc -l)
                echo -e "   ${GREEN}(Consumed ${msg_count} message(s) - credential OK)${NC}"
                echo -e "   ${CYAN}--- Messages (first 5) ---${NC}"
                echo "$consume_output" | grep -vE '^\[|^Processed|^Error' | head -5 | sed 's/^/   /'
                echo -e "   ${CYAN}------------------------${NC}"
            elif [ $exitcode -eq 0 ]; then
                echo -e "   ${CYAN}(Consume succeeded - auth OK)${NC}"
            else
                echo -e "   ${CYAN}(No messages or timeout - auth OK, exit=$exitcode)${NC}"
            fi
            break
        done
        if [ "$consume_ok" = false ]; then
            echo -e "\n   ${RED}❌ Consume auth FAILED after $CONSUME_AUTH_RETRY_COUNT attempts (exit code: $exitcode)${NC}"
            echo -e "   ${RED}--- Last error output ---${NC}"
            echo "$consume_output" | sed 's/^/   /'
            echo -e "   ${RED}-------------------${NC}"
            if [ "${GEN_NONINTERACTIVE}" = "1" ]; then VALIDATE_PASSED=false; else read -p "   Continue to pack anyway? [y/N]: " cont; [[ ! "$cont" =~ ^[Yy]$ ]] && error_exit "Consume validation failed. Aborted."; fi
        fi
    fi
    VALIDATE_PASSED=true
fi

# 5. SECURE OUTPUT (Passphrase Validation)
echo -e "\n-------------------------------------------------------"
echo "  SECURE OUTPUT GENERATION"
echo "-------------------------------------------------------"
if [ "${GEN_NONINTERACTIVE}" = "1" ] && [ -n "${GEN_PASSPHRASE:-}" ]; then
    PASS1="${GEN_PASSPHRASE}"
    echo -e "   ${GREEN}✅ Passphrase set (non-interactive).${NC}"
else
    while true; do
        read -s -p "   Set Passphrase for .enc file: " PASS1; echo
        read -s -p "   Confirm Passphrase: " PASS2; echo
        if [ "$PASS1" == "$PASS2" ] && [ ! -z "$PASS1" ]; then
            echo -e "   ${GREEN}✅ Passphrase matched.${NC}"
            break
        else
            echo -e "   ${RED}❌ Mismatch or empty! Please try again.${NC}"
        fi
    done
fi

TIMESTAMP=$(date +"%Y%m%d_%H%M")
ENC_FILE="${USER_OUTPUT_DIR}/${SYSTEM_NAME}_${TIMESTAMP}.enc"
PACK_DIR="$TMP_DIR/${SYSTEM_NAME}_${TIMESTAMP}"
PACK_NAME="${SYSTEM_NAME}_${TIMESTAMP}"

# Truststore from server config (same for all clients of this cluster)
TRUSTSTORE_LOCATION=$(grep -E '^ssl\.truststore\.location' "$ADMIN_CONFIG" 2>/dev/null | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
[ -z "$TRUSTSTORE_LOCATION" ] && TRUSTSTORE_LOCATION=$(grep -E '^ssl\.truststore\.location' "$CLIENT_CONFIG" 2>/dev/null | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
TRUSTSTORE_PASSWORD=$(grep -E '^ssl\.truststore\.password' "$ADMIN_CONFIG" 2>/dev/null | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
[ -z "$TRUSTSTORE_PASSWORD" ] && TRUSTSTORE_PASSWORD=$(grep -E '^ssl\.truststore\.password' "$CLIENT_CONFIG" 2>/dev/null | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
TRUSTSTORE_BASENAME=""
[ -n "$TRUSTSTORE_LOCATION" ] && [ -f "$TRUSTSTORE_LOCATION" ] && TRUSTSTORE_BASENAME=$(basename "$TRUSTSTORE_LOCATION")

mkdir -p "$PACK_DIR/certs"
if [ -n "$TRUSTSTORE_BASENAME" ]; then
    cp "$TRUSTSTORE_LOCATION" "$PACK_DIR/certs/"
fi

# Escape password for sasl.jaas.config (backslash, double-quote, $ for heredoc)
SAFE_PASS_FILE="${NEW_PASS//\\/\\\\}"
SAFE_PASS_FILE="${SAFE_PASS_FILE//\"/\\\"}"
SAFE_PASS_FILE="${SAFE_PASS_FILE//\$/\\$}"

# 1) credentials.txt — human-readable summary
cat <<EOF > "$PACK_DIR/credentials.txt"
=========================================
KAFKA USER CREDENTIALS (SASL_PLAIN)
=========================================
System Name : $SYSTEM_NAME
Kafka User  : $KAFKA_USER
Credential  : $NEW_PASS
Mechanism   : SASL_PLAIN

[BOOTSTRAP] (use both for resilience)
$BOOTSTRAP_BOTH

Topic       : $TOPIC_NAME
ACL         : $ACL_DESC — $ACL_WHAT

Generated   : $(date)
=========================================
EOF
if [ -n "$TRUSTSTORE_PASSWORD" ]; then
    echo "Truststore password (for client.properties): $TRUSTSTORE_PASSWORD" >> "$PACK_DIR/credentials.txt"
    echo "=========================================" >> "$PACK_DIR/credentials.txt"
fi

# 2) client.properties — ready to use (user/pass + bootstrap + cert path inside this folder)
if [ -n "$TRUSTSTORE_BASENAME" ]; then
    REL_TRUSTSTORE="./certs/$TRUSTSTORE_BASENAME"
else
    REL_TRUSTSTORE="/path/to/your/kafka-truststore.jks"
fi
cat <<EOF > "$PACK_DIR/client.properties"
# Kafka client — ready to use. User/password and cert are in this folder.
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="$KAFKA_USER" password="$SAFE_PASS_FILE";
bootstrap.servers=$BOOTSTRAP_BOTH
ssl.truststore.location=$REL_TRUSTSTORE
ssl.truststore.password=${TRUSTSTORE_PASSWORD:-your_truststore_password}
EOF

# 3) README.txt — how to use after decrypt
cat <<EOF > "$PACK_DIR/README.txt"
KAFKA CLIENT PACK — Usage
========================

1. Decrypt the .enc file you received:
   openssl enc -d -aes-256-cbc -salt -pbkdf2 -in <your_file>.enc -out pack.tar.gz
   (enter the passphrase you set when the pack was created)

2. Unpack and enter the folder:
   tar xzf pack.tar.gz
   cd <extracted_folder>

3. Use client.properties as-is (user, password, bootstrap, and cert are in this folder):
   kafka-console-consumer.sh --bootstrap-server $BOOTSTRAP_CWDC --topic YOUR_TOPIC --consumer.config ./client.properties --from-beginning --max-messages 5
   Or with kafka-console-producer.sh use --producer.config ./client.properties

4. credentials.txt has the same user/password and truststore password for reference.
EOF

# 4) Tar.gz the folder, then encrypt the archive (encrypt level: .tar.gz then encrypt). Output always in USER_OUTPUT_DIR.
TARBALL="${USER_OUTPUT_DIR}/${SYSTEM_NAME}_${TIMESTAMP}.tar.gz"
tar czf "$TARBALL" -C "$TMP_DIR" "$PACK_NAME"
echo -n "$PASS1" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass stdin -in "$TARBALL" -out "$ENC_FILE"
rm -f "$TARBALL"
rm -rf "$PACK_DIR"

# Logging
log_action "GEN | what=add_user_and_pack | system=$SYSTEM_NAME | user=$KAFKA_USER | topic=$TOPIC_NAME | sites=$NUM_SITES | file=$ENC_FILE | namespaces=${SITE_NS[*]} | secret=$K8S_SECRET_NAME"

# 6. FINAL SUCCESS & DECRYPT GUIDE
clear
echo -e "${GREEN}✔ PROVISIONING SUCCESSFUL!${NC}"
echo -e "-------------------------------------------------------"
echo -e " System Name  : $SYSTEM_NAME"
echo -e " Kafka User   : $KAFKA_USER"
echo -e " OCP Sites    : $NUM_SITES site(s)"
[ "$VALIDATE_PASSED" = "true" ] && echo -e " Validated    : ${GREEN}Yes (auth tested before pack)${NC}"
echo -e " History Log  : Recorded in provisioning.log"
echo -e " Secure File  : ${YELLOW}$ENC_FILE${NC}"
echo -e "-------------------------------------------------------"

echo -e "\n${CYAN}HOW TO DECRYPT AND UNPACK:${NC}"
echo -e " 1) Decrypt (enter passphrase when prompted):"
echo -e "    ${YELLOW}openssl enc -d -aes-256-cbc -salt -pbkdf2 -in $ENC_FILE -out ${PACK_NAME}.tar.gz${NC}"
echo -e " 2) Unpack the folder:"
echo -e "    ${YELLOW}tar xzf ${PACK_NAME}.tar.gz && cd ${PACK_NAME}${NC}"
echo -e "    Inside: credentials.txt, client.properties, certs/, README.txt"

echo -e "\n${RED}SECURITY NOTE: User injected into plain-users.json.${NC}\n"

    # Ask if user wants to continue or go back to menu (skip when non-interactive)
    if [ "${GEN_NONINTERACTIVE}" = "1" ]; then
        echo "GEN_VALIDATE_PASSED=$VALIDATE_PASSED"
        echo "GEN_PACK_DIR=$USER_OUTPUT_DIR"
        echo "GEN_PACK_FILE=$(basename "$ENC_FILE")"
        echo "GEN_PACK_NAME=$PACK_NAME"
        exit 0
    fi
    echo -e "\n   ${CYAN}Options:${NC}"
    echo "   [M] Main menu"
    echo "   [Q] Quit"
    read -p "   Your choice [M/Q]: " ADD_CHOICE
    [[ "$ADD_CHOICE" =~ ^[Qq]$ ]] && { echo -e "   ${CYAN}Exiting...${NC}"; exit 0; }
    [[ "$ADD_CHOICE" =~ ^[Mm]$ ]] && continue
    continue  # Default: go back to main menu
done
