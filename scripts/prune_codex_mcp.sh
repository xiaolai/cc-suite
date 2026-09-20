#!/usr/bin/env bash
# cc-suite: remove the dead `codex-cli` MCP registration from .mcp.json.
#
# cc-suite ≤2.0.1 registered Codex CLI's built-in MCP server (`codex
# mcp-server`) under `mcpServers.codex-cli` so Claude could call Codex as an
# MCP tool. That subcommand no longer exists (gone in codex-cli 0.155.1, where
# `codex mcp` manages *external* servers and has no `serve`); the string is now
# parsed as a TUI prompt, so under an MCP client's piped stdin it exits 1 with
# "stdin is not a terminal". Every session in such a project reports a failed
# MCP connection.
#
# Nothing in cc-suite consumed it: Claude→Codex delegation runs `codex exec`
# through scripts/codex-runner.mjs. So the entry is removed, not replaced.
#
# Idempotent. A `codex-cli` entry cc-suite did not write is left alone and
# reported. An unreadable or unexpected .mcp.json is left alone (exit 2).
# The removal reaches Claude Code on its next session — MCP config is read at
# session start.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The embedded Python block below is a quoted heredoc, so it reads the script
# location from the environment to import scripts/lib modules.
export CC_SUITE_SCRIPT_DIR="$SCRIPT_DIR"

python3 - <<'PY'
import json, os, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(os.environ["CC_SUITE_SCRIPT_DIR"]) / "lib"))
from codex_mcp_entry import (  # noqa: E402
    ABSENT, DEAD, FOREIGN, REASONS, SERVER_NAME, classify_document,
)

p = Path(".mcp.json")

if not p.exists():
    print("· no .mcp.json — no Codex MCP registration to remove")
    sys.exit(0)

try:
    raw = p.read_text(encoding="utf-8")
except OSError as exc:
    print(f"! .mcp.json unreadable ({exc.strerror}) — leaving alone", file=sys.stderr)
    sys.exit(2)
try:
    doc = json.loads(raw)
except json.JSONDecodeError:
    print("! .mcp.json is not valid JSON — leaving alone", file=sys.stderr)
    sys.exit(2)

state = classify_document(doc)
if state is None:
    print("! .mcp.json top level or mcpServers is not an object — leaving alone", file=sys.stderr)
    sys.exit(2)
if state == ABSENT:
    print(f"· .mcp.json has no {SERVER_NAME} entry — nothing to remove")
    sys.exit(0)
if state == FOREIGN:
    print(f"· .mcp.json {SERVER_NAME} entry {REASONS[FOREIGN]}")
    sys.exit(0)

assert state in DEAD
servers = doc["mcpServers"]
del servers[SERVER_NAME]

# Drop a file that existed only to hold that one entry: an empty registry is
# inert, but leaving it behind means every later run has to explain it. Any
# other server, or any other top-level key, keeps the file.
if not servers and set(doc) == {"mcpServers"}:
    p.unlink()
    print(f"✓ .mcp.json removed — it held only the dead {SERVER_NAME} entry ({REASONS[state]})")
    sys.exit(0)

# Atomic replace through a same-directory temp file, carrying the original mode
# over so a 0600 file holding MCP credentials is not widened to the umask
# default.
fd, tmp_name = tempfile.mkstemp(dir=str(p.parent), prefix=f".{p.name}.", suffix=".tmp")
try:
    os.fchmod(fd, p.stat().st_mode & 0o7777)
    with os.fdopen(fd, "w", encoding="utf-8") as tmp_file:
        tmp_file.write(json.dumps(doc, indent=2) + "\n")
    os.replace(tmp_name, p)
except BaseException:
    try:
        os.unlink(tmp_name)
    except OSError:
        pass
    raise

print(f"✓ .mcp.json: removed the dead {SERVER_NAME} entry ({REASONS[state]})")
PY
