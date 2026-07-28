---
name: diagnose
description: Diagnose the cc-suite setup in the current project. Runs a full health check, explains every issue found, and offers to fix everything that can be fixed automatically.
---

# CC-Suite Diagnose

Inspect every cc-suite artifact and configuration in the current project, explain what is wrong or missing, and offer to auto-fix what is fixable.

## Workflow

### Step 1: Run the status script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

Capture the full output. Parse every line:
- Lines starting with `  ✓` → healthy
- Lines starting with `  ·` → missing (never set up)
- Lines starting with `  !` → warning (exists but misconfigured)

### Step 2: Run additional deep checks

These are not covered by status.sh.

**Check A — stale nested symlinks**

Look for any symlinks inside `.claude/skills/` or `.agents/skills/` that resolve to a path containing another `cc-suite` directory (the macOS `ln -sf` bug artifact):

```bash
find -L .claude/skills/ .agents/skills/ -maxdepth 3 -name "cc-suite" -type d 2>/dev/null | grep -v "^.claude/skills/cc-suite$" | grep -v "^.agents/skills/cc-suite$"
```

If any paths are returned, flag them as stale nested symlinks.

**Check B — Codex CLI availability**

```bash
which codex 2>/dev/null || echo "not-found"
```

**Check B2 — Antigravity CLI availability**

```bash
which agy 2>/dev/null || echo "not-found"
```

**Check C — cache freshness**

Read the active plugin version from the `.claude/skills/cc-suite` symlink target:

```bash
readlink .claude/skills/cc-suite 2>/dev/null || echo "missing"
```

Extract the version from the path (e.g. `.../cc-suite/0.2.4/skills/cc-suite` → `0.2.4`).

Compare to the version in `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json` (the installed plugin manifest). If they differ, flag as stale — the symlink points to an older cache. If the symlink target contains no semver (e.g. a development checkout), skip this check.

**Check D — broken symlinks in skills chain**

```bash
[ -L .claude/skills/cc-suite ] && [ ! -d .claude/skills/cc-suite ] && echo "broken" || echo "ok"
[ -L .agents/skills ] && [ ! -d .agents/skills ] && echo "broken" || echo "ok"
```

**Check E — pinned claude-octopus boots and handshakes**

This is the only check that catches "the registered claude-octopus@<version> is no longer reachable / no longer works on this machine." Network-dependent.

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/lib/boot_test_claude_mcp.mjs"
```

Exit 0 = pin works. Non-zero = report verbatim and flag as a fixable issue (the fix is `/cc-suite:update`, which refreshes the registration and re-tests).

**Check F — `.cc-suite.md` model pin freshness**

Extract the value from the `- **Default model**:` line in the `## Defaults` section of `.cc-suite.md` (match that field exactly; trim whitespace; compare values case-insensitively):

```bash
grep -in '^\- \*\*Default model\*\*:' .cc-suite.md
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-preflight.sh"
```

- Skip when `.cc-suite.md` does not exist, the field is absent, or its value is `latest` — a policy value never goes stale.
- If the field appears more than once or its value is empty → report as malformed config (informational, with the line numbers) and skip the freshness comparison.
- Preflight `status` is `"error"` → skip the check; staleness cannot be judged without a catalog. Note that preflight reports the catalog as Codex's local models cache sees it (plus preflight's own 5-minute result cache) — `codex login` refreshes the underlying cache if it looks outdated.

If the field pins a concrete slug:

- Pinned slug **not in** the preflight `models` array → flag as a fixable issue (**model pin stale**): every model-selecting command warns and falls back to the preflight default (see `commands/shared/model-selection.md`), and the config line stays dead weight until fixed.
- Pinned slug present but different from preflight `default_model` → not an issue. Add one informational line to the report ("`.cc-suite.md` pins `X`; catalog latest is `Y`") so a deliberate pin stays visible without being nagged.

### Step 3: Build the diagnosis report

Group all findings into three buckets:

**Healthy** — list items that passed (one line each, `✓`).

**Information** — non-issue observations that should stay visible: a deliberate model pin that is older than the catalog's latest (Check F), a malformed `Default model` field, or any other "worth knowing, nothing to fix" note. Include this bucket in the report even when there are no issues.

**Issues** — for every `·` or `!` item and every failed deep check, produce a structured entry:

