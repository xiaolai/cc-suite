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
import json, re, sys
from pathlib import Path

SENTINEL_START = "# >>> cc-bridge-mcp >>>"
SENTINEL_END   = "# <<< cc-bridge-mcp <<<"
# codex-cli is registered in .mcp.json so Claude can invoke Codex as a tool.
# It must not be mirrored back into Codex's own config.
SKIP_SERVERS = {"codex-cli"}


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

    if not isinstance(mcp, dict):
        print(f"! .mcp.json top level must be an object (got {type(mcp).__name__})", file=sys.stderr)
        return 2
    servers = mcp.get("mcpServers")
    if servers is None or servers == {}:
        print("· .mcp.json has no mcpServers — nothing to mirror")
        return 0
    if not isinstance(servers, dict):
        print(f"! .mcp.json mcpServers must be an object (got {type(servers).__name__})", file=sys.stderr)
        return 2

    Path(".codex").mkdir(exist_ok=True)
    config_path = Path(".codex/config.toml")
    existing = config_path.read_text(encoding="utf-8") if config_path.exists() else ""

    # Strip old sentinel block so it can be rewritten cleanly on re-runs.
    s_start = existing.find(SENTINEL_START)
    s_end   = existing.find(SENTINEL_END)
    # A lone (partial) sentinel marker indicates manual editing / a botched
    # previous run; refuse to silently append a new block on top of it.
    if (s_start == -1) != (s_end == -1):
        print(
            f"! .codex/config.toml has only one of the cc-bridge sentinel markers "
            f"({'start' if s_start != -1 else 'end'} present). "
            "Manually repair before rerunning.",
            file=sys.stderr,
        )
        return 2
    if s_start != -1 and s_end != -1:
        nl = existing.find("\n", s_end)
        base = existing[:s_start].rstrip("\n") + (
            "\n" + existing[nl + 1:] if nl != -1 else ""
        )
    else:
        base = existing

    # Only add servers not already declared in the non-sentinel portion.
    new_blocks: list[str] = []
    skipped: list[str] = []
    warned: list[str] = []
    for name, cfg in servers.items():
        if not isinstance(cfg, dict):
            print(f"! {name}: server config must be an object, got {type(cfg).__name__} — skipped", file=sys.stderr)
            warned.append(name)
            continue
        if name in SKIP_SERVERS:
            skipped.append(f"{name} (not mirrored to Codex — it is the tool Codex runs as)")
            continue
        if f"[mcp_servers.{_toml_key(name)}]" in base:
            skipped.append(name)
            continue
        block = _toml_block(name, cfg)
        if block is None:
            warned.append(name)
            print(f"! {name}: unsupported transport or missing required field — skipped", file=sys.stderr)
            continue
        new_blocks.append(block)

    if skipped:
        print(f"· skipped: {skipped}")

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
    added = [n for n in servers if n not in SKIP_SERVERS
             and n not in [s.split(" ")[0] for s in skipped]
             and n not in warned]
    print(f"✓ .codex/config.toml: added {len(added)} server(s): {added}")
    return 1 if warned else 0


def _toml_key(name: str) -> str:
    """Return a valid TOML key — bare if safe, quoted otherwise."""
    if re.match(r'^[a-zA-Z0-9_-]+$', name):
        return name
    return '"' + name.replace('\\', '\\\\').replace('"', '\\"') + '"'


def _toml_block(name: str, cfg: dict) -> str | None:
    transport = cfg.get("type", "stdio")
    key = _toml_key(name)
    lines: list[str] = [f"[mcp_servers.{key}]"]

    if transport == "stdio":
        cmd = cfg.get("command")
        if not cmd:
            return None
        lines.append(f"command = {_qs(cmd)}")
        if args := cfg.get("args"):
            lines.append(f"args = [{', '.join(_qs(a) for a in args)}]")
        env = cfg.get("env") or {}
        if env:
            # Env values are not mirrored — embedding secrets in config.toml risks
            # committing them. Document the required vars as TOML comments instead.
            env_var_names = sorted(env.keys())
            lines.append(f"# env vars required — add [mcp_servers.{key}.env] manually:")
            for k in env_var_names:
                lines.append(f"# {k} = \"<value>\"")
            print(
                f"⚠ {name}: env vars {env_var_names} not mirrored (values not safe to commit).\n"
                f"  Add to .codex/config.toml manually:\n"
                f"  [mcp_servers.{key}.env]\n"
                + "\n".join(f"  {k} = \"<value>\"" for k in env_var_names)
            )

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
