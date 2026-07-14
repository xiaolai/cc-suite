#!/usr/bin/env bash
# cc-suite: mirror .mcp.json MCP servers into Codex and Antigravity configs.
#
# Codex reads MCP configuration from .codex/config.toml, not .mcp.json. Agy
# reads workspace MCP configuration from .agents/mcp_config.json. The Codex
# portion is sentinel-guarded; the agy portion has a companion provenance file.
#
# Idempotent: re-running rewrites only the sentinel block; entries declared
# outside it (manually added to config.toml) are never touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if python3 - <<'PY'
from __future__ import annotations
import json, re, sys
from pathlib import Path

SENTINEL_START = "# >>> cc-suite-mcp >>>"
SENTINEL_END   = "# <<< cc-suite-mcp <<<"
# codex-cli is registered in .mcp.json so Claude can invoke Codex as a tool.
# It must not be mirrored back into Codex's own config.
SKIP_SERVERS = {"codex-cli"}


def main() -> int:
    mcp_path = Path(".mcp.json")
    if not mcp_path.exists():
        print("· .mcp.json does not exist — clearing cc-suite-owned projections")
        mcp = {}
    else:
        try:
            mcp = json.loads(mcp_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            print(f"! .mcp.json is not valid JSON: {e}", file=sys.stderr)
            return 1

    if not isinstance(mcp, dict):
        print(f"! .mcp.json top level must be an object (got {type(mcp).__name__})", file=sys.stderr)
        return 2
    servers = mcp.get("mcpServers")
    if servers is None:
        print("· .mcp.json has no mcpServers — clearing cc-suite-owned projections")
        servers = {}
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
            f"! .codex/config.toml has only one of the cc-suite sentinel markers "
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
    skipped_names: set[str] = set()
    warned: list[str] = []
    seen_codex_names: dict[str, str] = {}
    normalized: list[str] = []
    for name, cfg in servers.items():
        if not isinstance(cfg, dict):
            print(f"! {name}: server config must be an object, got {type(cfg).__name__} — skipped", file=sys.stderr)
            warned.append(name)
            continue
        if name in SKIP_SERVERS:
            skipped.append(f"{name} (not mirrored to Codex — it is the tool Codex runs as)")
            skipped_names.add(name)
            continue

        codex_name = _codex_name(name)
        previous_name = seen_codex_names.get(codex_name)
        if previous_name is not None and previous_name != name:
            print(
                f"! {name}: Codex name {codex_name!r} collides with {previous_name!r} after normalization — skipped",
                file=sys.stderr,
            )
            warned.append(name)
            continue
        seen_codex_names[codex_name] = name

        if codex_name != name:
            normalized.append(f"{name} → {codex_name}")

        if f"[mcp_servers.{codex_name}]" in base:
            skipped.append(name)
            skipped_names.add(name)
            continue
        block = _toml_block(name, codex_name, cfg)
        if block is None:
            warned.append(name)
            print(f"! {name}: unsupported transport or missing required field — skipped", file=sys.stderr)
            continue
        new_blocks.append(block)

    if skipped:
        print(f"· skipped: {skipped}")
    if normalized:
        print(f"· normalized for Codex: {normalized}")

    if new_blocks:
        sentinel = (
            f"\n{SENTINEL_START}\n"
            + "\n\n".join(new_blocks)
            + f"\n{SENTINEL_END}\n"
        )
        rendered = base.rstrip("\n") + sentinel
    else:
        # Reconcile deletions too: an old cc-suite sentinel block must not keep
        # exposing servers that disappeared from .mcp.json. Leave unrelated
        # user-authored TOML untouched.
        rendered = base.rstrip("\n") + ("\n" if base.strip() else "")
        if existing != rendered and s_start != -1:
            print("✓ .codex/config.toml: removed stale cc-suite MCP entries")

    if existing != rendered or new_blocks:
        config_path.write_text(rendered, encoding="utf-8")

    if not new_blocks:
        if not warned:
            print("· no new servers to add")
        return 1 if warned else 0

    added = [n for n in servers if n not in SKIP_SERVERS
             and n not in skipped_names
             and n not in warned]
    print(f"✓ .codex/config.toml: added {len(added)} server(s): {added}")
    return 1 if warned else 0


def _codex_name(name: str) -> str:
    """Map a Claude MCP name to Codex's stricter server-name grammar."""
    if re.fullmatch(r'[a-zA-Z0-9_-]+', name):
        return name
    normalized = re.sub(r'[^a-zA-Z0-9_-]+', '-', name).strip('-_')
    return normalized or 'mcp-server'


def _toml_block(name: str, codex_name: str, cfg: dict) -> str | None:
    transport = cfg.get("type", "stdio")
    lines: list[str] = [f"[mcp_servers.{codex_name}]"]
    if name != codex_name:
        comment_name = name.replace('\\', '\\\\').replace('\r', '\\r').replace('\n', '\\n')
        lines.append(f"# Claude MCP name: {comment_name}")

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
            lines.append(f"# env vars required — add [mcp_servers.{codex_name}.env] manually:")
            for k in env_var_names:
                lines.append(f"# {k} = \"<value>\"")
            print(
                f"⚠ {name}: env vars {env_var_names} not mirrored (values not safe to commit).\n"
                f"  Add to .codex/config.toml manually:\n"
                f"  [mcp_servers.{codex_name}.env]\n"
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
then
  CODEX_RC=0
else
  CODEX_RC=$?
fi

# Keep the same project MCP surface available to Antigravity. This also adds
# the cc-suite-managed claude-code server so agy can delegate back to Claude.
if python3 "$SCRIPT_DIR/bridge_agy_mcp.py";
then
  AGY_RC=0
else
  AGY_RC=$?
fi

if [ "$CODEX_RC" -ne 0 ]; then
  exit "$CODEX_RC"
fi
exit "$AGY_RC"
