#!/usr/bin/env bash
# cc-suite: add the claude-octopus MCP server to .codex/config.toml (idempotent).
#
# claude-octopus wraps the Anthropic Claude Agent SDK and exposes claude_code /
# claude_code_reply tools so Codex can delegate tasks back to Claude.
# The npm package is pinned to a known version below.
# Bump CC_SUITE_CLAUDE_MCP_VERSION at the top of this script to upgrade.

set -euo pipefail

CC_SUITE_CLAUDE_MCP_VERSION="${CC_SUITE_CLAUDE_MCP_VERSION:-1.0.0}"

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

# ── idempotency check ────────────────────────────────────────────────────────
if [ -f "$TOML" ] && grep -qF "$SENTINEL_OPEN" "$TOML"; then
  skip "$TOML already contains cc-suite claude-code MCP block"
  exit 0
fi

# ── build the TOML block ─────────────────────────────────────────────────────
BLOCK="$(cat <<TOML
${SENTINEL_OPEN}
[mcp_servers.claude-code]
command = "npx"
args    = ["-y", "claude-octopus@${CC_SUITE_CLAUDE_MCP_VERSION}"]
env     = {}
${SENTINEL_CLOSE}
TOML
)"

if [ -f "$TOML" ]; then
  # Append with a blank separator line.
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
