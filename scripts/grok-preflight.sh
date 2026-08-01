#!/usr/bin/env bash
# grok-preflight.sh — fast LOCAL readiness check for Grok Build (xAI).
#
# Unlike codex-preflight.sh / agy-preflight.sh, this performs NO network
# round-trip. Its job is to fail fast on the two things that would otherwise
# make /cc-suite:grok hang until the job deadline: grok not installed, or grok
# not logged in. Both are detectable locally (binary on PATH; XAI_API_KEY env or
# a non-empty ~/.grok/auth.json), so a preflight here is a cheap pre-check rather
# than a full connectivity probe — which also respects the "no availability
# ping" philosophy the delegation runners follow.
#
# Model discovery is read from ~/.grok/models_cache.json (populated by grok
# itself). Grok keeps model and effort as separate flags, so reasoning_efforts
# is a fixed enum, not something that needs discovery.
#
# Output: a single JSON line whose keys mirror codex-preflight.sh:
#   {"backend":"grok","preflight_schema":1,"status":"ok",
#    "grok_version":"...","auth_mode":"api_key|session",
#    "default_model":"grok-4.5","models":[...],"models_detail":[...],
#    "reasoning_efforts":[...],"sandbox_levels":[...]}
# On failure: status="error" with error_code + an actionable error message.

set -euo pipefail

PREFLIGHT_SCHEMA=1
SANDBOX_LEVELS='["read-only","workspace-write","danger-full-access"]'
REASONING_EFFORTS='["none","minimal","low","medium","high","xhigh","max"]'
GROK_DIR="${GROK_HOME:-$HOME/.grok}"
MODELS_CACHE="$GROK_DIR/models_cache.json"
AUTH_FILE="$GROK_DIR/auth.json"

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

emit_error() { # error_code, message, [version-or-null]
  printf '{"backend":"grok","preflight_schema":%s,"status":"error","error_code":"%s","error":"%s","grok_version":%s,"auth_mode":"none","default_model":null,"models":[],"models_detail":[],"reasoning_efforts":%s,"sandbox_levels":%s}\n' \
    "$PREFLIGHT_SCHEMA" "$1" "$(json_str "$2")" "${3:-null}" "$REASONING_EFFORTS" "$SANDBOX_LEVELS"
}

# 1. binary present?
if ! command -v grok >/dev/null 2>&1; then
  emit_error "grok_not_found" "grok not found on PATH. Install Grok Build: curl -fsSL https://x.ai/cli/install.sh | bash"
  exit 0
fi
GROK_VERSION="$(grok --version 2>/dev/null | head -1 || echo unknown)"
GROK_VERSION_JSON="\"$(json_str "$GROK_VERSION")\""

# 2. authenticated? (local check only)
AUTH_MODE="none"
if [ -n "${XAI_API_KEY:-}" ]; then
  AUTH_MODE="api_key"
elif [ -s "$AUTH_FILE" ]; then
  # A real grok session file is a JSON object holding credential fields (a
  # session entry carries e.g. `key` and `refresh_token`, possibly nested under
  # a per-issuer key). Malformed JSON, an empty object, or unrelated content
  # must not pass as an authenticated session. Still a local check, no network.
  if python3 - "$AUTH_FILE" <<'PY' 2>/dev/null; then
import json, re, sys

try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)

CRED_KEY = re.compile(r"key|token|session|credential", re.I)


def has_credential(obj, depth=0):
    """A non-empty string under a credential-named key, up to two levels deep."""
    if not isinstance(obj, dict) or depth > 2:
        return False
    for k, v in obj.items():
        if isinstance(k, str) and CRED_KEY.search(k) and isinstance(v, str) and v.strip():
            return True
        if has_credential(v, depth + 1):
            return True
    return False


sys.exit(0 if isinstance(data, dict) and has_credential(data) else 1)
PY
    AUTH_MODE="session"
  else
    emit_error "credentials_unreadable" "auth.json exists but is not a JSON object with credential fields — corrupt or foreign credentials. Run: grok login" "$GROK_VERSION_JSON"
    exit 0
  fi
fi
if [ "$AUTH_MODE" = "none" ]; then
  emit_error "not_authenticated" "Not authenticated. Run: grok login" "$GROK_VERSION_JSON"
  exit 0
fi

# 3. success — build the ok payload, reading models from the local cache.
GROK_VERSION="$GROK_VERSION" AUTH_MODE="$AUTH_MODE" \
REASONING_EFFORTS="$REASONING_EFFORTS" SANDBOX_LEVELS="$SANDBOX_LEVELS" \
python3 - "$MODELS_CACHE" "$PREFLIGHT_SCHEMA" <<'PY'
import json, os, sys

cache_path, schema = sys.argv[1], int(sys.argv[2])
version = os.environ.get("GROK_VERSION", "unknown")
auth_mode = os.environ.get("AUTH_MODE", "none")
reasoning = json.loads(os.environ["REASONING_EFFORTS"])
sandboxes = json.loads(os.environ["SANDBOX_LEVELS"])

models_map, default = {}, None
try:
    data = json.load(open(cache_path))
    m = data.get("models")
    if isinstance(m, dict):
        models_map = m
    default = data.get("default_model")
except Exception:
    pass

ids = list(models_map.keys())
if not default and ids:
    default = ids[0]  # grok lists a single default model (e.g. grok-4.5)

detail = []
for i, (slug, cfg) in enumerate(models_map.items()):
    info = cfg.get("info", {}) if isinstance(cfg, dict) else {}
    detail.append({
        "slug": slug,
        "display_name": info.get("name") or slug,
        "description": info.get("description") or "",
        "priority": i,
    })

print(json.dumps({
    "backend": "grok",
    "preflight_schema": schema,
    "status": "ok",
    "grok_version": version,
    "auth_mode": auth_mode,
    "default_model": default,
    "models": ids,
    "models_detail": detail,
    "reasoning_efforts": reasoning,
    "sandbox_levels": sandboxes,
}))
PY
