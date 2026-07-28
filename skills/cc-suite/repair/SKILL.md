---
name: repair
description: "Non-interactive re-run of all cc-suite bridge and registration scripts. No questions asked — idempotent escalation step after the diagnose skill finds issues it could not fix. Skill counterpart to /cc-suite:repair."
version: 0.3.0
---

# Repair

Re-run every cc-suite setup script in sequence without prompts. All scripts are idempotent — correct artifacts are left alone, missing or broken ones are recreated.

## When to Use

- `/cc-suite:diagnose` found issues and its auto-fix did not resolve them
- The cc-suite layer is in an inconsistent state (e.g. after a manual edit gone wrong)
- After reinstalling cc-suite to a project, to restore all artifacts at once

If repair still leaves issues, the next step is `/cc-suite:init` in a Claude Code session (full interactive re-initialization).

## Workflow

### Step 0: Resolve the plugin root

`CLAUDE_PLUGIN_ROOT` is set by Claude Code only — in a Codex or Antigravity session it is unset. Resolve the root from the bridged skills symlink (it points at `<plugin-root>/skills/cc-suite`):

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(readlink -f .claude/skills/cc-suite 2>/dev/null)")")}"
[ -d "${PLUGIN_ROOT}/scripts" ] || echo "! cannot resolve the cc-suite plugin root — run /cc-suite:bridge-skills from Claude Code first, or export CLAUDE_PLUGIN_ROOT"
```

Every command below uses `${PLUGIN_ROOT}`. Stop if it could not be resolved.

### Step 1: Bridge init

```bash
bash "${PLUGIN_ROOT}/scripts/init.sh"
```

Creates `AGENTS.md`, `CLAUDE.md`, Codex scaffolding, the `.agents/` workspace
skills/MCP projections, and the `.gitignore` block. Antigravity CLI (`agy`)
reads `AGENTS.md` natively and no new Gemini-era project scaffolding is
created. Skips each artifact if it is already in place.

### Step 2: Expose skills

```bash
bash "${PLUGIN_ROOT}/scripts/bridge_skills.sh"
```

Links plugin skills into `.claude/skills/cc-suite/` and ensures `.agents/skills → ../.claude/skills`.

### Step 3: Register codex-cli MCP server

```bash
bash "${PLUGIN_ROOT}/scripts/mcp_codex.sh"
```

Adds `codex-cli` to `.mcp.json` so Claude can invoke Codex as a tool.

### Step 4: Register claude-code MCP server

```bash
bash "${PLUGIN_ROOT}/scripts/mcp_claude.sh"
```

Adds `claude-code` (claude-octopus) to `.codex/config.toml` so Codex can invoke Claude as a tool.

### Step 5: Mirror MCP servers

```bash
bash "${PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```

Copies additional MCP servers from `.mcp.json` into `.codex/config.toml` and the
generated `.agents/mcp_config.json` projection for agy. User-managed agy
configuration without cc-suite provenance is preserved.

### Step 6: Bridge hooks

```bash
python3 "${PLUGIN_ROOT}/scripts/bridge_hooks.py"
```

Mirrors `.claude/settings.json` hooks into `.codex/hooks.json`. Skips gracefully if nothing to bridge.

### Step 6b: Bridge additional coding agents

```bash
python3 "${PLUGIN_ROOT}/scripts/bridge_tools.py"
```

Mirrors the project MCP surface into any registry-bridged tools (Grok Build, opencode, Qwen Code, Kimi CLI) enabled in `.cc-suite.md`'s `## Enabled Tools` section. No-op when none are enabled.

### Step 7: Status check

```bash
bash "${PLUGIN_ROOT}/scripts/status.sh"
```

Show the full status output. Then report:

- **All green**: "Repair complete — cc-suite is healthy."
- **Issues remain**: list remaining `·` and `!` items. Distinguish:
  - Items fixable only interactively (e.g. `AGENTS.md` missing when a non-importable `CLAUDE.md` exists): "Run `/cc-suite:init` in a Claude Code session."
  - Items requiring manual action (Codex trust prompt, Codex CLI not installed): give the exact manual step.
