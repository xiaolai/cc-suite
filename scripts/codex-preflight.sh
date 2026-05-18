#!/usr/bin/env bash
# codex-preflight.sh — Discover available Codex models from the local models cache.
#
# Usage:  bash scripts/codex-preflight.sh
# Output: JSON to stdout  (human summary to stderr)
#
# Caching: Results are cached for 5 minutes in $XDG_CACHE_HOME/codex-toolkit/preflight-cache.json.
#          Set CODEX_PREFLIGHT_NO_CACHE=1 to skip cache.
#
# How it works:
#   Reads ~/.codex/models_cache.json (maintained by the codex CLI) to get the
#   list of available models. Zero hardcoded model names — new models appear
#   automatically after `codex login` refreshes the cache.
#   If cache is missing, attempts to refresh it via `codex login --refresh`.

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

CLOUD_TIMEOUT=5          # seconds to wait for codex cloud list
CACHE_TTL=300            # seconds (5 minutes) for our own preflight cache
REFRESH_TIMEOUT=15       # seconds to wait for codex login --refresh

# Static options (stable CLI flags — no need to probe).
REASONING_EFFORTS='["low","medium","high"]'
SANDBOX_LEVELS='["read-only","workspace-write","danger-full-access"]'

# ── Helpers ──────────────────────────────────────────────────────────────────

info() { echo "$*" >&2; }

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

resolve_timeout_cmd() {
  if command -v timeout &>/dev/null; then
    echo "timeout"
  elif command -v gtimeout &>/dev/null; then
    echo "gtimeout"
  else
    echo ""
  fi
}

