#!/usr/bin/env bash
# cc-suite: add (or refresh) the claude-octopus MCP server in .codex/config.toml.
#
# claude-octopus wraps the Anthropic Claude Agent SDK and exposes claude_code /
# claude_code_reply tools so Codex can delegate tasks back to Claude.
#
# The pinned version lives in scripts/lib/claude-octopus-pin.txt — single source
# of truth, also read by the boot-handshake test and the integration suite.
# Override at runtime with CC_SUITE_CLAUDE_MCP_VERSION=<version> for testing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_FILE="${SCRIPT_DIR}/lib/claude-octopus-pin.txt"

if [ -z "${CC_SUITE_CLAUDE_MCP_VERSION:-}" ]; then
  if [ ! -f "$PIN_FILE" ]; then
    printf '! pin file missing: %s\n' "$PIN_FILE" >&2
    exit 1
  fi
  CC_SUITE_CLAUDE_MCP_VERSION="$(tr -d '[:space:]' < "$PIN_FILE")"
fi

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }
die()  { printf '! %s\n' "$*" >&2; exit 1; }

# Ensure .codex/ exists — mcp_codex.sh / init.sh should have run first, but
# guard defensively so this script can also be called standalone.
if [ ! -d .codex ]; then
  mkdir -p .codex
fi

TOML=".codex/config.toml"

# Sentinel used inside config.toml to guard the claude-code block.
SENTINEL_OPEN="# >>> cc-suite-claude-mcp >>>"
SENTINEL_CLOSE="# <<< cc-suite-claude-mcp <<<"
PIN_MARKER="claude-octopus@${CC_SUITE_CLAUDE_MCP_VERSION}"

# ── build the canonical TOML block ───────────────────────────────────────────
BLOCK="$(cat <<TOML
${SENTINEL_OPEN}
[mcp_servers.claude-code]
command = "npx"
args    = ["-y", "${PIN_MARKER}"]
env     = {}
# Codex default tool_timeout_sec is too short for claude_code calls: a
# single multi-turn agent invocation can run several minutes, so 900s
# matches the forward-direction codex-runner deadline. startup_timeout_sec
# covers cold-cache npx -y downloads on first launch.
startup_timeout_sec = 60
tool_timeout_sec    = 900
${SENTINEL_CLOSE}
TOML
)"

# ── idempotency / freshen check ──────────────────────────────────────────────
# Four cases:
#   1. Sentinel block found AND body contains current pin       → skip (no-op)
#   2. Sentinel block found AND body has different/older pin   → rewrite
#   3. Sentinel absent  AND user-managed [mcp_servers.claude-code] present
#                                                              → skip with warning
#   4. Sentinel absent  AND no claude-code block at all         → append
if [ -f "$TOML" ]; then
  if grep -qF "$SENTINEL_OPEN" "$TOML"; then
    # Extract the sentinel block and check whether it already pins the current
    # version. Doing this with awk keeps macOS/Linux behavior identical.
    current_block="$(awk -v sopen="$SENTINEL_OPEN" -v sclose="$SENTINEL_CLOSE" '
      $0 == sopen  { capture=1 }
      capture      { print }
      $0 == sclose { capture=0 }
    ' "$TOML")"

    # The block is considered up-to-date only if it pins the current
    # claude-octopus version AND carries the tool_timeout_sec field added in
    # cc-suite 0.7.2. Without the timeout check, configs pinned at the right
    # version but written by a pre-0.7.2 cc-suite would never refresh, and
    # `claude_code` tool calls would keep hitting Codex's default 120s ceiling.
    if printf '%s' "$current_block" | grep -qF "$PIN_MARKER" \
       && printf '%s' "$current_block" | grep -q "tool_timeout_sec"; then
      skip "$TOML already pins ${PIN_MARKER}"
      exit 0
    fi

    # Pin moved (or block is malformed) — rewrite in place.
    tmpfile="$(mktemp)"
    # Delete the sentinel block (inclusive) and one immediately-following
    # blank separator line, if present. Leaves the rest of the file untouched.
    awk -v sopen="$SENTINEL_OPEN" -v sclose="$SENTINEL_CLOSE" '
      $0 == sopen                       { skip=1; next }
      $0 == sclose                      { skip=0; trailing_blank=1; next }
      skip                              { next }
      trailing_blank && /^[[:space:]]*$/ { trailing_blank=0; next }
      { trailing_blank=0; print }
    ' "$TOML" > "$tmpfile"

    {
      cat "$tmpfile"
      [ -s "$tmpfile" ] && printf '\n'
      printf '%s\n' "$BLOCK"
    } > "$TOML"
    rm -f "$tmpfile"
    ok "$TOML: claude-code MCP server refreshed (now pinned @${CC_SUITE_CLAUDE_MCP_VERSION})"
    exit 0
  fi

  # No sentinel — but does a user-managed [mcp_servers.claude-code] table exist?
  # Match both bare and quoted-key forms with optional leading whitespace.
  if grep -qE '^[[:space:]]*\[mcp_servers\.(claude-code|"claude-code")\][[:space:]]*$' "$TOML"; then
    skip "$TOML already registers [mcp_servers.claude-code] (not cc-suite-managed) — leaving it alone"
    skip "  to let cc-suite manage it, remove the existing block and re-run /cc-suite:repair"
    exit 0
  fi
fi

# ── append a fresh block ─────────────────────────────────────────────────────
if [ -f "$TOML" ]; then
  {
    printf '\n'
    printf '%s\n' "$BLOCK"
  } >> "$TOML"
  ok "$TOML: claude-code MCP server appended (pinned @${CC_SUITE_CLAUDE_MCP_VERSION})"
else
  cat > "$TOML" <<TOML
${BLOCK}
TOML
  ok "$TOML created with claude-code MCP server (pinned @${CC_SUITE_CLAUDE_MCP_VERSION})"
fi
