#!/usr/bin/env bash
# cc-bridge: add the codex-cli MCP server to .mcp.json (idempotent merge).

set -euo pipefail

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }

if [ -f .mcp.json ]; then
  if grep -q '"codex-cli"' .mcp.json; then
    skip ".mcp.json already lists codex-cli"
    exit 0
  fi
  # Use Python to merge cleanly.
  python3 - <<'PY'
import json
from pathlib import Path

p = Path(".mcp.json")
try:
    data = json.loads(p.read_text())
except json.JSONDecodeError:
    print("! .mcp.json is not valid JSON — leaving alone")
    raise SystemExit(1)
servers = data.setdefault("mcpServers", {})
servers["codex-cli"] = {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "codex-mcp-server"],
}
p.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print("✓ .mcp.json: codex-cli server merged")
PY
else
  cat > .mcp.json <<'JSON'
{
  "mcpServers": {
    "codex-cli": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "codex-mcp-server"]
    }
  }
}
JSON
  ok ".mcp.json created with codex-cli server"
fi
