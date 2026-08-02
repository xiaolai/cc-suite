---
description: Refresh the cc-suite bridge after updating the plugin. Re-renders MCP registrations, pre-warms the npx cache for the pinned claude-octopus, and verifies the pin actually boots and speaks MCP.
---

# CC-Suite Update

Use this **after** running `claude plugin update cc-suite@xiaolai`. The plugin-update command itself is a Claude Code operation — this command picks up where it leaves off: re-renders the cc-suite-managed bits of `.codex/config.toml`, ensures the new claude-octopus pin actually works on this machine, and reports any remaining staleness.

This is distinct from `/cc-suite:repair`. **Repair** is the recovery path when artifacts are broken or missing. **Update** is the deliberate refresh path after the plugin itself has moved.

## Workflow

### Step 1: Confirm the plugin has actually been updated

Read the currently-installed plugin version:

```bash
node -p "require('${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json').version"
```

Tell the user the active version. If they haven't yet run `claude plugin update cc-suite@xiaolai`, stop and tell them to do that first. The update command cannot replace the running plugin; that's Claude Code's job.

### Step 2: Re-render the bridge artifacts

Run every bridge script (mirrors what `/cc-suite:repair` would run). This is the user-side half of the coupled-release contract — every artifact the plugin owns gets rewritten against the *current* plugin's expectations.

```bash
bash    "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"
bash    "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_codex.sh"
bash    "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_claude.sh"
bash    "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_hooks.py"
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_agents.py"
```

`bridge_skills.sh` is critical here: the `.claude/skills/cc-suite` symlink points at the plugin's version-stamped cache path (e.g. `~/.claude/plugins/cache/xiaolai/cc-suite/0.3.0/skills/cc-suite`). After `claude plugin update`, the new version lives at a different cache path, so the symlink is stale until re-pointed.

`mcp_claude.sh` will print one of:
- `· already pins claude-octopus@<version>` → no-op, already current.
- `✓ claude-code MCP server refreshed (now pinned @<version>)` → block was stale, has been rewritten.
- `· … not cc-suite-managed — leaving it alone` → a user-owned block exists; surface this so the user knows their custom registration is being preserved.

### Step 3: Pre-warm the npx cache for the pinned claude-octopus

The first time Codex starts the `claude-code` MCP server, npx downloads the pinned `claude-octopus` package. Doing it now (instead of during the first Codex delegation) means the user doesn't watch a 10-second pause during real work.

```bash
PIN="$(tr -d '[:space:]' < ${CLAUDE_PLUGIN_ROOT}/scripts/lib/claude-octopus-pin.txt)"
npx -y --quiet claude-octopus@${PIN} --help >/dev/null 2>&1 || true
```

This step is best-effort; if the user is offline, skip silently and let Step 4 surface the failure.

### Step 4: Boot-handshake test the pinned version

Run the pinned claude-octopus as if Codex were starting it, send one MCP `initialize`, verify the response. This is the only check that catches "pin published but broken on this machine."

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/lib/boot_test_claude_mcp.mjs"
```

Exit 0 = handshake ok. Non-zero = report the failure verbatim and stop.

If the boot test fails, the most likely causes (rank by frequency):
- Network/npm registry unreachable — the user is offline or behind a firewall.
- The pinned version was yanked from npm — escalate to the cc-suite maintainer.
- A peer dependency of claude-octopus no longer resolves cleanly — escalate to the cc-suite maintainer.

### Step 5: Run the bridge status check

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

Report the result. If status shows all `✓`, end with:

```
cc-suite updated and verified. The pinned claude-octopus@<version> boots and responds to MCP.
```

If status shows any `·` or `!` lines, summarize what's still off and suggest `/cc-suite:repair` (for missing artifacts) or `/cc-suite:diagnose` (for diagnosis with auto-fix).
