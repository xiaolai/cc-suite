---
description: Mirror MCP servers from .mcp.json into .codex/config.toml so Codex CLI sees the same project MCP surface as Claude Code.
allowed-tools:
  - Bash
---

# /cc-suite:bridge-mcp

Copy every MCP server registered in `.mcp.json` (except `codex-cli` itself) into `.codex/config.toml` under `[mcp_servers.*]` entries, so Codex CLI can call the same project MCP tools as Claude Code.

Idempotent. Skips servers already present in `.codex/config.toml`. Wraps server names containing special characters in TOML quoted keys.

## Workflow

### Step 1: Run the bridge script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```

If the script exits non-zero, report the error output and stop. If `.mcp.json` does not exist, report: "No `.mcp.json` found — nothing to mirror." and stop.

### Step 2: Report results

Use this template:

```markdown
**bridge-mcp**: MCP servers mirrored from `.mcp.json` to `.codex/config.toml`

| Server | Action |
|--------|--------|
| {server-name} | mirrored |
| {server-name} | already present (skipped) |
| codex-cli | skipped (Codex cannot call itself) |
```

Success criterion: script exits 0 and every server from `.mcp.json` (except `codex-cli`) appears under `[mcp_servers.*]` in `.codex/config.toml`.
