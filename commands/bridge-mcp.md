---
name: bridge-mcp
description: Mirror MCP servers from .mcp.json into .codex/config.toml so Codex CLI sees the same project MCP surface as Claude Code.
allowed-tools:
  - Bash
---

# /cc-suite:bridge-mcp

Copy every MCP server registered in `.mcp.json` (except `codex-cli` itself) into `.codex/config.toml` under `[mcp_servers.*]` entries, so Codex CLI can call the same project MCP tools as Claude Code.

Idempotent. Skips servers already present in `.codex/config.toml`. Wraps server names containing special characters in TOML quoted keys.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```

Report which servers were mirrored and which were already present. Success criterion: script exits 0 and all servers from `.mcp.json` (except `codex-cli`) appear under `[mcp_servers.*]` in `.codex/config.toml`.

If the script exits non-zero, report the error output and stop. If `.mcp.json` does not exist, report: "No `.mcp.json` found — nothing to mirror." and stop.
