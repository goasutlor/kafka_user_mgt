#!/bin/bash
# =====================================================
# gen-wizard.sh — Add new user: step-by-step interactive
# Keeps gen.sh unchanged; this script validates each step then calls gen.sh once.
# USAGE: Run on Helper Node (same dir as gen.sh). Same pre-reqs: oc, jq, Kafka bin, configs.
# =====================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN_SCRIPT="${GEN_SCRIPT_PATH:-$SCRIPT_DIR/gen.sh}"
[ ! -f "$GEN_SCRIPT" ] && { echo "ERROR: gen.sh not found at $GEN_SCRIPT"; exit 1; }

# Same config as gen.sh (overridable by env)
BASE_DIR="${GEN_BASE_DIR:-/opt/kafka-usermgmt}"
KAFKA_BIN="${GEN_KAFKA_BIN:-$BASE_DIR/kafka_2.13-3.6.1/bin}"
CLIENT_CONFIG="${GEN_CLIENT_CONFIG:-$BASE_DIR/configs/kafka-client.properties}"
ADMIN_CONFIG="${GEN_ADMIN_CONFIG:-$BASE_DIR/configs/kafka-client-master.properties}"
K8S_SECRET_NAME="${GEN_K8S_SECRET_NAME:-kafka-server-side-credentials}"
NS_CWDC="${NS_CWDC:-}"
NS_TLS2="${NS_TLS2:-}"
OCP_CTX_CWDC="${OCP_CTX_CWDC:-}"
OCP_CTX_TLS2="${OCP_CTX_TLS2:-}"
BOOTSTRAP_BOTH="${BOOTSTRAP_BOTH:-}"
if [[ -z "$BOOTSTRAP_BOTH" ]]; then
  _WMASTER="${GEN_MASTER_CONFIG:-${PORTAL_MASTER_CONFIG:-/app/config/master.config.json}}"
  [[ -f "$_WMASTER" ]] && command -v jq &>/dev/null && BOOTSTRAP_BOTH=$(jq -r '.kafka.bootstrapServers // empty' "$_WMASTER" 2>/dev/null)
fi
TIMEOUT_SEC="${TIMEOUT_SEC:-20}"
TMP_DIR="${TMP_DIR:-/tmp}"
SYSTEM_USERS="^(kafka|schema_registry|kafka_connect|control_center|client|admin|user1|user2|an-api-key)$"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

status_msg() { echo -ne " ${CYAN}[...]${NC} $1..."; }
done_msg() { echo -e " ${GREEN}OK${NC}"; }
err_msg() { echo -e " ${RED}$1${NC}"; }
step_header() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}\n"; }

