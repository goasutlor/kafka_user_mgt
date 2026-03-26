#!/usr/bin/env bash
# Sourced inside the app container before bundled gen.sh (via gen-in-container / image entry).
# Aligns CLI with Portal when the operator did not set GEN_OCP_SITES / GEN_ACTIVE_ENV_ID:
#   - Prefer synced environments.json under GEN_BASE_DIR (same file gen.sh + Portal use).
#   - Else derive OCP sites (+ optional bootstrap) from /app/config/master.config.json.
#
# Override/disable: export GEN_SKIP_PORTAL_PARITY=1  OR  set GEN_OCP_SITES explicitly.

# shellcheck shell=bash
# Do not `set -e` — this file is sourced.

if [[ -n "${GEN_SKIP_PORTAL_PARITY:-}" ]]; then
  __pp_set_audit_paths
  return 0 2>/dev/null || exit 0
fi
if [[ -n "${GEN_OCP_SITES:-}" ]]; then
  __pp_set_audit_paths
  return 0 2>/dev/null || exit 0
fi

BASE_DIR="${GEN_BASE_DIR:-/opt/kafka-usermgmt}"
MASTER="${PORTAL_MASTER_CONFIG:-${GEN_MASTER_CONFIG:-/app/config/master.config.json}}"
ENV_JSON="${GEN_ENVIRONMENTS_JSON:-$BASE_DIR/environments.json}"

if ! command -v jq &>/dev/null; then
  echo "[portal-parity] jq not found — skipping (install jq in image)" >&2
  return 0 2>/dev/null || exit 0
fi

__pp_msg() { echo "[portal-parity] $*" >&2; }

# Same audit.log + download-history.json as Web (under config dir or config/environments/{id}/).
__pp_set_audit_paths() {
  # If audit path was pre-exported (e.g. host env), still align download-history sibling unless set.
  if [[ -n "${GEN_PORTAL_AUDIT_LOG:-}" ]]; then
    if [[ -z "${GEN_PORTAL_DOWNLOAD_HISTORY_JSON:-}" ]]; then
      export GEN_PORTAL_DOWNLOAD_HISTORY_JSON="$(dirname "$GEN_PORTAL_AUDIT_LOG")/download-history.json"
    fi
    return 0
  fi
  local m="${PORTAL_MASTER_CONFIG:-${GEN_MASTER_CONFIG:-/app/config/master.config.json}}"
  [[ -f "$m" ]] || return 0
  local cfgdir env_on id
  cfgdir=$(dirname "$m")
  env_on=$(jq -r '.environments.enabled // false' "$m" 2>/dev/null)
  id="${GEN_ACTIVE_ENV_ID:-}"
  if [[ "$env_on" == "true" ]] && [[ -n "$id" ]]; then
    export GEN_PORTAL_AUDIT_LOG="$cfgdir/environments/$id/audit.log"
    export GEN_PORTAL_DOWNLOAD_HISTORY_JSON="$cfgdir/environments/$id/download-history.json"
  else
    export GEN_PORTAL_AUDIT_LOG="$cfgdir/audit.log"
    export GEN_PORTAL_DOWNLOAD_HISTORY_JSON="$cfgdir/download-history.json"
  fi
}

# --- environments.json (Portal syncs this when multi-env is enabled) ---
if [[ -f "$ENV_JSON" ]]; then
  enabled=$(jq -r 'if .enabled == false then "false" else "true" end' "$ENV_JSON" 2>/dev/null || echo "true")
  if [[ "$enabled" != "false" ]]; then
    export GEN_ENVIRONMENTS_JSON="$ENV_JSON"
    if [[ -z "${GEN_ACTIVE_ENV_ID:-}" ]]; then
      def=$(jq -r '.defaultEnvironmentId // empty' "$ENV_JSON" 2>/dev/null)
      if [[ -z "$def" ]]; then
        def=$(jq -r '[.environments[]? | select(.enabled != false) | .id] | first // empty' "$ENV_JSON" 2>/dev/null)
      fi
      if [[ -n "$def" ]]; then
        export GEN_ACTIVE_ENV_ID="$def"
        __pp_msg "GEN_ACTIVE_ENV_ID=$def (from environments.json default)"
      fi
    else
      __pp_msg "GEN_ACTIVE_ENV_ID already set ($GEN_ACTIVE_ENV_ID)"
    fi
    if [[ -n "${GEN_ACTIVE_ENV_ID:-}" ]]; then
      if [[ -z "${GEN_USER_OUTPUT_DIR:-}" ]]; then
        export GEN_USER_OUTPUT_DIR="${BASE_DIR}/user_output/${GEN_ACTIVE_ENV_ID}"
      fi
    fi
    __pp_set_audit_paths
    return 0 2>/dev/null || exit 0
  fi
  __pp_msg "environments.json has enabled:false — using master.config for OCP sites"
