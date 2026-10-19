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
CONFIG_TOML="$GROK_DIR/config.toml"
AUTH_FILE="$GROK_DIR/auth.json"

# JSON forbids raw bytes below 0x20, and `grok --version` can emit ANSI escapes.
json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }

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
import json, sys

try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)

# Exact field names only. A substring match on key/token/session also accepts
# `monkey`, `keynote`, and `session_name`, so unrelated JSON would pass as an
# authenticated session.
CRED_FIELDS = {
    "key", "api_key", "apikey",
    "token", "access_token", "accesstoken",
    "refresh_token", "refreshtoken",
    "id_token", "idtoken",
    "session_token", "sessiontoken",
    "auth_token", "authtoken",
}
MIN_CREDENTIAL_LENGTH = 8


def is_credential(value):
    """Credentials are opaque single-token strings — never prose, never a flag."""
    if not isinstance(value, str):
        return False
    value = value.strip()
    return len(value) >= MIN_CREDENTIAL_LENGTH and not any(c.isspace() for c in value)


def has_credential(obj, depth=0):
    """A credential-shaped string under an exact credential field name."""
    if not isinstance(obj, dict) or depth > 2:
        return False
    for k, v in obj.items():
        if isinstance(k, str) and k.lower() in CRED_FIELDS and is_credential(v):
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


# 3. success — build the ok payload from the local model cache, merged with any
# models the user declared in config.toml.
#
# models_cache.json is written by grok itself and only ever holds the models the
# *backend* served, so a locally-declared model (a gateway, a bedrock alias, a
# custom endpoint) is absent from it and this preflight used to report a catalog
# that silently omitted it. Grok's own config schema, confirmed against the
# shipped binary, declares those as `[model.<slug>]` tables with the default
# pinned at `[models] default = "..."` — note the singular/plural split, they are
# two different tables. Merging them here keeps the documented no-network
# guarantee: both inputs are files already on disk.
#
# This is deliberately best-effort. Grok layers managed settings, requirements
# .toml and remote config over the user's file, so reading config.toml alone
# cannot reproduce the resolved catalog exactly; it can only *add* models the
# user wrote down, which is strictly better than omitting them. The cache stays
# the source of display metadata where it has any.
GROK_VERSION="$GROK_VERSION" AUTH_MODE="$AUTH_MODE" \
REASONING_EFFORTS="$REASONING_EFFORTS" SANDBOX_LEVELS="$SANDBOX_LEVELS" \
python3 - "$MODELS_CACHE" "$PREFLIGHT_SCHEMA" "$CONFIG_TOML" <<'PY'
import json, os, re, sys

cache_path, schema = sys.argv[1], int(sys.argv[2])
config_path = sys.argv[3] if len(sys.argv) > 3 else ""
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


# --- minimal TOML header scan -------------------------------------------------
# Python 3.9 is this repo's floor and tomllib arrives in 3.11, so a full parse is
# not available. Only two things are needed, and both are header-level, so a
# scanner that understands table headers, dotted keys and multi-line strings is
# enough -- and it cannot fail the preflight the way a strict parser would on a
# config file that grok itself accepts.
_BARE = r"[A-Za-z0-9_-]+"
_QUOTED = r'"(?:[^"\\]|\\.)*"' + "|" + r"'[^']*'"
_SEGMENT = re.compile(r"\s*(%s|%s)\s*" % (_QUOTED, _BARE))
_HEADER = re.compile(r"^\s*\[([^\[\]]+)\]\s*(?:#.*)?$")
# `default = "x"`, bare or quoted key, single- or double-quoted value.
_DEFAULT = re.compile(
    r"""^\s*(?:default|"default"|'default')\s*=\s*(?:"((?:[^"\\]|\\.)*)"|'([^']*)')\s*(?:#.*)?$"""
)


def _unquote(segment):
    segment = segment.strip()
    if len(segment) >= 2 and segment[0] == segment[-1] and segment[0] in "\"'":
        inner = segment[1:-1]
        # Only basic strings process escapes; literal strings are verbatim.
        if segment[0] == '"':
            try:
                return json.loads('"%s"' % inner)
            except Exception:
                return inner
        return inner
    return segment


def _split_path(raw):
    """Split a dotted TOML key path, honoring quoted segments containing dots."""
    parts, pos = [], 0
    while pos < len(raw):
        match = _SEGMENT.match(raw, pos)
        if not match:
            return None
        parts.append(_unquote(match.group(1)))
        pos = match.end()
        if pos < len(raw):
            if raw[pos] != ".":
                return None
            pos += 1
    return parts or None


def scan_config(path):
    """Return (locally declared model slugs in file order, pinned default)."""
    slugs, pinned, section = [], None, None
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except Exception:
        return slugs, pinned

    # A table header is only a header at the top level of the file. Inside a
    # multi-line string a line like [model.x] is just text, so track the
    # delimiters and skip those lines rather than inventing a phantom model.
    in_multiline = None
    for line in text.splitlines():
        if in_multiline:
            if in_multiline in line:
                in_multiline = None
            continue
        for delim in ('"""', "'''"):
            # Opens and stays open only when the delimiter count is odd.
            if line.count(delim) % 2 == 1:
                in_multiline = delim
                break
        if in_multiline:
            continue

        header = _HEADER.match(line)
        if header:
            # `[[x]]` array-of-tables never matches: the inner class excludes brackets.
            section = _split_path(header.group(1))
            # `[model.<slug>]` only. `[model_providers.<name>]` is a different
            # table that names a provider, not a model, and must not leak in --
            # the exact-segment compare is what keeps it out.
            if section and len(section) >= 2 and section[0] == "model":
                slug = section[1]
                if slug and slug not in slugs:
                    slugs.append(slug)
            continue

        # `[models] default = "..."` is the pinned model for new sessions.
        if section == ["models"]:
            pinned_match = _DEFAULT.match(line)
            if pinned_match:
                pinned = pinned_match.group(1)
                if pinned is None:
                    pinned = pinned_match.group(2)

    return slugs, pinned


config_slugs, config_default = ([], None)
if config_path:
    config_slugs, config_default = scan_config(config_path)

ids = list(models_map.keys())
# Config-declared models the cache never saw. Appended rather than merged in
# place so the backend's own ordering (which encodes priority) survives.
extra = [slug for slug in config_slugs if slug not in models_map]
ids.extend(extra)

# A pinned default is the user's explicit choice, so it outranks the cached one.
# Only honor it if the model actually exists in the merged catalog -- a stale pin
# naming a removed model would otherwise be reported as the default.
if config_default and config_default in ids:
    default = config_default
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
        "source": "cache",
    })
for j, slug in enumerate(extra):
    # The config table carries no display metadata the cache format exposes, so
    # the slug is all there is to show.
    detail.append({
        "slug": slug,
        "display_name": slug,
        "description": "Declared locally in config.toml",
        "priority": len(models_map) + j,
        "source": "config",
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