validate_username() {
    local user="$1"
    [ -z "$user" ] && { err_msg "Username is required."; return 1; }
    [ ${#user} -lt 1 ] && { err_msg "Username too short."; return 1; }
    [ ${#user} -gt 64 ] && { err_msg "Username too long (max 64)."; return 1; }
    [[ "$user" =~ [^a-zA-Z0-9._-] ]] && { err_msg "Username may only contain letters, numbers, dots, underscores, hyphens."; return 1; }
    echo "$user" | grep -qE "$SYSTEM_USERS" && { err_msg "Username conflicts with system user: $user"; return 1; }
    return 0
}

# Pre-check
[ ! -f "$ADMIN_CONFIG" ] && { echo "ERROR: Admin config not found at $ADMIN_CONFIG"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required"; exit 1; }
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc required"; exit 1; }
[[ -z "$BOOTSTRAP_BOTH" ]] && { echo "ERROR: Kafka bootstrap not set. Use Portal Setup (master.config kafka.bootstrapServers) or export BOOTSTRAP_BOTH / GEN_MASTER_CONFIG."; exit 1; }
[[ -z "$NS_CWDC" || -z "$OCP_CTX_CWDC" ]] && { echo "ERROR: OCP site not set. Set NS_CWDC + OCP_CTX_CWDC (and optional second site) to match kubeconfig, or use gen.sh with environments.json."; exit 1; }

clear
echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  ADD NEW USER — Step-by-step (Interactive)                 ║${NC}"
echo -e "${YELLOW}║  Each step is validated before the next.                 ║${NC}"
echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"

# --- Step 1: System name + Topic (list + validate) ---
step_header "1" "Identification & Topic"

read -p "   System name (for tracking): " SYSTEM_NAME
[ -z "$SYSTEM_NAME" ] && { err_msg "System name is required."; exit 1; }

echo -e "\n   Fetching topic list..."
$KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config $ADMIN_CONFIG --list 2>/dev/null > "$TMP_DIR/topics.list" || true
if [ -s "$TMP_DIR/topics.list" ]; then
    echo -e "${CYAN}   --- Available topics ---${NC}"
    cat "$TMP_DIR/topics.list" | sed 's/^/   /'
    echo -e "${CYAN}   -------------------------${NC}"
fi

while true; do
    read -p "   Topic name (or Q to quit): " TOPIC_INPUT
    [[ "$TOPIC_INPUT" =~ ^[Qq]$ ]] && { echo "Cancelled."; exit 0; }
    [ -z "$TOPIC_INPUT" ] && { err_msg "Topic is required."; continue; }
    status_msg "Validating topic '$TOPIC_INPUT'"
    timeout $TIMEOUT_SEC $KAFKA_BIN/kafka-topics.sh --bootstrap-server $BOOTSTRAP_BOTH --command-config $ADMIN_CONFIG --describe --topic "$TOPIC_INPUT" > "$TMP_DIR/topic_out" 2>/dev/null || true
    if [ -s "$TMP_DIR/topic_out" ]; then
        done_msg
        TOPIC_NAME="$TOPIC_INPUT"
        break
    fi
    err_msg "Topic '$TOPIC_INPUT' not found or no permission."
done

# --- Step 2: Username (validate + check duplicate) ---
step_header "2" "Username"

echo -e "   Checking existing users..."
JSON_CWDC=$(oc get secret $K8S_SECRET_NAME -n $NS_CWDC --context $OCP_CTX_CWDC -o jsonpath='{.data.plain-users\.json}' 2>/dev/null | base64 -d)
if [ -n "$JSON_CWDC" ]; then
    USER_LIST=$(echo "$JSON_CWDC" | jq -r 'keys[]' 2>/dev/null | grep -vE "$SYSTEM_USERS" | sort || true)
    if [ -n "$USER_LIST" ]; then
        echo -e "${CYAN}   --- Existing users (do not reuse) ---${NC}"
        echo "$USER_LIST" | sed 's/^/   /'
        echo -e "${CYAN}   -------------------------------------${NC}"
    fi
fi

while true; do
    read -p "   Kafka username: " KAFKA_USER
    [ -z "$KAFKA_USER" ] && { err_msg "Username is required."; continue; }
    validate_username "$KAFKA_USER" || continue
    # Check duplicate
    if [ -n "$JSON_CWDC" ]; then
        exists=$(echo "$JSON_CWDC" | jq -r --arg u "$KAFKA_USER" 'if has($u) then "yes" else "no" end')
        if [ "$exists" = "yes" ]; then
            err_msg "User '$KAFKA_USER' already exists. Use Test or Change password instead."
            continue
        fi
    fi
    done_msg
    break
done

# --- Step 3: ACL ---
step_header "3" "Permission"

echo "   [1] Read (consume only)"
echo "   [2] All (full access)"
read -p "   Select [1-2] (default: 2): " ACL_CHOICE
[[ -z "$ACL_CHOICE" ]] && ACL_CHOICE="2"
[[ "$ACL_CHOICE" != "1" ]] && ACL_CHOICE="2"
ACL_VAL="$ACL_CHOICE"

# --- Step 4: Passphrase ---
step_header "4" "Passphrase for .enc file"

while true; do
    read -s -p "   Passphrase: " PASS1; echo
    read -s -p "   Confirm:    " PASS2; echo
    if [ "$PASS1" = "$PASS2" ] && [ -n "$PASS1" ]; then
        echo -e "   ${GREEN}Passphrase matched.${NC}"
        break
    fi
    err_msg "Mismatch or empty. Try again."
done

# --- Step 5: Execute (call gen.sh) ---
step_header "5" "Execute"

echo -e "   Calling gen.sh with the values you entered..."
echo -e "   System: $SYSTEM_NAME | Topic: $TOPIC_NAME | User: $KAFKA_USER | ACL: $ACL_VAL"
read -p "   Proceed? [y/N]: " GO
[[ ! "$GO" =~ ^[Yy]$ ]] && { echo "Cancelled."; exit 0; }

export GEN_NONINTERACTIVE=1
export GEN_MODE=1
export GEN_SYSTEM_NAME="$SYSTEM_NAME"
export GEN_TOPIC_NAME="$TOPIC_NAME"
export GEN_KAFKA_USER="$KAFKA_USER"
export GEN_ACL="$ACL_VAL"
export GEN_PASSPHRASE="$PASS1"
export GEN_BASE_DIR="$BASE_DIR"
export GEN_KAFKA_BIN="$KAFKA_BIN"
export GEN_CLIENT_CONFIG="$CLIENT_CONFIG"
export GEN_ADMIN_CONFIG="$ADMIN_CONFIG"
export GEN_K8S_SECRET_NAME="$K8S_SECRET_NAME"

exec "$GEN_SCRIPT"