| # | Item | Status | Diagnosis | Fix command |
|---|------|--------|-----------|-------------|
| 1 | `.agents/skills` | missing | Codex cannot see any skills | `/cc-suite:bridge-skills` |
| 2 | `.codex/hooks.json` | missing | Project hooks not bridged to Codex | `/cc-suite:bridge-hooks` (only needed if you have hooks in `.claude/settings.json`) |
| 3 | `.mcp.json → codex-cli` | missing | Claude cannot invoke Codex as MCP tool | `/cc-suite:init` step 8 |
| 4 | `.codex/config.toml → claude-code` | missing | Codex cannot invoke Claude as MCP tool | `/cc-suite:init` step 9 |
| 5 | `plugin_hooks` | not set | Plugin-bundled Codex hooks are inert | Add `plugin_hooks = true` under `[features]` in `~/.codex/config.toml` |
| 6 | `project trust` | not trusted | Codex hooks and rules are inert for this project | Run `codex` once in this directory and accept the trust prompt |
| 7 | stale nested symlink | present | Duplicate skills visible in Codex | `rm {path}` then `/cc-suite:bridge-skills` |
| 8 | cache stale | version mismatch | Skills symlink points to old cache | Run `claude plugin update cc-suite@xiaolai` then `/cc-suite:bridge-skills` |
| 9 | Codex CLI | not found | `$audit`, `$audit-fix`, `$claude-*` skills require Codex CLI | Install from https://github.com/openai/codex |
| 10 | `.mcp.json → codex-cli` | stale | Project still has the legacy npm registration — Codex MCP server loads with the wrong API and every Codex call falls back | `/cc-suite:repair` |
| 11 | `.codex/config.toml → Codex` | stale pin | Registered claude-octopus version doesn't match the plugin's expected pin — Codex may be running an older Claude bridge | `/cc-suite:update` |
| 12 | claude-octopus boot test | failed | The pinned claude-octopus does not boot or respond to MCP on this machine — Codex delegation to Claude will fail | `/cc-suite:update` (refreshes registration + re-tests). If still failing, the pin may be broken; escalate to the cc-suite maintainer. |
| 13 | `.agents/mcp_config.json → agy` | missing/stale | Antigravity cannot see the workspace MCP surface or delegate to Claude | `/cc-suite:bridge-mcp` |
| 14 | `agy CLI` | not found | Google-backed delegation and Antigravity preflight are unavailable | Install with the command shown by `/cc-suite:agy-preflight` |
| 15 | legacy `GEMINI.md` / `.gemini/` | present | Legacy Google files need deliberate migration or may be retained for enterprise use | `/cc-suite:migrate-google` |
| 16 | `.cc-suite.md → Default model` | stale pin | Pinned model no longer exists in the Codex catalog — model-selecting commands warn and fall back to the preflight default on every call | Rewrite the `Default model` line to `latest` |

Use the actual item names and details from the status output — the table above is a reference mapping, not a literal template.

If `.codex/hooks.json` is the only `·` and the project has no hooks in `.claude/settings.json`, annotate it as "expected — no hooks to bridge" and exclude it from the issues list.

### Step 4: If no issues

Report:

```
cc-suite is healthy. All bridge artifacts and MCP registrations are in place.
```

List the healthy items and stop.

### Step 5: If issues exist — offer to fix

Show the issues table. Then ask:

```
AskUserQuestion:
  question: "Found N issues. Fix them now?"
  header: "Auto-fix"
  options:
    - label: "Fix all (Recommended)"
      description: "Run every auto-fixable command in sequence"
    - label: "Show fix commands only"
      description: "Print the commands so you can run them yourself"
    - label: "Cancel"
      description: "Do nothing"
```

### Step 6: Execute fixes (if chosen)

Run each fixable issue's fix in order. For each:

**`/cc-suite:bridge-skills`** — run:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"
```

**`/cc-suite:bridge-hooks`** — run:
```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_hooks.py"
```

**`/cc-suite:bridge-mcp`** — run:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```

**`/cc-suite:init` step 8 (codex-cli MCP) — fixes both missing and stale registrations** — run:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_codex.sh"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```
After this runs, **restart Claude Code** so the MCP loader picks up the new server definition.

**`/cc-suite:init` step 9 (claude-code MCP)** — run:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_claude.sh"
```

**`/cc-suite:update` (stale pin or failed boot test)** — re-render the claude-code MCP block with the current pin, pre-warm the npx cache, and re-run the boot handshake. The full flow lives in `/cc-suite:update`; the auto-fix path can run the same scripts inline:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_claude.sh"
node "${CLAUDE_PLUGIN_ROOT}/scripts/lib/boot_test_claude_mcp.mjs"
```

**stale nested symlink** — remove the flagged path:
```bash
rm "{stale_path}"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"
```

**cache stale** — update the plugin and repoint skills:
```bash
claude plugin update cc-suite@xiaolai
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"
```

**model pin stale** — rewrite the `Default model` line in `.cc-suite.md` to the policy value `latest`. That is what "Fix all" writes — deterministic, tracks the catalog, cannot go stale again. Edit that single line only; leave the rest of the file untouched. Write a concrete slug (preflight's current `default_model`) only when the user explicitly asks for a fresh pin instead.

**`plugin_hooks` not set** — write it directly:
```bash
python3 -c "
import pathlib, re
f = pathlib.Path.home() / '.codex/config.toml'
text = f.read_text()
if '[features]' in text:
    text = re.sub(r'(\[features\]\n)', r'\1plugin_hooks = true\n', text, count=1)
else:
    text += '\n[features]\nplugin_hooks = true\n'
f.write_text(text)
print('plugin_hooks = true written to ~/.codex/config.toml')
"
```

Items that **cannot** be auto-fixed (flag and explain):
- `project trust` — requires the user to run `codex` interactively and accept the trust prompt
- Codex CLI not installed — requires manual install

### Step 7: Re-run status and report result

After applying all auto-fixes, re-run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"` and show the updated output.

Report the count of issues fixed (N fixed, M remain). If all issues are resolved, report success: "cc-suite is healthy." If issues persist after auto-fix, close with:

"Issues remain. Next step: run `/cc-suite:repair` for a full non-interactive re-run of all setup scripts. If that also fails, run `/cc-suite:init` for a complete interactive re-initialization."
