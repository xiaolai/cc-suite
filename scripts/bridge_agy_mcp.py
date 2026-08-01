#!/usr/bin/env python3
"""Mirror Claude MCP servers into Antigravity's workspace config.

Antigravity reads workspace MCP servers from .agents/mcp_config.json. The
file is generated and ignored by cc-suite because an MCP config can contain
credentials. A small provenance file lets us refresh only entries that
cc-suite owns while preserving user-managed entries in the same file.
"""

from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
from pathlib import Path


SCHEMA = 1
ROOT = Path.cwd()
SOURCE = ROOT / ".mcp.json"
AGENTS_DIR = ROOT / ".agents"
TARGET = AGENTS_DIR / "mcp_config.json"
PROVENANCE = AGENTS_DIR / ".cc-suite-mcp.provenance.json"
PIN_FILE = Path(__file__).resolve().parent / "lib" / "claude-octopus-pin.txt"


def report(message: str, *, error: bool = False) -> None:
    print(("! " if error else "· ") + message, file=sys.stderr if error else sys.stdout)


def load_json(path: Path) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as exc:
        report(f"{path}: invalid JSON: {exc}", error=True)
        raise SystemExit(2)


def atomic_write_json(path: Path, payload: object) -> None:
    """Same-directory tempfile + os.replace, so a crash or a concurrent reader
    never sees partial JSON."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, indent=2) + "\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def translate_server(name: str, config: object) -> dict | None:
    if not isinstance(config, dict):
        report(f"{name}: server config must be an object — skipped", error=True)
        return None

    result = copy.deepcopy(config)
    transport = result.get("type", "stdio")
    if transport == "stdio":
        if not result.get("command"):
            report(f"{name}: stdio server has no command — skipped", error=True)
            return None
        return result

    if transport in ("sse", "http", "streamable_http"):
        # Antigravity uses serverUrl for remote MCP transports. Accept the
        # Claude/Gemini-era url and httpUrl spellings as migration inputs.
        if not result.get("serverUrl"):
            result["serverUrl"] = result.get("url") or result.get("httpUrl")
        result.pop("url", None)
        result.pop("httpUrl", None)
        if not result.get("serverUrl"):
            report(f"{name}: remote server has no URL/serverUrl — skipped", error=True)
            return None
        return result

    report(f"{name}: unsupported transport {transport!r} — skipped", error=True)
    return None


def claude_code_server() -> dict:
    try:
        pin = "".join(PIN_FILE.read_text(encoding="utf-8").split())
    except FileNotFoundError:
        report(f"missing claude-octopus pin file: {PIN_FILE}", error=True)
        raise SystemExit(2)
    if not pin:
        report("claude-octopus pin file is empty", error=True)
        raise SystemExit(2)
    return {
        "type": "stdio",
        "command": "npx",
        "args": ["-y", f"claude-octopus@{pin}"],
        "env": {},
    }


def read_source_servers() -> dict[str, object]:
    source = load_json(SOURCE)
    if source is None:
        return {}
    if not isinstance(source, dict):
        report(".mcp.json top level must be an object", error=True)
        raise SystemExit(2)
    servers = source.get("mcpServers", {})
    if not isinstance(servers, dict):
        report(".mcp.json mcpServers must be an object", error=True)
        raise SystemExit(2)
    return servers


def read_provenance() -> set[str] | None:
    data = load_json(PROVENANCE)
    if data is None:
        return None
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        report(f"{PROVENANCE}: unsupported provenance schema — refusing to overwrite", error=True)
        raise SystemExit(2)
    names = data.get("managed_servers")
    if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
        report(f"{PROVENANCE}: managed_servers is invalid — refusing to overwrite", error=True)
        raise SystemExit(2)
    return set(names)


def main() -> int:
    source_servers = read_source_servers()
    desired: dict[str, dict] = {}
    warned = False

    for name, config in source_servers.items():
        translated = translate_server(name, config)
        if translated is not None:
            desired[name] = translated
        else:
            warned = True

    # mcp_claude.sh owns the Codex registration, but agy needs the same
    # claude-octopus server in its workspace MCP profile for agy → Claude.
    desired.setdefault("claude-code", claude_code_server())

    managed = read_provenance()
    if TARGET.exists() and managed is None:
        report(
            f"{TARGET} exists without cc-suite provenance — leaving it alone; "
            "merge the desired servers manually or remove it and rerun",
            error=True,
        )
        return 2

    existing: dict[str, object] = {}
    if TARGET.exists():
        raw_target = load_json(TARGET)
        if not isinstance(raw_target, dict) or not isinstance(raw_target.get("mcpServers", {}), dict):
            report(f"{TARGET}: top-level mcpServers must be an object — leaving it alone", error=True)
            return 2
        existing = raw_target.get("mcpServers", {})

    if managed is None:
        managed = set()

    # Remove only entries from the last cc-suite run. A user-owned server with
    # the same name is preserved and reported as a conflict below.
    remaining = {name: cfg for name, cfg in existing.items() if name not in managed}
    conflicts = sorted(set(desired) & set(remaining))
    if conflicts:
        report(
            "user-managed Antigravity server name conflict(s): "
            + ", ".join(conflicts)
            + " — refusing to overwrite",
            error=True,
        )
        return 2

    merged = {**remaining, **desired}
    AGENTS_DIR.mkdir(parents=True, exist_ok=True)
    # Three-step transactional write, each step atomic, so a crash between any
    # two writes self-heals on the next run in both directions:
    #   1. expand provenance to old ∪ new — every server we have ever written
    #      stays recorded as cc-suite-owned, so a fresh target entry is never
    #      misclassified as a user-owned conflict;
    #   2. write the target;
    #   3. contract provenance to exactly the new set — a name is un-claimed
    #      only after the target write that removed it has really landed, so a
    #      removed managed server is never misclassified as user-owned either.
    # A provenance name absent from the target is inert (nothing to preserve
    # or remove), so a stale expanded set from a crashed run is harmless.
    def prov_payload(names: list[str]) -> dict:
        return {"schema": SCHEMA, "managed_servers": names, "source": ".mcp.json"}

    union = sorted(managed | set(desired))
    final = sorted(desired)
    if union != final:
        atomic_write_json(PROVENANCE, prov_payload(union))
    atomic_write_json(TARGET, {"mcpServers": merged})
    atomic_write_json(PROVENANCE, prov_payload(final))

    print(f"✓ {TARGET}: synchronized {len(desired)} cc-suite server(s)")
    if "claude-code" in desired:
        print("· claude-code: registered for agy → Claude delegation")
    return 1 if warned else 0


if __name__ == "__main__":
    raise SystemExit(main())
