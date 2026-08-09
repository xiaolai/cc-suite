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

# Creation and merge share one implementation and one CANONICAL object: a
# second spelling of the server definition is how the two paths drift apart.
# Exit 2 = invalid shape, file left alone. Exit 1 = another process created
# .mcp.json mid-run.
python3 - <<'PY'
import json, os, sys, tempfile
from pathlib import Path

CANONICAL = {"type": "stdio", "command": "codex", "args": ["mcp-server"]}
p = Path(".mcp.json")


def commit(data, create):
    """Publish `data` as .mcp.json through a same-directory temp file.

    Exclusive-create (link) for a new file so a concurrent creator is never
    clobbered; atomic replace for an existing one, carrying its mode over so a
    0600 file holding MCP credentials is not widened to the umask default.
    Raises FileExistsError when `create` loses the race.
    """
    fd, tmp_name = tempfile.mkstemp(dir=str(p.parent), prefix=f".{p.name}.", suffix=".tmp")
    try:
        if create:
            mask = os.umask(0)
            os.umask(mask)
            os.fchmod(fd, 0o666 & ~mask)
        else:
            os.fchmod(fd, p.stat().st_mode & 0o7777)
        with os.fdopen(fd, "w", encoding="utf-8") as tmp_file:
            tmp_file.write(json.dumps(data, indent=2) + "\n")
        if create:
            os.link(tmp_name, p)
        else:
            os.replace(tmp_name, p)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    if create:
        os.unlink(tmp_name)


if not p.exists():
    try:
        commit({"mcpServers": {"codex-cli": CANONICAL}}, create=True)
    except FileExistsError:
        print("! .mcp.json appeared while creating it — re-run to merge the codex-cli entry", file=sys.stderr)
        sys.exit(1)
    print("✓ .mcp.json created with codex-cli server (codex mcp-server)")
    sys.exit(0)

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
commit(data, create=False)
print(f"✓ .mcp.json: codex-cli server {verb} (codex mcp-server)")
PY
