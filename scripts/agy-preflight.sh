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
# A non-integer would defeat the macOS fallback's numeric comparison and leave
# a hung probe unbounded — validate and fall back to the default.
if ! [[ "$MODELS_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  MODELS_TIMEOUT_SECONDS=10
fi
SANDBOX_LEVELS='["read-only","workspace-write","danger-full-access"]'
REASONING_EFFORTS='[]'   # agy encodes effort in the model name — see header

info() { [[ -n "${AGY_PREFLIGHT_VERBOSE:-}" ]] && printf '· %s\n' "$*" >&2; return 0; }

# Must encode, never drop: a model name emitted here is handed straight back to
# `agy --model`, so a silently altered one no longer names a real model.
json_escape() {
  local s="$1" byte esc i
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
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
  # `set -m` makes the child a process-group leader so the deadline can signal
  # its whole group: agy spawns helpers that outlive a signal aimed at the
  # direct child alone. Only stdout is captured, matching `timeout`'s streams.
  local output pid waited=0 rc
  output="$(mktemp "${TMPDIR:-/tmp}/cc-suite-agy-models.XXXXXX")"
  set -m
  "$@" >"$output" &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$seconds" ]; then
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
  wait "$pid"; rc=$?
  cat "$output"
  rm -f "$output"
  return "$rc"
}

# ── Step 1: cache ────────────────────────────────────────────────────────────
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codex-toolkit"
mkdir -p "$CACHE_DIR"
# workspace_mcp_registered depends on $PWD, so the cache is keyed per workspace —
# a single global file could serve one project's bridge status to another.
WORKSPACE_KEY="$(printf '%s' "$PWD" | cksum | awk '{print $1}')"
CACHE_FILE="$CACHE_DIR/agy-preflight-cache-${WORKSPACE_KEY}.json"

cache_is_valid_json() {
  # A truncated/concurrent write must not be replayed as a preflight result.
  # Without python3 the atomic-rename write path is the only guard.
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
}

if [[ -z "${AGY_PREFLIGHT_NO_CACHE:-}" && -f "$CACHE_FILE" \
      && "$(grep -c '"preflight_schema":'$PREFLIGHT_SCHEMA "$CACHE_FILE" 2>/dev/null || true)" -gt 0 ]] \
      && cache_is_valid_json "$CACHE_FILE"; then
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

# A bare grep for the package name also passes on malformed JSON, a disabled or
# commented-out block, and unrelated servers that merely mention claude-octopus.
# Verify the actual mcpServers["claude-code"] entry instead.
#
# Two strictnesses, as commands/shared/agy-call.md documents. `pinned` is for the
# cc-suite-generated workspace profile, which always writes an exact version.
# `any` answers "is the reverse bridge available at all" for a user-managed
# profile, where `claude-octopus@latest` or a globally installed `claude-octopus`
# binary with no args is a working registration, not a broken one.
mcp_claude_registered() {
  local config="$1" mode="$2"
  [[ -s "$config" ]] || return 1
  if ! command -v python3 >/dev/null 2>&1; then
    info "python3 unavailable — cannot verify $config; reporting unregistered"
    return 1
  fi
  python3 - "$config" "$mode" >/dev/null 2>&1 <<'PY'
import json, os, re, sys

PINNED = re.compile(
    r"^(?:@[^/@\s]+/)?claude-octopus@"
    r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
    r"(?:-(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*)?"
    r"(?:\+[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*)?$"
)
ANY_VERSION = re.compile(r"^(?:@[^/@\s]+/)?claude-octopus(?:@\S*)?$")

mode = sys.argv[2]

try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)

servers = data.get("mcpServers") if isinstance(data, dict) else None
entry = servers.get("claude-code") if isinstance(servers, dict) else None
if not isinstance(entry, dict):
    sys.exit(1)
command = entry.get("command")
if not isinstance(command, str) or not command.strip():
    sys.exit(1)
raw_args = entry.get("args")

if mode == "pinned":
    if not isinstance(raw_args, list) or not all(isinstance(a, str) for a in raw_args):
        sys.exit(1)
    sys.exit(0 if any(PINNED.match(a) for a in raw_args) else 1)

args = raw_args if isinstance(raw_args, list) else []
if ANY_VERSION.match(os.path.basename(command.strip())):
    sys.exit(0)
sys.exit(0 if any(isinstance(a, str) and ANY_VERSION.match(a) for a in args) else 1)
PY
}

if mcp_claude_registered "$AGY_WORKSPACE_MCP_CONFIG" pinned; then
  WORKSPACE_MCP_REGISTERED=true
fi
if mcp_claude_registered "$AGY_WORKSPACE_MCP_CONFIG" any \
   || mcp_claude_registered "$AGY_GLOBAL_MCP_CONFIG" any; then
  CLAUDE_MCP_REGISTERED=true
fi
info "claude-code MCP registered in agy workspace: $WORKSPACE_MCP_REGISTERED"
info "claude-code MCP registered in agy global config: $CLAUDE_MCP_REGISTERED"

# ── Step 5: emit + cache ─────────────────────────────────────────────────────
DEFAULT_MODEL="$(printf '%s\n' "$MODELS_RAW" | head -1)"
DEFAULT_MODEL_SAFE="$(json_escape "$DEFAULT_MODEL")"
RESULT="{\"backend\":\"agy\",\"preflight_schema\":$PREFLIGHT_SCHEMA,\"status\":\"ok\",\"agy_version\":\"$AGY_VERSION_SAFE\",\"default_model\":\"$DEFAULT_MODEL_SAFE\",\"models\":$MODELS_JSON,\"reasoning_efforts\":$REASONING_EFFORTS,\"sandbox_levels\":$SANDBOX_LEVELS,\"workspace_mcp_registered\":$WORKSPACE_MCP_REGISTERED,\"claude_mcp_registered\":$CLAUDE_MCP_REGISTERED}"

# Atomic cache commit — a concurrent reader must never observe a partial write.
CACHE_TMP="$(mktemp "$CACHE_FILE.XXXXXX")"
printf '%s\n' "$RESULT" > "$CACHE_TMP"
mv -f "$CACHE_TMP" "$CACHE_FILE"
printf '%s\n' "$RESULT"
