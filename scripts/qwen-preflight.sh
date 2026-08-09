#!/usr/bin/env bash
# qwen-preflight.sh — fast, local readiness check for the bounded Qwen review
# runner. It does not send a model prompt or inspect credentials.

set -uo pipefail

PREFLIGHT_SCHEMA=1
MIN_VERSION="0.21.0"
SANDBOX_LEVELS='["read-only"]'
REASONING_EFFORTS='[]'
PROBE_TIMEOUT_SECONDS=5   # every local probe is bounded — this preflight is the "fast" one

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  # JSON forbids raw bytes below 0x20 — drop any remaining control characters
  # (\n, \t, \r are already handled above).
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
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
  # this preflight. `set -m` makes it a process-group leader, so the deadline
  # signals its descendants too; only stdout is captured, as with `timeout`.
  local output pid waited=0 rc
  output="$(mktemp "${TMPDIR:-/tmp}/cc-suite-qwen-preflight.XXXXXX")"
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

emit_error() {
  local code="$1" message="$2" version="${3:-null}"
  printf '{"backend":"qwen","preflight_schema":%s,"status":"error","error_code":"%s","error":"%s","qwen_version":%s,"auth_mode":"not_probed","default_model":null,"models":[],"reasoning_efforts":%s,"sandbox_levels":%s}\n' \
    "$PREFLIGHT_SCHEMA" "$code" "$(json_escape "$message")" "$version" "$REASONING_EFFORTS" "$SANDBOX_LEVELS"
}

if ! command -v qwen >/dev/null 2>&1; then
  emit_error "qwen_not_found" "qwen not found on PATH. Install Qwen Code, then retry."
  exit 0
fi

SANDBOX_PROVIDER="${QWEN_SANDBOX:-}"
case "$SANDBOX_PROVIDER" in
  docker|podman|sandbox-exec) ;;
  *)
    if [[ "$(uname -s)" == "Darwin" ]]; then
      SANDBOX_PROVIDER="sandbox-exec"
    elif command -v docker >/dev/null 2>&1; then
      SANDBOX_PROVIDER="docker"
    elif command -v podman >/dev/null 2>&1; then
      SANDBOX_PROVIDER="podman"
    else
      emit_error "qwen_sandbox_unavailable" "No supported Qwen sandbox provider was found. Install Docker or Podman."
      exit 0
    fi
    ;;
esac

if ! command -v "$SANDBOX_PROVIDER" >/dev/null 2>&1; then
  emit_error "qwen_sandbox_unavailable" "Configured Qwen sandbox provider is unavailable: $SANDBOX_PROVIDER"
  exit 0
fi

# For daemon-backed providers, an installed binary is not readiness: a stopped
# daemon would pass preflight and fail at review time. Probe locally, bounded.
provider_ready() {
  run_with_timeout "$PROBE_TIMEOUT_SECONDS" "$1" info >/dev/null 2>&1
}

case "$SANDBOX_PROVIDER" in
  docker|podman)
    if ! provider_ready "$SANDBOX_PROVIDER"; then
      emit_error "qwen_sandbox_unavailable" "Qwen sandbox provider '$SANDBOX_PROVIDER' is installed but not responding — is the daemon running?"
      exit 0
    fi
    ;;
esac

QWEN_VERSION_RAW="$(run_with_timeout "$PROBE_TIMEOUT_SECONDS" qwen --version 2>/dev/null | head -1 | tr -d '\r')"
QWEN_VERSION_RC=$?
if [[ "$QWEN_VERSION_RC" -eq 124 ]]; then
  emit_error "qwen_probe_timeout" "qwen --version did not respond within ${PROBE_TIMEOUT_SECONDS}s — the Qwen Code CLI or its wrapper is hung."
  exit 0
fi
QWEN_VERSION_JSON="\"$(json_escape "${QWEN_VERSION_RAW:-unknown}")\""
QWEN_SEMVER="$(printf '%s' "$QWEN_VERSION_RAW" | sed -nE 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1)"

if [[ -z "$QWEN_SEMVER" ]]; then
  emit_error "qwen_version_unparseable" "Could not parse the Qwen Code version: ${QWEN_VERSION_RAW:-empty}" "$QWEN_VERSION_JSON"
  exit 0
else
  VERSION_OK="$(node -e '
const parts = (value) => value.split(".").map(Number);
const actual = parts(process.argv[1]);
const minimum = parts(process.argv[2]);
const ok = actual.some((part, index) => part > minimum[index] && actual.slice(0, index).every((value, i) => value === minimum[i]))
  || actual.every((part, index) => part === minimum[index]);
process.stdout.write(ok ? "yes" : "no");
' "$QWEN_SEMVER" "$MIN_VERSION")"
  if [[ "$VERSION_OK" != "yes" ]]; then
    emit_error "qwen_version_unsupported" "Qwen Code $QWEN_SEMVER is too old. Upgrade to $MIN_VERSION or newer." "$QWEN_VERSION_JSON"
    exit 0
  fi
fi

printf '{"backend":"qwen","preflight_schema":%s,"status":"ok","qwen_version":%s,"minimum_version":"%s","auth_mode":"not_probed","default_model":null,"models":[],"reasoning_efforts":%s,"sandbox_levels":%s,"sandbox_provider":"%s","capabilities":{"safe_mode":true,"plan_mode":true,"sandbox":true,"stream_json":true,"resume":true,"tool_boundary":true,"tool_budget":true,"zero_tool_budget":true,"isolated_target_copies":true,"exact_target_policy":true}}\n' \
  "$PREFLIGHT_SCHEMA" "$QWEN_VERSION_JSON" "$MIN_VERSION" "$REASONING_EFFORTS" "$SANDBOX_LEVELS" "$(json_escape "$SANDBOX_PROVIDER")"
