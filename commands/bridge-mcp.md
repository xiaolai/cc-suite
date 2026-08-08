---
description: Mirror MCP servers from .mcp.json into Codex and Antigravity workspace configs
allowed-tools:
  - Bash
---

# /cc-suite:bridge-mcp

Copy every MCP server registered in `.mcp.json` into both target projections:
Codex's `.codex/config.toml` and Antigravity's generated
`.agents/mcp_config.json`. The agy projection also registers the pinned
`claude-code` server for agy → Claude delegation.

Idempotent and reconciliatory. Codex entries are sentinel-managed and stale
cc-suite-owned entries are removed when they disappear from `.mcp.json`. Agy
entries are refreshed only when the provenance file belongs to cc-suite;
user-managed agy configs are never overwritten. Names containing characters Codex rejects (for example,
`@scope/pkg`) are normalized only in the Codex projection.

The explicit alias `/cc-suite:sync-mcp` runs the same sync for discoverability.

## Workflow

### Step 1: Run the bridge script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```

If the script exits non-zero, report the error output and stop. If `.mcp.json`
does not exist, Codex receives no project servers; the agy projection still
contains cc-suite's reverse Claude bridge.

### Step 2: Report results

Use this template:

```markdown
**bridge-mcp**: MCP servers mirrored from `.mcp.json` to Codex and agy

| Server | Action |
|--------|--------|
| {server-name} | mirrored |
| {server-name} | already present (skipped) |
| codex-cli | available to agy; skipped in Codex's own config |
```

Success criterion: script exits 0 and the source servers appear in both target
configs, subject to transport validation and user-managed conflict protection.