json_array() {
  if [[ $# -eq 0 ]]; then
    echo "[]"
    return
  fi
  local result="["
  local first=true
  for item in "$@"; do
    if $first; then first=false; else result+=","; fi
    result+="\"$item\""
  done
  result+="]"
  echo "$result"
}

file_age_seconds() {
  local file="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    echo $(( $(date +%s) - $(stat -f %m "$file") ))
  else
    echo $(( $(date +%s) - $(stat -c %Y "$file") ))
  fi
}

# ── Step 0: Check our own preflight cache ────────────────────────────────────

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codex-toolkit"
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/preflight-cache.json"

if [[ -z "${CODEX_PREFLIGHT_NO_CACHE:-}" && -f "$CACHE_FILE" ]]; then
  cache_age=$(file_age_seconds "$CACHE_FILE")
  if [[ $cache_age -lt $CACHE_TTL ]]; then
    info "Using cached results (${cache_age}s old, TTL ${CACHE_TTL}s)"
    cat "$CACHE_FILE"
    exit 0
  fi
fi

# ── Step 1: Check codex CLI ──────────────────────────────────────────────────

if ! command -v codex &>/dev/null; then
  cat <<'JSON'
{"status":"error","error":"codex CLI not found. Install: npm install -g @openai/codex","models":[],"reasoning_efforts":[],"sandbox_levels":[]}
JSON
  exit 1
fi

# ── Step 2: Get codex version ────────────────────────────────────────────────

CODEX_VERSION=$(codex --version 2>/dev/null || echo "unknown")
info "Codex version: $CODEX_VERSION"

# ── Step 3: Check authentication ─────────────────────────────────────────────

AUTH_MODE="unknown"

LOGIN_STATUS=$(codex login status 2>&1) || true
if echo "$LOGIN_STATUS" | grep -qi "logged in"; then
  if echo "$LOGIN_STATUS" | grep -qi "chatgpt"; then
    AUTH_MODE="chatgpt_login"
  elif echo "$LOGIN_STATUS" | grep -qi "api.key\|api_key"; then
    AUTH_MODE="api_key"
  else
    AUTH_MODE="authenticated"
  fi
elif echo "$LOGIN_STATUS" | grep -qi "not logged in\|not authenticated"; then
  AUTH_MODE="unknown"
else
  AUTH_FILE="$HOME/.codex/auth.json"
  if [[ -f "$AUTH_FILE" ]]; then
    if command -v jq &>/dev/null; then
      AUTH_MODE=$(jq -r '.auth_mode // "unknown"' "$AUTH_FILE" 2>/dev/null || echo "unknown")
    else
      AUTH_MODE=$(grep -o '"auth_mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$AUTH_FILE" 2>/dev/null \
        | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || echo "unknown")
    fi
  fi
fi

if [[ "$AUTH_MODE" == "unknown" && -n "${OPENAI_API_KEY:-}" ]]; then
  AUTH_MODE="api_key"
fi

if [[ "$AUTH_MODE" == "unknown" ]]; then
  CODEX_VERSION_SAFE=$(json_escape "$CODEX_VERSION")
  cat <<JSON
{"status":"error","error":"Not authenticated. Run: codex login","auth_mode":"none","codex_version":"$CODEX_VERSION_SAFE","models":[],"reasoning_efforts":$REASONING_EFFORTS,"sandbox_levels":$SANDBOX_LEVELS}
JSON
  exit 1
fi

info "Auth mode: $AUTH_MODE"

# ── Step 4: Read models from ~/.codex/models_cache.json ──────────────────────

MODELS_CACHE="$HOME/.codex/models_cache.json"
USE_CACHE=false

if [[ -f "$MODELS_CACHE" ]]; then
  USE_CACHE=true
  cache_age=$(file_age_seconds "$MODELS_CACHE")
  info "Reading models from ~/.codex/models_cache.json (${cache_age}s old)"
else
  # No cache — try to create it by triggering a codex login refresh
  info "No models_cache.json found, attempting to refresh..."
  TIMEOUT_CMD=$(resolve_timeout_cmd)
  if [[ -n "$TIMEOUT_CMD" ]]; then
    $TIMEOUT_CMD "$REFRESH_TIMEOUT" codex login --refresh &>/dev/null || true
  else
    codex login --refresh &>/dev/null || true
  fi
  if [[ -f "$MODELS_CACHE" ]]; then
    USE_CACHE=true
    info "Models cache refreshed successfully"
  else
    info "Could not create models cache"
  fi
fi

AVAILABLE=()
# models_detail holds JSON array of {slug, description} objects (from cache path only)
MODELS_DETAIL="[]"

if $USE_CACHE; then
  # Extract model metadata from the cache using python3 (always available on macOS/Linux)
  if command -v python3 &>/dev/null; then
    MODELS_DETAIL=$(python3 -c "
import json, sys
try:
    with open('$MODELS_CACHE') as f:
        data = json.load(f)
    result = []
    for m in data.get('models', []):
        slug = m.get('slug', '')
        if slug:
            result.append({
                'slug': slug,
                'description': m.get('description', slug),
            })
    print(json.dumps(result))
except Exception:
    print('[]')
    sys.exit(1)
" 2>/dev/null) || MODELS_DETAIL="[]"

    # Also populate AVAILABLE array for backward compat and info output
    while IFS= read -r slug; do
      [[ -n "$slug" ]] && AVAILABLE+=("$slug")
    done < <(printf '%s' "$MODELS_DETAIL" | python3 -c "
import json, sys
for m in json.loads(sys.stdin.read()):
    print(m['slug'])
" 2>/dev/null)
  elif command -v jq &>/dev/null; then
    MODELS_DETAIL=$(jq '[.models[] | {slug, description: (.description // .slug)}]' "$MODELS_CACHE" 2>/dev/null) || MODELS_DETAIL="[]"
    while IFS= read -r slug; do
      [[ -n "$slug" ]] && AVAILABLE+=("$slug")
    done < <(echo "$MODELS_DETAIL" | jq -r '.[].slug' 2>/dev/null)
  else
    while IFS= read -r slug; do
      [[ -n "$slug" ]] && AVAILABLE+=("$slug")
    done < <(grep -o '"slug"[[:space:]]*:[[:space:]]*"[^"]*"' "$MODELS_CACHE" 2>/dev/null \
      | sed 's/.*"\([^"]*\)"$/\1/')
  fi

  if [[ ${#AVAILABLE[@]} -eq 0 ]]; then
    info "Warning: models_cache.json parsed but no models found"
    USE_CACHE=false
    MODELS_DETAIL="[]"
  else
    info "Found ${#AVAILABLE[@]} models from cache"
    for model in "${AVAILABLE[@]}"; do
      info "  $model"
    done
  fi
fi

# ── Step 4b: Handle missing cache ────────────────────────────────────────────

UNAVAILABLE=()

if ! $USE_CACHE; then
  CODEX_VERSION_SAFE=$(json_escape "$CODEX_VERSION")
  AUTH_MODE_SAFE=$(json_escape "$AUTH_MODE")
  cat <<JSON
{"status":"error","error":"No models cache found. Run 'codex login' to populate ~/.codex/models_cache.json","codex_version":"$CODEX_VERSION_SAFE","auth_mode":"$AUTH_MODE_SAFE","models":[],"models_detail":[],"reasoning_efforts":$REASONING_EFFORTS,"sandbox_levels":$SANDBOX_LEVELS}
JSON
  exit 1
fi

# ── Step 5: Check Codex Cloud availability ───────────────────────────────────

CODEX_CLOUD="false"
TIMEOUT_CMD=$(resolve_timeout_cmd)
if [[ -n "$TIMEOUT_CMD" ]]; then
  if $TIMEOUT_CMD "$CLOUD_TIMEOUT" codex cloud list &>/dev/null; then
    CODEX_CLOUD="true"
  fi
else
  info "  Skipping cloud check (no timeout command available)"
fi

# ── Step 6: Output JSON ─────────────────────────────────────────────────────

available_json=$(json_array "${AVAILABLE[@]+"${AVAILABLE[@]}"}")
unavailable_json=$(json_array "${UNAVAILABLE[@]+"${UNAVAILABLE[@]}"}")

CODEX_VERSION_SAFE=$(json_escape "$CODEX_VERSION")
AUTH_MODE_SAFE=$(json_escape "$AUTH_MODE")

OUTPUT=$(cat <<JSON
{"status":"ok","codex_version":"$CODEX_VERSION_SAFE","auth_mode":"$AUTH_MODE_SAFE","codex_cloud":$CODEX_CLOUD,"models":$available_json,"models_detail":$MODELS_DETAIL,"unavailable":$unavailable_json,"reasoning_efforts":$REASONING_EFFORTS,"sandbox_levels":$SANDBOX_LEVELS}
JSON
)

echo "$OUTPUT" > "$CACHE_FILE"
echo "$OUTPUT"
