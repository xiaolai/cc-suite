#!/usr/bin/env bash
# cc-bridge: add the codex-cli MCP server to .mcp.json (idempotent merge).
#
# Security note: the npx command below uses an unpinned package version.
# To pin to a specific version, change "codex-mcp-server" to
# "codex-mcp-server@<version>" in the args array after running this script.

set -euo pipefail

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }

if [ -f .mcp.json ]; then
  # Use JSON parsing to check for the key — avoids false positives from grep.
  if python3 -c '
import json, sys
from pathlib import Path
data = json.loads(Path(".mcp.json").read_text())
sys.exit(0 if "codex-cli" in data.get("mcpServers", {}) else 1)
' 2>/dev/null; then
    skip ".mcp.json already registers codex-cli"
    exit 0
  fi
  # Merge cleanly with Python.
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
