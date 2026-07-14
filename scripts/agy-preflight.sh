#!/usr/bin/env bash
# agy-preflight.sh — Check Antigravity CLI (`agy`) availability, auth, and models.
#
# Emits a stable JSON shape for /cc-suite:google-preflight and agy-aware callers:
#   {"backend":"agy","status":"ok","agy_version":"1.1.2",
#    "default_model":"...","models":[...],"reasoning_efforts":[],
#    "sandbox_levels":[...],"workspace_mcp_registered":true}
#
# Caching: results cached for 5 minutes in $XDG_CACHE_HOME/codex-toolkit/agy-preflight-cache.json.
#          Set AGY_PREFLIGHT_NO_CACHE=1 to skip the cache.
#
# Two facts about agy shape this file:
#
#   * There is no reasoning-effort flag. Effort is baked into the model name
#     ("Gemini 3.1 Pro (High)"), so reasoning_efforts is deliberately an empty
#     array — callers must not offer an effort picker for this backend.
#
#   * There is no non-interactive auth-status command (`agy auth status` opens a
#     TUI and dies without a TTY). `agy models` is used as the connectivity/auth
#     probe instead: it round-trips to Google and fails when unauthenticated.

set -uo pipefail

CACHE_TTL=300
PREFLIGHT_SCHEMA=2
MODELS_TIMEOUT_SECONDS="${AGY_MODELS_TIMEOUT_SECONDS:-10}"
SANDBOX_LEVELS='["read-only","workspace-write","danger-full-access"]'
REASONING_EFFORTS='[]'   # agy encodes effort in the model name — see header

info() { [[ -n "${AGY_PREFLIGHT_VERBOSE:-}" ]] && printf '· %s\n' "$*" >&2; return 0; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

file_age_seconds() {
  local f="$1" now mtime
  now=$(date +%s)
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  echo $(( now - mtime ))
}

run_with_timeout() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}s" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${seconds}s" "$@"
    return $?
  fi

  # macOS does not ship timeout. Keep preflight bounded without requiring a
  # package manager by supervising the child in a temporary output file.
  local output pid waited=0 rc
  output="$(mktemp "${TMPDIR:-/tmp}/cc-suite-agy-models.XXXXXX")"
  "$@" >"$output" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$seconds" ]; then
      kill TERM "$pid" 2>/dev/null || true
      sleep 1
      kill KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      cat "$output"
      rm -f "$output"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"; rc=$?
  cat "$output"
  rm -f "$output"
  return "$rc"
}

# ── Step 1: cache ────────────────────────────────────────────────────────────
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codex-toolkit"
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/agy-preflight-cache.json"

if [[ -z "${AGY_PREFLIGHT_NO_CACHE:-}" && -f "$CACHE_FILE" \
      && "$(grep -c '"preflight_schema":'$PREFLIGHT_SCHEMA "$CACHE_FILE" 2>/dev/null || true)" -gt 0 ]]; then
  cache_age=$(file_age_seconds "$CACHE_FILE")
  if [[ $cache_age -lt $CACHE_TTL ]]; then
    info "Using cached results (${cache_age}s old, TTL ${CACHE_TTL}s)"
    cat "$CACHE_FILE"
    exit 0
  fi
fi

# ── Step 2: is agy installed? ────────────────────────────────────────────────
if ! command -v agy >/dev/null 2>&1; then
  cat <<'JSON'
{"backend":"agy","preflight_schema":2,"status":"error","error_code":"agy_not_found","error":"agy not found on PATH. Install Antigravity CLI (antigravity-cli): curl -fsSL https://antigravity.google/cli/install.sh | bash","agy_version":null,"default_model":null,"models":[],"reasoning_efforts":[],"sandbox_levels":["read-only","workspace-write","danger-full-access"],"workspace_mcp_registered":false,"claude_mcp_registered":false}
JSON
  exit 0
fi

AGY_VERSION="$(agy --version 2>/dev/null | head -1 | tr -d '\r')"
AGY_VERSION_SAFE="$(json_escape "${AGY_VERSION:-unknown}")"
info "agy version: ${AGY_VERSION:-unknown}"

