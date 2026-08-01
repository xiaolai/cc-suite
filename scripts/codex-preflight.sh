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
#   list of available models. The cache is not guaranteed to be newest first
#   (and includes special-purpose models such as codex-auto-review), so the
#   preflight ranks general models by an explicit "latest" description marker,
#   then model version, with Codex priority as a tie-breaker.
#   If cache is missing, attempts to refresh it via `codex login --refresh`.

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

CLOUD_TIMEOUT=5          # seconds to wait for codex cloud list
CACHE_TTL=300            # seconds (5 minutes) for our own preflight cache
REFRESH_TIMEOUT=15       # seconds to wait for codex login --refresh
PREFLIGHT_SCHEMA=3       # invalidate cached output when its model ordering changes

# Fallback options used only when an older/partial models cache has no
# reasoning-level metadata. A current cache replaces these with the union of
# the supported levels advertised by its models.
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

if [[ -z "${CODEX_PREFLIGHT_NO_CACHE:-}" && -f "$CACHE_FILE" \
      && "$(grep -c "\"preflight_schema\":$PREFLIGHT_SCHEMA" "$CACHE_FILE" 2>/dev/null || true)" -gt 0 ]]; then
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

# All `codex` invocations below redirect stdin from /dev/null. This script may
# run from background/hook contexts (Claude Code hooks, /cc-suite:preflight,
# /cc-suite:init) with no controlling TTY, where `codex` subcommands can
# otherwise block on stdin waiting for interactive prompts.
CODEX_VERSION=$(codex --version </dev/null 2>/dev/null || echo "unknown")
info "Codex version: $CODEX_VERSION"

# ── Step 3: Check authentication ─────────────────────────────────────────────

AUTH_MODE="unknown"

LOGIN_STATUS=$(codex login status </dev/null 2>&1) || true
# Negative phrases first: "Not logged in" contains "logged in", so testing the
# positive phrase first would classify it as authenticated.
if echo "$LOGIN_STATUS" | grep -qi "not logged in\|not authenticated"; then
  AUTH_MODE="unknown"
elif echo "$LOGIN_STATUS" | grep -qi "logged in"; then
  if echo "$LOGIN_STATUS" | grep -qi "chatgpt"; then
    AUTH_MODE="chatgpt_login"
  elif echo "$LOGIN_STATUS" | grep -qi "api.key\|api_key"; then
    AUTH_MODE="api_key"
  else
    AUTH_MODE="authenticated"
  fi
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
    $TIMEOUT_CMD "$REFRESH_TIMEOUT" codex login --refresh </dev/null &>/dev/null || true
  else
    codex login --refresh </dev/null &>/dev/null || true
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
  # Extract and order model metadata. Do not infer recency from the JSON array
  # order: Codex's cache includes older and special-purpose models alongside
  # the current frontier model.
  if command -v python3 &>/dev/null; then
    MODELS_DETAIL=$(python3 -c "
import json, re, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    result = []
    for index, m in enumerate(data.get('models', [])):
        slug = m.get('slug', '')
        if slug:
            try:
                priority = float(m.get('priority', 0))
            except (TypeError, ValueError):
                priority = 0
            description = m.get('description', slug)
            model_text = ' '.join([slug, m.get('display_name', slug), description]).lower()
            version = re.search(r'gpt-(\d+)(?:\.(\d+))?', slug.lower())
            major = int(version.group(1)) if version else -1
            minor = int(version.group(2) or 0) if version else -1
            review_only = 1 if 'auto-review' in slug.lower() or 'automatic approval review' in model_text else 0
            latest_marker = 0 if 'latest' in model_text else 1
            metadata = {
                'slug': slug,
                'display_name': m.get('display_name', slug),
                'description': description,
                'priority': m.get('priority', 0),
                'reasoning_efforts': [
                    level.get('effort')
                    for level in m.get('supported_reasoning_levels', [])
                    if level.get('effort')
                ],
            }
            result.append((review_only, latest_marker, -major, -minor, priority, index, metadata))
    result.sort(key=lambda item: item[:-1])
    result = [item[-1] for item in result]
    print(json.dumps(result))
except Exception:
    print('[]')
    sys.exit(1)
" "$MODELS_CACHE" 2>/dev/null) || MODELS_DETAIL="[]"

    # Also populate AVAILABLE array for backward compat and info output
    while IFS= read -r slug; do
      [[ -n "$slug" ]] && AVAILABLE+=("$slug")
    done < <(printf '%s' "$MODELS_DETAIL" | python3 -c "
import json, sys
for m in json.loads(sys.stdin.read()):
    print(m['slug'])
" 2>/dev/null)

    REASONING_EFFORTS=$(printf '%s' "$MODELS_DETAIL" | python3 -c "
import json, sys
preferred = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra']
seen = {effort for model in json.loads(sys.stdin.read()) for effort in model.get('reasoning_efforts', [])}
print(json.dumps([effort for effort in preferred if effort in seen], separators=(',', ':')))
" 2>/dev/null) || REASONING_EFFORTS='["low","medium","high"]'
  elif command -v jq &>/dev/null; then
    MODELS_DETAIL=$(jq '[.models | to_entries[] | .value + {__index: .key}]
      | map(. + {
          __text: (((.slug // "") + " " + (.display_name // .slug // "") + " " + (.description // .slug // "")) | ascii_downcase),
          __major: (try ((.slug // "") | capture("gpt-(?<major>[0-9]+)").major | tonumber) catch -1),
          __minor: (try ((.slug // "") | capture("gpt-[0-9]+\\.(?<minor>[0-9]+)").minor | tonumber) catch -1),
          __review_only: (if ((.slug // "" | ascii_downcase) | contains("auto-review")) or (((.description // "") | ascii_downcase) | contains("automatic approval review")) then 1 else 0 end),
          __latest_marker: (if (. + {__text: (((.slug // "") + " " + (.display_name // .slug // "") + " " + (.description // .slug // "")) | ascii_downcase)} | .__text | contains("latest")) then 0 else 1 end)
        })
      | sort_by([.__review_only, .__latest_marker, -.__major, -.__minor, (.priority // 0), .__index])
      | map({slug, display_name: (.display_name // .slug), description: (.description // .slug), priority: (.priority // 0), reasoning_efforts: ([.supported_reasoning_levels[]?.effort] // [])})' "$MODELS_CACHE" 2>/dev/null) || MODELS_DETAIL="[]"
    while IFS= read -r slug; do
      [[ -n "$slug" ]] && AVAILABLE+=("$slug")
    done < <(echo "$MODELS_DETAIL" | jq -r '.[].slug' 2>/dev/null)
    REASONING_EFFORTS=$(echo "$MODELS_DETAIL" | jq -c '([.[].reasoning_efforts[]] | unique) as $seen | ["minimal","low","medium","high","xhigh","max","ultra"] | map(select(. as $effort | ($seen | index($effort)) != null))' 2>/dev/null) || REASONING_EFFORTS='["low","medium","high"]'
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
  if $TIMEOUT_CMD "$CLOUD_TIMEOUT" codex cloud list </dev/null &>/dev/null; then
    CODEX_CLOUD="true"
  fi
else
  info "  Skipping cloud check (no timeout command available)"
fi

# ── Step 6: Output JSON ─────────────────────────────────────────────────────

available_json=$(json_array "${AVAILABLE[@]+"${AVAILABLE[@]}"}")
# No unavailable-model calculation exists; the field stays for schema stability.
unavailable_json="[]"

CODEX_VERSION_SAFE=$(json_escape "$CODEX_VERSION")
AUTH_MODE_SAFE=$(json_escape "$AUTH_MODE")

OUTPUT=$(cat <<JSON
{"preflight_schema":$PREFLIGHT_SCHEMA,"status":"ok","codex_version":"$CODEX_VERSION_SAFE","auth_mode":"$AUTH_MODE_SAFE","codex_cloud":$CODEX_CLOUD,"default_model":"${AVAILABLE[0]}","models":$available_json,"models_detail":$MODELS_DETAIL,"unavailable":$unavailable_json,"reasoning_efforts":$REASONING_EFFORTS,"sandbox_levels":$SANDBOX_LEVELS}
JSON
)

echo "$OUTPUT" > "$CACHE_FILE"
echo "$OUTPUT"
