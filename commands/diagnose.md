---
description: Diagnose the cc-suite setup in the current project. Runs a full health check, explains every issue found, and offers to fix everything that can be fixed automatically.
---

# CC-Suite Diagnose

All detection, classification, and repair mapping live in one structured engine: `scripts/diagnose.py`. This command is a thin wrapper — run the engine, render its report, apply the fixes it prescribes, then run it again and diff. Do not re-implement checks in prose here; if a check is missing or misclassified, the engine is where it gets fixed.

## The engine contract

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/diagnose.py" --json
```

Returns one JSON object:

- `enabled_tools` — the project's Enabled Tools selection. The engine classifies with this in view: artifacts absent because their tool is deselected report as `expected_absent`, never as issues.
- `checks[]` — each with `id`, `label`, `status`, `detail`, and `fix` (`null`, or `{auto: [shell commands], manual: text, restart_required: bool}`). Statuses: `healthy`, `issue` (fixable — `fix.auto` holds runnable commands, otherwise `fix.manual` explains), `info` (worth knowing, nothing to fix), `expected_absent`, `manual` (only the user can close it), `skipped` (not runnable here).
- `summary` — counts per status.

Flags: `--boot-test` adds the network-dependent claude-octopus boot/handshake check (it tests the version **actually registered** in `.codex/config.toml`, falling back to an expected-pin smoke test when there is no registration). Include it when the user asks for a deep check or Codex→Claude delegation is misbehaving. `--no-preflight` skips the model-pin freshness probe.

## Workflow

### Step 1: Run the engine

Run the engine with `--json` (add `--boot-test` per above). If the script itself fails to run, report the error and fall back to `bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"` for a basic readout — but say clearly that the structured diagnosis was unavailable.

### Step 2: Render the report

Present the checks grouped by bucket, in this order — include **Information** even when there are no issues:

1. **Issues** — table: `# | Item | Diagnosis | Fix` (label, detail, `fix.auto` commands joined with `&&`, or `fix.manual`)
2. **Manual action needed** — items only the user can close, with their `fix.manual` text
3. **Information** — non-issue observations (deliberate model pin drift, user-managed configs, malformed fields)
4. **Healthy** — one line each
5. **Expected absent** / **Skipped** — one line each, so the user sees what was consciously not judged

### Step 3: If no issues and nothing manual

Report: "cc-suite is healthy." with the Healthy and Information buckets, and stop.

### Step 4: If issues exist — offer to fix

```
AskUserQuestion:
  question: "Found {N} fixable issues ({M} more need manual action). Fix the fixable ones now?"
  header: "Auto-fix"
  options:
    - label: "Fix all (Recommended)"
      description: "Run every fix.auto command in sequence"
    - label: "Show fix commands only"
      description: "Print the commands so you can run them yourself"
    - label: "Cancel"
      description: "Do nothing"
```

### Step 5: Apply fixes (if chosen)

For each `issue` check, in report order:

- Run its `fix.auto` commands in sequence. Capture each exit code; on non-zero, report the failure verbatim, skip that check's remaining commands, and continue with the next check — a failed fix must never be counted as applied.
- **`model_pin`** is the one editor fix: rewrite the `- **Default model**:` line in `.cc-suite.md` to `latest` with a single-line Edit (deterministic; write a concrete slug only if the user explicitly asks for a fresh pin). Touch nothing else in the file.
- Checks with only `fix.manual` (and all `manual`-status checks): collect and present as the user's to-do list — do not attempt them.
- Collect every applied fix with `restart_required: true`; after all fixes, tell the user which changes need a Claude Code restart to take effect.

### Step 6: Verify — run the engine again

Re-run the exact same engine invocation and diff per check `id`:

- **fixed** — was `issue`, now `healthy` / `expected_absent`
- **pending restart** — was `issue`, fix applied with `restart_required`, still reporting `issue` (expected until restart — not a failure)
- **remaining** — still `issue` (or new)

Report the counts: "{fixed} fixed, {pending} pending restart, {remaining} remaining." The second engine run is the verification — never claim a fix worked based on the fix command's exit code alone.

### Step 7: If issues remain

Close with: "Issues remain. Next step: run `/cc-suite:repair` for a full non-interactive re-run of all setup scripts. If that also fails, run `/cc-suite:init` for a complete interactive re-initialization."