# ── Step 3: models (doubles as the auth/connectivity probe) ──────────────────
# `agy models` prints one display name per line. It requires a live authenticated
# session, so a non-zero exit or empty list means "not signed in". The timeout is
# essential: an auth/network problem must not hang /cc-suite:google-preflight.
MODELS_RAW="$(run_with_timeout "$MODELS_TIMEOUT_SECONDS" agy models 2>/dev/null | sed -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^Available/d')"
MODELS_RC=$?

# Some agy builds have emitted authentication failures on stdout with exit 0.
# Never expose those diagnostic lines as selectable model names.
if printf '%s\n' "$MODELS_RAW" | grep -qiE '(^|[[:space:]])(error:|please sign in|not signed in|not authenticated)'; then
  MODELS_RC=1
fi

if [[ "$MODELS_RC" -ne 0 || -z "$MODELS_RAW" ]]; then
  if [[ "$MODELS_RC" -eq 124 ]]; then
    ERROR="agy model discovery timed out after ${MODELS_TIMEOUT_SECONDS}s — run agy interactively to sign in, then retry"
    ERROR_CODE="agy_probe_timeout"
  else
    ERROR="agy is installed but model discovery failed — run agy interactively to sign in"
    ERROR_CODE="agy_not_authenticated"
  fi
  cat <<JSON
{"backend":"agy","preflight_schema":$PREFLIGHT_SCHEMA,"status":"error","error_code":"$ERROR_CODE","error":"$(json_escape "$ERROR")","agy_version":"$AGY_VERSION_SAFE","default_model":null,"models":[],"reasoning_efforts":$REASONING_EFFORTS,"sandbox_levels":$SANDBOX_LEVELS,"workspace_mcp_registered":false,"claude_mcp_registered":false}
JSON
  exit 0
fi

MODELS_JSON="["
first=1
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  esc="$(json_escape "$line")"
  if [[ $first -eq 1 ]]; then
    MODELS_JSON+="\"$esc\""
    first=0
  else
    MODELS_JSON+=",\"$esc\""
  fi
done <<< "$MODELS_RAW"
MODELS_JSON+="]"

model_count="$(printf '%s\n' "$MODELS_RAW" | wc -l | tr -d ' ')"
info "models: $model_count"

# ── Step 4: is the reverse bridge (agy → Claude Code) registered? ────────────
# Agy supports workspace and global MCP profiles. Prefer the workspace profile
# generated by cc-suite, while also reporting a global registration.
AGY_WORKSPACE_MCP_CONFIG="$PWD/.agents/mcp_config.json"
AGY_GLOBAL_MCP_CONFIG="$HOME/.gemini/config/mcp_config.json"
WORKSPACE_MCP_REGISTERED=false
CLAUDE_MCP_REGISTERED=false
if [[ -s "$AGY_WORKSPACE_MCP_CONFIG" ]] && grep -q "claude-octopus" "$AGY_WORKSPACE_MCP_CONFIG" 2>/dev/null; then
  WORKSPACE_MCP_REGISTERED=true
  CLAUDE_MCP_REGISTERED=true
fi
if [[ -s "$AGY_GLOBAL_MCP_CONFIG" ]] && grep -q "claude-octopus" "$AGY_GLOBAL_MCP_CONFIG" 2>/dev/null; then
  CLAUDE_MCP_REGISTERED=true
fi
info "claude-code MCP registered in agy workspace: $WORKSPACE_MCP_REGISTERED"
info "claude-code MCP registered in agy global config: $CLAUDE_MCP_REGISTERED"

# ── Step 5: emit + cache ─────────────────────────────────────────────────────
DEFAULT_MODEL="$(printf '%s\n' "$MODELS_RAW" | head -1)"
DEFAULT_MODEL_SAFE="$(json_escape "$DEFAULT_MODEL")"
RESULT="{\"backend\":\"agy\",\"preflight_schema\":$PREFLIGHT_SCHEMA,\"status\":\"ok\",\"agy_version\":\"$AGY_VERSION_SAFE\",\"default_model\":\"$DEFAULT_MODEL_SAFE\",\"models\":$MODELS_JSON,\"reasoning_efforts\":$REASONING_EFFORTS,\"sandbox_levels\":$SANDBOX_LEVELS,\"workspace_mcp_registered\":$WORKSPACE_MCP_REGISTERED,\"claude_mcp_registered\":$CLAUDE_MCP_REGISTERED}"

printf '%s\n' "$RESULT" > "$CACHE_FILE"
printf '%s\n' "$RESULT"
