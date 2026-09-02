#!/usr/bin/env bash
# codex-preflight.sh — Discover available Codex models from the local models cache.
#
# Usage:  bash scripts/codex-preflight.sh
# Output: JSON to stdout  (human summary to stderr)
#
# Caching: Results are cached for 5 minutes in
#          $XDG_CACHE_HOME/codex-toolkit/preflight-cache-<script-checksum>.json.
#          Set CODEX_PREFLIGHT_NO_CACHE=1 to skip cache.
#
# How it works:
#   Reads ~/.codex/models_cache.json (maintained by the codex CLI) to get the
#   list of available models. The cache is not guaranteed to be newest first
#   (and includes special-purpose models such as codex-auto-review), so the
#   preflight ranks general models by an explicit "latest" description marker,
#   then model version, with Codex priority as a tie-breaker.
#   If cache is missing, runs a minimal `codex exec` to populate it — the CLI
#   writes the cache at session start. (`codex login --refresh` used to do this
#   but the flag was removed in codex-cli 0.147.0; `login status` and `doctor`
#   do not touch the cache.)

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

CLOUD_TIMEOUT=5          # seconds to wait for codex cloud list
CACHE_TTL=300            # seconds (5 minutes) for our own preflight cache
# Seconds for the cache-populating codex exec (a real model roundtrip). Bounded
# by diagnose.py, which runs this whole script under a 60s subprocess timeout,
# or diagnose loses its model_pin check in exactly the broken-cache state it
# judges. The worst path is the one where BOTH bounded probes hang: the refresh
# writes a usable cache and then hangs (REFRESH_TIMEOUT + 1s kill grace + 1s
# loop granularity), execution continues, and the cloud probe hangs too
# (CLOUD_TIMEOUT + 1s). At 30/5 that is 38s, leaving room for the `codex
# --version` and `codex login status` startups ahead of it.
REFRESH_TIMEOUT=30
# Bumped whenever the emitted payload changes shape — it is also what
# invalidates the 5-minute cache, so a new field must bump it or upgraded
# installs replay a payload that lacks the field for a whole TTL.
PREFLIGHT_SCHEMA=4       # caller-facing contract version of the emitted payload

# Fallback options used only when an older/partial models cache has no
# reasoning-level metadata. A current cache replaces these with the union of
# the supported levels advertised by its models.
REASONING_EFFORTS='["low","medium","high"]'
SANDBOX_LEVELS='["read-only","workspace-write","danger-full-access"]'

# ── Helpers ──────────────────────────────────────────────────────────────────

info() { echo "$*" >&2; }

# Must encode, never drop: `models` is escaped here while `models_detail` is
# escaped by python's json.dumps, and a slug that survives one path but is
# altered by the other cannot be matched across the two arrays.
json_escape() {
  local s="$1" byte esc i
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # JSON forbids raw bytes below 0x20; \n, \r and \t are already encoded above.
  for i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    printf -v byte '%b' "\\0$(printf '%03o' "$i")"
    case "$s" in
      *"$byte"*)
        printf -v esc '\\u%04x' "$i"
        s="${s//"$byte"/$esc}"
        ;;
    esac
  done
  printf '%s' "$s"
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

  # Stock macOS ships neither. Supervise the child here so no probe can hang
  # the preflight. `set -m` makes it a process-group leader, so the deadline
  # signals its descendants too; only stdout is captured, as with `timeout`.
  local output pid waited=0 rc
  output="$(mktemp "${TMPDIR:-/tmp}/cc-suite-codex-preflight.XXXXXX")"
  set -m
  "$@" >"$output" &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$waited" -ge "$seconds" ]]; then
      kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      cat "$output"
      rm -f "$output"
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" || rc=$?
  rc=${rc:-0}
  cat "$output"
  rm -f "$output"
  return "$rc"
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
    result+="\"$(json_escape "$item")\""
  done
  result+="]"
  echo "$result"
}

