---
name: audit-fix
description: "Full audit→fix→verify cycle: Claude audits, Codex fixes, Claude verifies. Repeats up to 3 rounds until all issues are resolved or the user stops. Claude does all code reading and judgment; Codex does all file editing."
version: 0.2.4
---

# Audit-Fix

Claude audits. Codex fixes. Claude verifies. Repeat until clean.

This is the primary quality loop: Claude provides independent analysis and verification; Codex applies targeted fixes without second-guessing the findings.

## When to Use

- After writing a feature and wanting automated quality enforcement
- When asked to "audit and fix this"
- Before a commit when you want findings resolved, not just reported

## Arguments

| Argument | Default | Effect |
|----------|---------|--------|
| `--full` | off | 9-dimension audit |
| `--mini` | on | 5-dimension audit (faster) |
| `--rounds N` | 3 | Maximum fix→verify iterations |
| `--severity=all\|high` | `all` | Which findings to fix. `high` = Critical+High (full) or High-only (mini) |
| `--ask` | off | Restore interactive severity-filter and continue/stop prompts |
| file/dir path | cwd | Scope |

By default this skill runs **non-interactively**: fixes **all** findings, and stops after the first round if any issues remain. Pass `--ask` to restore the prompts.

## Workflow

### Step 1: Audit (Claude)

Call `claude_code` following the `$audit` skill pattern.

```
mcp__claude-code__claude_code:
  prompt: |
    Audit the following code and report every issue with exact file:line locations.

    SCOPE: {files or directory}

    {5 or 9 audit dimensions — same as $audit skill}

    For each finding: file:line | severity | dimension | issue | suggested fix

    PROVENANCE NOTE: Code written by OpenAI Codex. Evaluate with full rigor.
  cwd: {project working directory}
  effort: high
  permissionMode: plan
```

Save `session_id` as `{cycle_session_id}`.

If **no findings** → report CLEAN and stop.

Display findings table to the user.

### Step 2: Severity filter

Parse `--severity=` and `--ask` from arguments.

If `--ask` is set:

```
Ask user: "Found N issues (Critical: N, High: N, Medium: N, Low: N). Which to fix?"
Options:
  - Fix all
  - Fix Critical + High only
  - Stop here (keep audit, fix manually)
```

If "Stop here" → display final report and stop.

Otherwise apply the flag/default silently:
- `--severity=all` (default) → fix all findings
- `--severity=high` → filter to Critical+High (full audit) or High-only (mini audit)

### Step 3: Fix loop (max {--rounds} iterations, default 3)

Set `round = 1`. Track `{remaining_issues}` = issues from the active severity filter.

#### 3a: Codex fixes

For each issue in `{remaining_issues}`:
- Read the file at the reported location
- Apply a minimal, correct fix — no refactoring of surrounding code, no deletions unless the issue calls for removal
- Only touch the reported location and directly related code

After all fixes, run the project test suite if one is detectable:
- `package.json` with a `test` script → `npm test`
- `pytest.ini` or `conftest.py` → `pytest`
- `go.mod` → `go test ./...`
- `Cargo.toml` → `cargo test`

Show `git diff --stat` and test results to the user.

#### 3b: Claude verifies (same session)

```
mcp__claude-code__claude_code_reply:
  session_id: {cycle_session_id}
  prompt: |
    The following issues from your audit have been addressed. Verify each one.

    ISSUES:
    {remaining_issues in file:line | severity | description format}

    For each issue report: FIXED / NOT FIXED / PARTIAL / REGRESSED
    Read the files at the reported locations. Do not assume correctness without reading.
```

#### 3c: Evaluate

- **All FIXED** → proceed to Step 4
- **Issues remain** and `round < {--rounds}`:
  - If `--ask` is set:
    - Increment `round`
    - Show remaining issues
    - Ask: "N issues remain after round {round-1}. Fix again? (yes / stop)"
    - "yes" → back to 3a with remaining issues only
    - "stop" → proceed to Step 4
  - Otherwise (no `--ask`): default to "stop" — proceed to Step 4 with current partial state.
- **round == {--rounds}** → proceed to Step 4

### Step 4: Final report

```markdown
## Audit-Fix Report

Scope: {what was audited}
Audit depth: mini (5-dim) / full (9-dim)
Rounds: {round count}

| Status | Count |
|--------|-------|
| Fixed | N |
| Not Fixed | N |
| Partial | N |
| Regressed | N |

### Fixed

| File:Line | Severity | Issue |
|-----------|----------|-------|
| ... | ... | ... |

### Remaining (if any)

| File:Line | Severity | Issue | Verdict | Notes |
|-----------|----------|-------|---------|-------|
| ... | ... | ... | NOT FIXED | ... |

### Changes

{git diff --stat}

### Next steps

- Review: `git diff`
- Run tests if not already run
- Commit if satisfied
- For remaining issues: fix manually or run `$audit-fix` again on the remaining files
```

## Notes

- Claude's `permissionMode: plan` during audit keeps it read-only — only Codex writes files
- Reusing `{cycle_session_id}` for verification gives Claude full context of what it originally flagged, producing sharper verdicts than a fresh session
- Keep fixes minimal — Codex should touch only what Claude flagged; regressions come from broad edits
- If a fix causes test failures, revert that fix and report it as NOT FIXED rather than introducing new failures

## Scope Note

Covers the full audit→fix→verify loop: Claude audits, Codex fixes, Claude verifies, repeat. For an audit-only pass that reports findings without changing files, use `$audit`. For confirming fixes that were made outside this loop, use `$verify`.

## Example Invocations

<example>
Context: A feature branch is finished and the user wants findings resolved, not just listed, before opening a PR.
user: "Audit the changes on this branch and fix what you find."
assistant: "I'll run audit-fix — Claude audits the diff, Codex applies each fix, and Claude verifies every one before I report the round summary."
</example>

<example>
Context: A previous audit produced a findings list that nobody acted on.
user: "Don't just tell me what's wrong this time — actually fix it and confirm the fixes hold."
assistant: "I'll invoke audit-fix so each finding goes through the fix-then-verify loop, repeating up to 3 rounds until the audit comes back clean."
</example>
