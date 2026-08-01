#!/usr/bin/env bash
# cc-suite: register the codex-cli MCP server in .mcp.json (idempotent merge).
#
# The codex-cli MCP server is the Codex CLI's own built-in MCP server, started
# with `codex mcp-server`. It requires the `codex` binary on PATH (listed as a
# prerequisite in AGENTS.md). No npm package is installed.
#
# Idempotent: a missing entry is added, a stale entry (e.g. an older npm-based
# registration) is migrated to the canonical definition, and an already-correct
# entry is left untouched.

set -euo pipefail

if [ -f .mcp.json ]; then
  # One pass: validate shape, then skip / migrate / merge as needed.
  # Exit 2 = invalid shape (leave the file alone); exit 0 = success.
  python3 - <<'PY'
import json, os, sys
from pathlib import Path

CANONICAL = {"type": "stdio", "command": "codex", "args": ["mcp-server"]}
p = Path(".mcp.json")

try:
    data = json.loads(p.read_text())
except json.JSONDecodeError:
    print("! .mcp.json is not valid JSON — leaving alone", file=sys.stderr)
    sys.exit(2)
if not isinstance(data, dict):
    print(f"! .mcp.json top level must be an object (got {type(data).__name__})", file=sys.stderr)
    sys.exit(2)

servers = data.get("mcpServers")
if servers is None:
    data["mcpServers"] = servers = {}
elif not isinstance(servers, dict):
    print(f"! .mcp.json mcpServers must be an object (got {type(servers).__name__})", file=sys.stderr)
    sys.exit(2)

if servers.get("codex-cli") == CANONICAL:
    print("· .mcp.json already registers codex-cli (codex mcp-server)")
    sys.exit(0)

verb = "updated" if "codex-cli" in servers else "merged"
servers["codex-cli"] = CANONICAL
# Same-directory temp + atomic rename: an interrupted write must never leave
# a truncated .mcp.json behind.
tmp = p.with_name(p.name + ".cc-suite-tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
os.replace(tmp, p)
print(f"✓ .mcp.json: codex-cli server {verb} (codex mcp-server)")
PY
else
  # Write to a temp file, then hard-link it into place: ln fails if .mcp.json
  # appeared since the check above, so a concurrent creation is never
  # clobbered, and the destination is complete or absent — never partial.
  tmp=".mcp.json.cc-suite-tmp.$$"
  trap 'rm -f "$tmp"' EXIT
  cat > "$tmp" <<'JSON'
{
  "mcpServers": {
    "codex-cli": {
      "type": "stdio",
      "command": "codex",
      "args": ["mcp-server"]
    }
  }
}
JSON
  if ln "$tmp" .mcp.json 2>/dev/null; then
    rm -f "$tmp"
    printf '✓ %s\n' ".mcp.json created with codex-cli server (codex mcp-server)"
  else
    rm -f "$tmp"
    printf '! %s\n' ".mcp.json appeared while creating it — re-run to merge the codex-cli entry" >&2
    exit 1
  fi
fi