# Every error path emits the same stable shape as the ok payload — callers
# switch on `status`/`error_code`, and a missing field is a caller crash.
emit_error() { # error_code, message, [json-encoded version], [auth_mode]
  local code="$1" message="$2" version="${3:-null}" auth="${4:-none}"
  printf '{"backend":"codex","preflight_schema":%s,"status":"error","error_code":"%s","error":"%s","codex_version":%s,"auth_mode":"%s","codex_cloud":false,"default_model":null,"models":[],"models_detail":[],"unavailable":[],"reasoning_efforts":%s,"sandbox_levels":%s}\n' \
    "$PREFLIGHT_SCHEMA" "$code" "$(json_escape "$message")" "$version" "$(json_escape "$auth")" \
    "$REASONING_EFFORTS" "$SANDBOX_LEVELS"
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
# The cache is keyed on this script's own content, so a payload written by any
# other build is simply never read. Callers dereference every field of the
# documented shape, and a field added to that payload without a matching bump of
# a hand-maintained constant would otherwise be missing for up to CACHE_TTL
# seconds after an upgrade — which is exactly what happened to `backend`.
# An environment that cannot compute the key gets no cache rather than an
# unkeyed one shared across builds.
SCRIPT_KEY="$({ cksum < "${BASH_SOURCE[0]}" | awk '{print $1}'; } 2>/dev/null)" || SCRIPT_KEY=""
CACHE_FILE="$CACHE_DIR/preflight-cache-${SCRIPT_KEY}.json"

cache_is_valid_json() {
  # A truncated/concurrent write must not be replayed as a preflight result.
  # Without python3 the atomic-rename write path is the only guard.
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
}

if [[ -z "${CODEX_PREFLIGHT_NO_CACHE:-}" && -n "$SCRIPT_KEY" && -f "$CACHE_FILE" ]] \
      && cache_is_valid_json "$CACHE_FILE"; then
  cache_age=$(file_age_seconds "$CACHE_FILE")
  if [[ $cache_age -lt $CACHE_TTL ]]; then
    info "Using cached results (${cache_age}s old, TTL ${CACHE_TTL}s)"
    cat "$CACHE_FILE"
    exit 0
  fi
fi

# ── Step 1: Check codex CLI ──────────────────────────────────────────────────

if ! command -v codex &>/dev/null; then
  emit_error "codex_not_found" "codex CLI not found. Install: npm install -g @openai/codex"
  exit 0
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
  emit_error "codex_not_authenticated" "Not authenticated. Run: codex login" \
    "\"$(json_escape "$CODEX_VERSION")\""
  exit 0
fi

info "Auth mode: $AUTH_MODE"

# ── Step 4: Read models from ~/.codex/models_cache.json ──────────────────────

MODELS_CACHE="$HOME/.codex/models_cache.json"
REFRESH_ATTEMPTED=false

AVAILABLE=()
# models_detail holds JSON array of {slug, description} objects (from cache path only)
MODELS_DETAIL="[]"

# The CLI writes the cache at session start, so trigger a minimal
# non-interactive exec. Costs one tiny model call; only happens when the cache
# is absent or unusable (effectively first run on a machine).
# A refresh is a real, billable model roundtrip. Without a cooldown every
# invocation on a broken-cache machine — and the preflight runs from hooks,
# /init, /update and every model-selecting command — spends another call and
# another timeout budget to fail the same way. Record the attempt and refuse to
# repeat it until the cooldown expires.
REFRESH_COOLDOWN=900   # seconds between refresh attempts after a failure
REFRESH_STAMP="$CACHE_DIR/last-refresh-attempt"

refresh_on_cooldown() {
  [[ -f "$REFRESH_STAMP" ]] || return 1
  local age
  age=$(file_age_seconds "$REFRESH_STAMP") || return 1
  [[ $age -lt $REFRESH_COOLDOWN ]]
}

populate_models_cache() {
  if refresh_on_cooldown; then
    info "Skipping models-cache refresh: the last attempt was under $((REFRESH_COOLDOWN / 60))m ago"
    return 1
  fi
  : > "$REFRESH_STAMP" 2>/dev/null || true
  REFRESH_ATTEMPTED=true
  local refresh_out refresh_rc=0
  refresh_out=$(run_with_timeout "$REFRESH_TIMEOUT" \
    codex exec --sandbox read-only --skip-git-repo-check -C "${TMPDIR:-/tmp}" \
    "Reply with the single word: ok" </dev/null 2>&1) || refresh_rc=$?
  # The cache file existing is not evidence of a refresh: on the unusable-cache
  # path it was already there. Only the exec's own exit status distinguishes a
  # refresh that ran from one that failed and left the stale file behind.
  if [[ $refresh_rc -eq 0 && -f "$MODELS_CACHE" ]]; then
    rm -f "$REFRESH_STAMP" 2>/dev/null || true
    info "Models cache populated successfully"
    return 0
  fi
  info "Could not create models cache. Output from codex exec:"
  info "$(printf '%s\n' "$refresh_out" | tail -3)"
  return 1
}

# Sets AVAILABLE/MODELS_DETAIL/REASONING_EFFORTS; returns non-zero when the
# cache yields no models, leaving the fallback options untouched.
load_models_cache() {
  local efforts_before="$REASONING_EFFORTS"
  AVAILABLE=()
  MODELS_DETAIL="[]"

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
    MODELS_DETAIL="[]"
    REASONING_EFFORTS="$efforts_before"
    return 1
  fi
  return 0
}

if [[ -f "$MODELS_CACHE" ]]; then
  cache_age=$(file_age_seconds "$MODELS_CACHE")
  info "Reading models from ~/.codex/models_cache.json (${cache_age}s old)"
else
  info "No models_cache.json found, running a minimal 'codex exec' to populate it..."
  populate_models_cache || true
fi

MODELS_LOADED=false
if [[ -f "$MODELS_CACHE" ]] && load_models_cache; then
  MODELS_LOADED=true
elif ! $REFRESH_ATTEMPTED; then
  # A present-but-unusable cache is stale, not fatal: it gets the same single
  # bounded refresh a missing cache gets, then one reparse.
  info "Warning: models_cache.json parsed but no models found, refreshing via 'codex exec'..."
  populate_models_cache || true
  if [[ -f "$MODELS_CACHE" ]] && load_models_cache; then
    MODELS_LOADED=true
  fi
fi

# ── Step 4b: Handle missing cache ────────────────────────────────────────────

if ! $MODELS_LOADED; then
  emit_error "codex_no_models_cache" \
    "No usable models cache. Run any codex session once (e.g. codex exec 'say ok') to repopulate ~/.codex/models_cache.json" \
    "\"$(json_escape "$CODEX_VERSION")\"" "$AUTH_MODE"
  exit 0
fi

info "Found ${#AVAILABLE[@]} models from cache"
for model in "${AVAILABLE[@]}"; do
  info "  $model"
done

# ── Step 5: Check Codex Cloud availability ───────────────────────────────────

# `codex cloud` writes an `error.log` into its working directory on every run,
# success included, and that file carries the ChatGPT account id. `-C` does not
# relocate it (verified on codex-cli 0.152.0) — only the real cwd does — so the
# probe runs from a private temp dir that is removed right after. Without this
# the preflight leaves the account id behind in every project it checks.
CODEX_CLOUD="false"
CLOUD_PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-suite-codex-cloud-probe.XXXXXX")"
if (cd "$CLOUD_PROBE_DIR" && run_with_timeout "$CLOUD_TIMEOUT" codex cloud list </dev/null &>/dev/null); then
  CODEX_CLOUD="true"
fi
rm -rf "$CLOUD_PROBE_DIR"

# ── Step 6: Output JSON ─────────────────────────────────────────────────────

available_json=$(json_array "${AVAILABLE[@]+"${AVAILABLE[@]}"}")
# No unavailable-model calculation exists; the field stays for schema stability.
unavailable_json="[]"

CODEX_VERSION_SAFE=$(json_escape "$CODEX_VERSION")
AUTH_MODE_SAFE=$(json_escape "$AUTH_MODE")
DEFAULT_MODEL_SAFE=$(json_escape "${AVAILABLE[0]}")

OUTPUT=$(cat <<JSON
{"backend":"codex","preflight_schema":$PREFLIGHT_SCHEMA,"status":"ok","codex_version":"$CODEX_VERSION_SAFE","auth_mode":"$AUTH_MODE_SAFE","codex_cloud":$CODEX_CLOUD,"default_model":"$DEFAULT_MODEL_SAFE","models":$available_json,"models_detail":$MODELS_DETAIL,"unavailable":$unavailable_json,"reasoning_efforts":$REASONING_EFFORTS,"sandbox_levels":$SANDBOX_LEVELS}
JSON
)

# Atomic cache commit — a concurrent reader must never observe a partial write.
if [[ -n "$SCRIPT_KEY" ]]; then
  CACHE_TMP="$(mktemp "$CACHE_FILE.XXXXXX")"
  printf '%s\n' "$OUTPUT" > "$CACHE_TMP"
  mv -f "$CACHE_TMP" "$CACHE_FILE"
fi
echo "$OUTPUT"
