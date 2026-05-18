#!/usr/bin/env bash
# cc-bridge: add the codex-cli MCP server to .mcp.json (idempotent merge).
#
# The codex-mcp-server package is pinned to a known version below.
# Bump CC_BRIDGE_CODEX_MCP_VERSION at the top of this script to upgrade.

set -euo pipefail

# Default pinned version of the codex-mcp-server npm package. Bump deliberately.
CC_BRIDGE_CODEX_MCP_VERSION="${CC_BRIDGE_CODEX_MCP_VERSION:-1.4.10}"

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }

if [ -f .mcp.json ]; then
  # Use JSON parsing to check shape and key — avoids false positives from grep.
  # Exit codes: 0 = already registered, 1 = need merge, 2 = invalid shape.
  python3 - "$CC_BRIDGE_CODEX_MCP_VERSION" <<'PY'
import json, sys
from pathlib import Path
try:
    data = json.loads(Path(".mcp.json").read_text())
except json.JSONDecodeError:
    print("! .mcp.json is not valid JSON — leaving alone", file=sys.stderr)
    sys.exit(2)
if not isinstance(data, dict):
    print(f"! .mcp.json top level must be an object (got {type(data).__name__})", file=sys.stderr)
    sys.exit(2)
servers = data.get("mcpServers")
if servers is None:
    sys.exit(1)
if not isinstance(servers, dict):
    print(f"! .mcp.json mcpServers must be an object (got {type(servers).__name__})", file=sys.stderr)
    sys.exit(2)
sys.exit(0 if "codex-cli" in servers else 1)
PY
  _rc=$?
  case "$_rc" in
    0) skip ".mcp.json already registers codex-cli"; exit 0 ;;
    2) exit 2 ;;
  esac
  # Merge cleanly.
  python3 - "$CC_BRIDGE_CODEX_MCP_VERSION" <<'PY'
import json, sys
from pathlib import Path
version = sys.argv[1]
p = Path(".mcp.json")
data = json.loads(p.read_text())
# Re-validate shape (the type-check above already did this, but be defensive
# against TOCTOU between the check and the merge).
if not isinstance(data, dict):
    print("! .mcp.json top level changed between check and merge — leaving alone", file=sys.stderr)
    raise SystemExit(2)
existing = data.get("mcpServers")
if existing is None:
    data["mcpServers"] = {}
elif not isinstance(existing, dict):
    print(f"! .mcp.json mcpServers must be an object, got {type(existing).__name__}", file=sys.stderr)
    raise SystemExit(2)
servers = data["mcpServers"]
servers["codex-cli"] = {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", f"codex-mcp-server@{version}"],
}
p.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"✓ .mcp.json: codex-cli server merged (pinned @{version})")
PY
else
  cat > .mcp.json <<JSON
{
  "mcpServers": {
    "codex-cli": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "codex-mcp-server@${CC_BRIDGE_CODEX_MCP_VERSION}"]
    }
  }
}
JSON
  ok ".mcp.json created with codex-cli server (pinned @${CC_BRIDGE_CODEX_MCP_VERSION})"
fi
