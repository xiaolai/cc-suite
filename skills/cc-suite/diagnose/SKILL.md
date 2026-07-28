---
name: diagnose
description: "Diagnose the cc-suite setup in the current project. Runs the full health check, explains every issue, and fixes what can be fixed automatically. Skill counterpart to /cc-suite:diagnose."
version: 0.3.1
---

# Diagnose

Run a full cc-suite health check and offer to auto-fix every issue found. Skill counterpart to `/cc-suite:diagnose`.

## When to Use

- At the start of a session when bridge artifacts may be missing or stale
- After updating cc-suite to confirm the new version is wired as expected
- When `/cc-suite:audit`, `/cc-suite:audit-fix`, or any `/cc-suite:claude-*` skill behaves unexpectedly

## Workflow

### Step 0: Resolve the plugin root

`CLAUDE_PLUGIN_ROOT` is set by Claude Code only — in a Codex or Antigravity session it is unset. Resolve the root from the bridged skills symlink (it points at `<plugin-root>/skills/cc-suite`):

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(readlink -f .claude/skills/cc-suite 2>/dev/null)")")}"
[ -d "${PLUGIN_ROOT}/scripts" ] || echo "! cannot resolve the cc-suite plugin root — run /cc-suite:bridge-skills from Claude Code first, or export CLAUDE_PLUGIN_ROOT"
```

Every command below uses `${PLUGIN_ROOT}`. Stop if it could not be resolved.

### Step 1: Status check

Run the status script:

```bash
bash "${PLUGIN_ROOT}/scripts/status.sh"
```

### Step 2: Deep checks

**Stale nested symlinks** (macOS `ln -sf` residue):

```bash
find .claude/skills/ .agents/skills/ -maxdepth 3 -name "cc-suite" -type l 2>/dev/null \
  | grep -vx ".claude/skills/cc-suite" | grep -vx ".agents/skills/cc-suite"
```

For each returned path, `readlink` it: it is stale residue only if the target points into a cc-suite skills tree (contains `skills/cc-suite`). Real directories or symlinks pointing elsewhere are not residue — report informationally, never offer deletion.

**Codex CLI binary**:

```bash
which codex 2>/dev/null || echo "not-found"
```

**Cache freshness** — extract the version from the active symlink target and compare to the `version` field of `${PLUGIN_ROOT}/.claude-plugin/plugin.json` (the installed plugin manifest). If they differ, the skills symlink points to an old cache. Skip when the symlink target contains no semver (e.g. a development checkout).

```bash
readlink .claude/skills/cc-suite 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "missing"
```

**Broken symlinks**:

```bash
[ -L .claude/skills/cc-suite ] && [ ! -d .claude/skills/cc-suite ] && echo "broken:claude-skills" || true
[ -L .agents/skills ]          && [ ! -d .agents/skills ]          && echo "broken:agents-skills"  || true
```

**`.cc-suite.md` model pin freshness** — extract the value of the `- **Default model**:` field in the `## Defaults` section (match that field exactly; trim whitespace; compare case-insensitively). Skip when the field is absent or reads `latest` (a policy value never goes stale); duplicate or empty fields → report as malformed config (informational) and skip the comparison. If it pins a concrete slug, compare against the catalog as preflight reports it:

```bash
grep -in '^\- \*\*Default model\*\*:' .cc-suite.md 2>/dev/null
bash "${PLUGIN_ROOT}/scripts/codex-preflight.sh"
```

Pinned slug missing from the preflight `models` array → fixable issue (model-selecting commands warn and fall back to the preflight default on every call; the pinned line stays dead weight until fixed). Pinned slug present but no longer the catalog's `default_model` → informational line only, not an issue — emit it in the report even on the no-issues path, before reporting healthy. Preflight error → skip the check.

### Step 3: Diagnose and report

Build an issues list from all `·` (missing) and `!` (warn) lines in the status output, plus any deep check failures.

Exclude `.codex/hooks.json` from issues if the project has no `hooks` section in `.claude/settings.json` — that missing entry is expected.

Display the diagnosis:

```
cc-suite diagnose — {cwd}

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
| `.agents/skills` missing or wrong | `bash "${PLUGIN_ROOT}/scripts/bridge_skills.sh"` |
| `.claude/skills/cc-suite` missing or wrong | `bash "${PLUGIN_ROOT}/scripts/bridge_skills.sh"` |
| `.codex/hooks.json` missing | `python3 "${PLUGIN_ROOT}/scripts/bridge_hooks.py"` |
| `.mcp.json → codex-cli` missing | `bash "${PLUGIN_ROOT}/scripts/mcp_codex.sh"` |
| `.codex/config.toml → claude-code` missing | `bash "${PLUGIN_ROOT}/scripts/mcp_claude.sh"` |
| MCP parity gaps | `bash "${PLUGIN_ROOT}/scripts/bridge_mcp.sh"` |
| stale nested symlink at `{path}` (target verified to point into a cc-suite skills tree) | `rm "{path}" && bash "${PLUGIN_ROOT}/scripts/bridge_skills.sh"` |
| cache stale | `claude plugin update cc-suite@xiaolai`, then STOP — the current session's plugin root predates the update, so re-running its `bridge_skills.sh` would repoint to the old cache; restart and run `/cc-suite:bridge-skills` in the new session |
| `plugin_hooks` not set | Set `plugin_hooks = true` idempotently in `~/.codex/config.toml`: replace an existing `plugin_hooks = …` assignment, otherwise insert once under `[features]`; parse-validate before writing (duplicate keys invalidate TOML) |
| model pin stale | Rewrite the `Default model` line in `.cc-suite.md` to `latest` (the deterministic fix-all value; a concrete slug only on explicit user request) — edit that line only |

Items that require manual action (flag, do not attempt to fix):
- **`project trust` not trusted** — run `codex` in this directory and accept the trust prompt
- **Codex CLI not found** — install from https://github.com/openai/codex
- **`AGENTS.md` missing** — run `/cc-suite:init` in a Claude Code session (requires Claude)

### Step 6: Re-run status and summarise

After all auto-fixes, run `bash "${PLUGIN_ROOT}/scripts/status.sh"` again.

Report: N issues fixed, N remaining (with manual steps for those that remain).

If issues persist after auto-fix, close with: "Issues remain. Next step: run `/cc-suite:repair` for a full non-interactive re-run of all setup scripts. If that also fails, run `/cc-suite:init` for a complete interactive re-initialization."
