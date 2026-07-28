---
name: diagnose
description: "Diagnose the cc-suite setup in the current project. Runs the full health check, explains every issue, and fixes what can be fixed automatically. Skill counterpart to /cc-suite:diagnose."
version: 0.4.0
---

# Diagnose

Run the structured diagnostic engine and act on its report. Skill counterpart to `/cc-suite:diagnose` — both are thin wrappers around the same engine, `scripts/diagnose.py`, which owns every check, its classification, and its repair mapping. Do not re-implement checks here.

## When to Use

- At the start of a session when bridge artifacts may be missing or stale
- After updating cc-suite to confirm the new version is wired as expected
- When `$audit`, `$audit-fix`, or any `$claude-*` skill behaves unexpectedly

## Workflow

### Step 0: Resolve the plugin root

`CLAUDE_PLUGIN_ROOT` is set by Claude Code only — in a Codex or Antigravity session it is unset. Resolve the root from the bridged skills symlink (it points at `<plugin-root>/skills/cc-suite`):

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(readlink -f .claude/skills/cc-suite 2>/dev/null)")")}"
[ -d "${PLUGIN_ROOT}/scripts" ] || echo "! cannot resolve the cc-suite plugin root — run /cc-suite:bridge-skills from Claude Code first, or export CLAUDE_PLUGIN_ROOT"
```

Stop if it could not be resolved.

### Step 1: Run the engine

```bash
python3 "${PLUGIN_ROOT}/scripts/diagnose.py" --json
```

The JSON: `enabled_tools`, `checks[]` (`id`, `label`, `status`, `detail`, `fix{auto[], manual, restart_required}`), `summary`. Statuses: `healthy` / `issue` (fixable) / `info` / `expected_absent` / `manual` / `skipped`. The engine honors the Enabled Tools selection — a deselected tool's absent artifacts are `expected_absent`, never issues. Add `--boot-test` for the network-dependent claude-octopus handshake (tests the version actually registered in `.codex/config.toml`) when delegation misbehaves.

### Step 2: Report

Render the buckets in order — Issues, Manual action needed, Information, Healthy, Expected absent/Skipped — emitting Information even on the no-issues path. If there are no issues and nothing manual: report healthy and stop.

### Step 3: Fix

Ask: "Fix all auto-fixable issues now? (yes / show commands only / cancel)". If yes, for each `issue` check run its `fix.auto` commands in order; a non-zero exit is reported verbatim and that check is NOT counted as fixed. The `model_pin` fix is an edit, not a command: rewrite the `- **Default model**:` line in `.cc-suite.md` to `latest` and touch nothing else. `fix.manual` and `manual`-status items go to the user's to-do list untouched.

### Step 4: Verify by re-running the engine

Run the same engine invocation again and diff per check `id`: fixed (issue → healthy/expected_absent), pending restart (fix applied with `restart_required: true`, still flagged — expected until the host restarts), remaining. Report the three counts. Never claim a fix worked from the fix command's exit code alone.

If issues remain: "Next step: run `/cc-suite:repair` for a full non-interactive re-run of all setup scripts. If that also fails, run `/cc-suite:init` in a Claude Code session."
