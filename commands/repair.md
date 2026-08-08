---
description: Non-interactive re-run of all cc-suite bridge and registration scripts. No questions asked — idempotent, safe to re-run at any time. Use when /cc-suite:diagnose finds issues it could not auto-fix, or when the setup is in an inconsistent state.
---

# CC-Suite Repair

Re-run every cc-suite setup script in sequence, non-interactively. All scripts are idempotent — existing correct artifacts are left alone; missing or broken ones are (re)created.

Use this as the escalation step after `/cc-suite:diagnose` has tried targeted fixes and issues remain. If repair also fails, the next step is `/cc-suite:init` (full interactive re-initialization).

## Workflow

### Step 1: Run bridge init

Creates `AGENTS.md`, `CLAUDE.md` (`@AGENTS.md`), Codex scaffolding, the
`.agents/skills` bridge, and the generated `.agents/mcp_config.json` projection.
Antigravity CLI (`agy`) reads `AGENTS.md` natively and uses `.agents/` workspace
assets; no new Gemini-era project files are created.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"
```

### Step 2: Expose skills

Links plugin skills into `.claude/skills/cc-suite/` and creates `.agents/skills → ../.claude/skills`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"
```

### Step 3: Register codex-cli MCP server

Adds `codex-cli` to `.mcp.json` so Claude can invoke Codex as a tool.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_codex.sh"
```

### Step 4: Register claude-code MCP server

Adds `claude-code` (claude-octopus) to `.codex/config.toml` so Codex can invoke Claude as a tool.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_claude.sh"
```

### Step 5: Mirror MCP servers

Copies MCP servers from `.mcp.json` into `.codex/config.toml` and
`.agents/mcp_config.json` so Codex and agy can see the full project MCP surface.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```

### Step 6: Bridge hooks (if applicable)

Mirrors `.claude/settings.json` hooks into `.codex/hooks.json`. Skips gracefully if there are no hooks to bridge.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_hooks.py"
```

### Step 7: Bridge advisor agents (if applicable)

Re-registers any cc-suite advisor agents declared in `.cc-suite/agents/*.md`. No-op if the directory doesn't exist.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_agents.py"
```

### Step 8: Bridge additional coding agents (if any enabled)

Mirrors the project MCP surface into any registry-bridged tools (Grok Build, opencode, Qwen Code, Kimi CLI) enabled in `.cc-suite.md`. No-op when none are enabled — safe to run unconditionally.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_tools.py"
```

If any script in Steps 1–8 exits non-zero, report the error output and the step that failed, then continue running the remaining steps. Collect all failures and surface them together in the final status below.

### Step 9: Final status

Run the full status check and display the output:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

Report a one-line summary:
- **All green**: "Repair complete — cc-suite is healthy."
- **Issues remain**: list the remaining `·` and `!` items and say: "Run `/cc-suite:init` for a full interactive re-initialization, or check the items above manually."
