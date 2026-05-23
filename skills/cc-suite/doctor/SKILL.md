---
name: doctor
description: "Diagnose the cc-suite setup in the current project. Runs the full health check, explains every issue, and fixes what can be fixed automatically. Skill counterpart to /cc-suite:doctor."
version: 0.2.5
---

# Doctor

Run a full cc-suite health check and offer to auto-fix every issue found. Skill counterpart to `/cc-suite:doctor`.

## When to Use

- At the start of a session when bridge artifacts may be missing or stale
- After updating cc-suite to confirm the new version is wired as expected
- When `$audit`, `$audit-fix`, or `$claude-*` skills behave unexpectedly

## Workflow

### Step 1: Status check

Run the status script:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

### Step 2: Deep checks

**Stale nested symlinks** (macOS `ln -sf` residue):

```bash
find -L .claude/skills/ .agents/skills/ -maxdepth 3 -name "cc-suite" -type d 2>/dev/null \
  | grep -vE "^\.claude/skills/cc-suite$|^\.agents/skills/cc-suite$"
```

Any output is a stale nested symlink that duplicates skills in Codex.

**Codex CLI binary**:

```bash
which codex 2>/dev/null || echo "not-found"
```

**Cache freshness** — extract the version from the active symlink target and compare to `${CLAUDE_PLUGIN_ROOT}/../../.claude-plugin/plugin.json` (the installed plugin version). If they differ, the skills symlink points to an old cache.

```bash
readlink .claude/skills/cc-suite 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "missing"
```

**Broken symlinks**:

```bash
[ -L .claude/skills/cc-suite ] && [ ! -d .claude/skills/cc-suite ] && echo "broken:claude-skills" || true
[ -L .agents/skills ]          && [ ! -d .agents/skills ]          && echo "broken:agents-skills"  || true
```

### Step 3: Diagnose and report

Build an issues list from all `·` (missing) and `!` (warn) lines in the status output, plus any deep check failures.

Exclude `.codex/hooks.json` from issues if the project has no `hooks` section in `.claude/settings.json` — that missing entry is expected.

Display the diagnosis:

```
cc-suite doctor — {cwd}

Healthy: N items ✓

Issues found: N

  #  Item                           Status     Diagnosis
  1  .agents/skills                 missing    Codex cannot see any skills
  2  .mcp.json → codex-cli          missing    Claude cannot invoke Codex as MCP tool
  3  plugin_hooks                   not set    Plugin-bundled hooks are inert in Codex
  ...
```

If no issues: report healthy and stop.

### Step 4: Offer to fix

Ask:

```
Fix all auto-fixable issues now? (yes / show commands only / cancel)
```

### Step 5: Apply fixes

For each fixable issue, run the corresponding script:

| Issue | Fix |
|-------|-----|
| `.agents/skills` missing or wrong | `bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"` |
| `.claude/skills/cc-suite` missing or wrong | `bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"` |
| `.codex/hooks.json` missing | `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_hooks.py"` |
| `.mcp.json → codex-cli` missing | `bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_codex.sh"` |
| `.codex/config.toml → claude-code` missing | `bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_claude.sh"` |
| MCP parity gaps | `bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"` |
| stale nested symlink at `{path}` | `rm "{path}" && bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"` |
| cache stale | `bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"` (repoints to current cache) |
| `plugin_hooks` not set | Write `plugin_hooks = true` under `[features]` in `~/.codex/config.toml` |

Items that require manual action (flag, do not attempt to fix):
- **`project trust` not trusted** — run `codex` in this directory and accept the trust prompt
- **Codex CLI not found** — install from https://github.com/openai/codex
- **`AGENTS.md` missing** — run `/cc-suite:init` in a Claude Code session (requires Claude)

### Step 6: Re-run status and summarise

After all auto-fixes, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"` again.

Report: N issues fixed, N remaining (with manual steps for those that remain).

If issues persist after auto-fix, close with: "Issues remain. Next step: run `$repair` for a full non-interactive re-run of all setup scripts. If that also fails, run `/cc-suite:init` in a Claude Code session for a complete interactive re-initialization."