else
  __pp_msg "no $ENV_JSON — trying master.config ($MASTER)"
fi

# --- master.config.json only ---
if [[ ! -f "$MASTER" ]]; then
  __pp_msg "master.config not at $MASTER — gen.sh will use generic built-in defaults"
  return 0 2>/dev/null || exit 0
fi

env_on=$(jq -r '.environments.enabled // false' "$MASTER" 2>/dev/null)
if [[ "$env_on" == "true" ]]; then
  def=$(jq -r '.environments.defaultEnvironmentId // empty' "$MASTER" 2>/dev/null)
  if [[ -z "$def" ]]; then
    def=$(jq -r '.environments.environments[0].id // empty' "$MASTER" 2>/dev/null)
  fi
  if [[ -z "$def" ]]; then
    __pp_msg "environments.enabled but no environments[] — check master.config"
    return 0 2>/dev/null || exit 0
  fi

  pairs=$(jq -r --arg id "$def" '
    ([.environments.environments[]? | select(.enabled != false) | select(.id == $id)] | first) as $e
    | if $e == null then ""
      elif ($e.sites | type) == "array" and ($e.sites | length) > 0 then
        $e.sites | map(select(.namespace != null and .ocContext != null) | "\(.ocContext):\(.namespace)") | join(",")
      elif ($e.namespace != null and $e.namespace != "") and ($e.ocContext != null and $e.ocContext != "") then
        "\($e.ocContext):\($e.namespace)"
      else "" end
  ' "$MASTER" 2>/dev/null)
  pairs=$(echo "$pairs" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  boot=$(jq -r --arg id "$def" '
    ([.environments.environments[]? | select(.enabled != false) | select(.id == $id)] | first) as $e
    | if $e == null then ""
      else ($e.bootstrapServers // "") | tostring | gsub("^\\s+";"") | gsub("\\s+$";"") end
  ' "$MASTER" 2>/dev/null)
  if [[ -z "$boot" || "$boot" == "null" ]]; then
    boot=$(jq -r '.kafka.bootstrapServers // empty' "$MASTER" 2>/dev/null)
  fi
  boot=$(echo "$boot" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [[ -n "$pairs" ]]; then
    export GEN_OCP_SITES="$pairs"
    export GEN_ACTIVE_ENV_ID="$def"
    [[ -n "$boot" ]] && export GEN_KAFKA_BOOTSTRAP="$boot"
    export GEN_USER_OUTPUT_DIR="${BASE_DIR}/user_output/${def}"
    __pp_msg "GEN_OCP_SITES=$GEN_OCP_SITES GEN_ACTIVE_ENV_ID=$def (from master; create environments.json via Portal for full prop parity)"
  else
    __pp_msg "master env '$def' has no resolvable sites[] — check master.config"
  fi
  __pp_set_audit_paths
  return 0 2>/dev/null || exit 0
fi

# Legacy single / dual cluster: fallbackSites
pairs=$(jq -r '
  if (.fallbackSites | type) == "array" and (.fallbackSites | length) > 0 then
    [.fallbackSites[]? | select(.namespace != null and .ocContext != null) | "\(.ocContext):\(.namespace)")] | join(",")
  else empty end
' "$MASTER" 2>/dev/null)
pairs=$(echo "$pairs" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [[ -n "$pairs" ]]; then
  export GEN_OCP_SITES="$pairs"
  boot=$(jq -r '.kafka.bootstrapServers // empty' "$MASTER" 2>/dev/null)
  boot=$(echo "$boot" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -n "$boot" ]] && export GEN_KAFKA_BOOTSTRAP="$boot"
  __pp_msg "GEN_OCP_SITES from master fallbackSites (+ bootstrap if set)"
else
  __pp_msg "no fallbackSites in master — gen.sh built-in defaults apply"
fi

__pp_set_audit_paths
return 0 2>/dev/null || exit 0
