---
name: sync-mcp
description: Synchronize Claude Code project MCP servers into Codex and Antigravity workspace configs.
allowed-tools:
  - Bash
---

# /cc-suite:sync-mcp

Synchronize the project MCP servers Claude Code reads from `.mcp.json` into
Codex's `.codex/config.toml` and Antigravity's `.agents/mcp_config.json`.

This is the explicit Claude → Codex/agy MCP sync command. It is equivalent to
`/cc-suite:bridge-mcp`; keep both names available because `bridge-mcp` is the
historical command name.

## Workflow

### Step 1: Run the sync script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```

The script skips `codex-cli` only in Codex's own config; agy may use it to call
Codex. It also adds the pinned `claude-code` server to agy's projection so agy
can call Claude. It normalizes Claude server names only in the Codex projection to
Codex's `^[a-zA-Z0-9_-]+$` grammar and
converts remote `url`/`httpUrl` fields to agy's `serverUrl`. Secret values are
never copied into `.codex/config.toml`; the generated agy config is ignored by
default because MCP definitions can preserve environment values and local paths.

If `.agents/mcp_config.json` exists without cc-suite provenance, the bridge
refuses to overwrite it. Merge the desired entries manually or remove the
user-owned file only after confirming it is safe to do so.

If the script exits non-zero, report the error and stop. If `.mcp.json` is
missing, report: `No .mcp.json found — nothing to sync.`

### Step 2: Report the result

Report the source name, Codex name, and action for every server:

| Claude name | Codex name | Action |
|-------------|------------|--------|
| `{server-name}` | `{codex-name}` | synced / already present / skipped |

Tell the user to restart Codex or agy if either was already running; both load
project MCP configuration at session start.
