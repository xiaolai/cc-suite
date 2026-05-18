#!/usr/bin/env bash
# cc-bridge: mirror .mcp.json mcpServers → .codex/config.toml [mcp_servers.*].
#
# Codex reads MCP configuration from .codex/config.toml, not .mcp.json.
# This script writes a sentinel-guarded block of [mcp_servers.*] entries so
# Codex can see the same servers that Claude Code uses.
#
# Idempotent: re-running rewrites only the sentinel block; entries declared
# outside it (manually added to config.toml) are never touched.

set -euo pipefail

python3 - <<'PY'
from __future__ import annotations
import json, sys
from pathlib import Path

SENTINEL_START = "# >>> cc-bridge-mcp >>>"
SENTINEL_END   = "# <<< cc-bridge-mcp <<<"


def main() -> int:
    mcp_path = Path(".mcp.json")
    if not mcp_path.exists():
        print("· .mcp.json does not exist — nothing to mirror")
        return 0
    try:
        mcp = json.loads(mcp_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"! .mcp.json is not valid JSON: {e}", file=sys.stderr)
        return 1

    servers = mcp.get("mcpServers") or {}
    if not servers:
        print("· .mcp.json has no mcpServers — nothing to mirror")
        return 0

    Path(".codex").mkdir(exist_ok=True)
    config_path = Path(".codex/config.toml")
    existing = config_path.read_text(encoding="utf-8") if config_path.exists() else ""

    # Strip old sentinel block so it can be rewritten cleanly on re-runs.
    s_start = existing.find(SENTINEL_START)
    s_end   = existing.find(SENTINEL_END)
    if s_start != -1 and s_end != -1:
        tail = existing.find("\n", s_end)
        base = existing[:s_start].rstrip("\n") + (
            "\n" + existing[tail + 1:] if tail != -1 else ""
        )
    else:
        base = existing

    # Only add servers not already declared in the non-sentinel portion.
    new_blocks: list[str] = []
    skipped: list[str] = []
    warned: list[str] = []
    for name, cfg in servers.items():
        if f"[mcp_servers.{name}]" in base:
            skipped.append(name)
            continue
        block = _toml_block(name, cfg)
        if block is None:
            warned.append(name)
            print(f"! {name}: unsupported transport or missing required field — skipped", file=sys.stderr)
            continue
        new_blocks.append(block)

    if skipped:
        print(f"· already in .codex/config.toml, skipped: {skipped}")

    if not new_blocks:
        if not warned:
            print("· no new servers to add")
        return 1 if warned else 0

    sentinel = (
        f"\n{SENTINEL_START}\n"
        + "\n\n".join(new_blocks)
        + f"\n{SENTINEL_END}\n"
    )
    config_path.write_text(base.rstrip("\n") + sentinel, encoding="utf-8")
    added = [n for n in servers if n not in skipped and n not in warned]
    print(f"✓ .codex/config.toml: added {len(added)} server(s): {added}")
    return 1 if warned else 0


def _toml_block(name: str, cfg: dict) -> str | None:
    transport = cfg.get("type", "stdio")
    lines: list[str] = [f"[mcp_servers.{name}]"]

    if transport == "stdio":
        cmd = cfg.get("command")
        if not cmd:
            return None
        lines.append(f"command = {_qs(cmd)}")
        if args := cfg.get("args"):
            lines.append(f"args = [{', '.join(_qs(a) for a in args)}]")
        env = cfg.get("env") or {}
        if env:
            lines.append(f"\n[mcp_servers.{name}.env]")
            for k, v in env.items():
                lines.append(f"{k} = {_qs(str(v))}")

    elif transport in ("sse", "http", "streamable_http"):
        url = cfg.get("url")
        if not url:
            return None
        lines.append(f"url = {_qs(url)}")
        if tok := cfg.get("bearer_token_env_var"):
            lines.append(f"bearer_token_env_var = {_qs(tok)}")

    else:
        return None

    return "\n".join(lines)


def _qs(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


if __name__ == "__main__":
    raise SystemExit(main())
PY
