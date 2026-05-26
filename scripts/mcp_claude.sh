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
# Two-stage check: (1) cc-suite's own sentinel block already present, or
# (2) some other tool — or the user — already registered a [mcp_servers.claude-code]
# table. In the second case we must NOT append a duplicate, since TOML treats
# two tables with the same key as a parse error and Codex will refuse to start.
if [ -f "$TOML" ]; then
  if grep -qF "$SENTINEL_OPEN" "$TOML"; then
    skip "$TOML already contains cc-suite claude-code MCP block"
    exit 0
  fi
  # Match both `[mcp_servers.claude-code]` and `[mcp_servers."claude-code"]`,
  # allowing leading whitespace. A pre-existing entry takes precedence —
  # cc-suite refuses to clobber user-managed config.
  if grep -qE '^[[:space:]]*\[mcp_servers\.(claude-code|"claude-code")\][[:space:]]*$' "$TOML"; then
    skip "$TOML already registers [mcp_servers.claude-code] (not cc-suite-managed) — leaving it alone"
    skip "  to let cc-suite manage it, remove the existing block and re-run /cc-suite:repair"
    exit 0
  fi
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
