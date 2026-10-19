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

Write the findings to `.cc-suite/audits/audit-fix-{YYYYMMDD-HHMMSS}-findings.md` **before any fix** (create the directory if missing; store the path as `{findings_file}`), one row per finding:

```markdown
| # | File | Line | Severity | Dimension | Finding | Suggested fix | Status | Round |
|---|------|------|----------|-----------|---------|---------------|--------|-------|
| 1 | {path} | {line} | {sev} | {dim} | {description} | {fix} | open | - |
```

Status values: `open` | `fixed` | `not-fixed` | `partial` | `regressed` | `skipped`. The file — not conversation memory — is the ground truth for the fix loop: a 3-round cycle accumulates diffs, test output, and verdicts, and a findings list held only in context gets silently corrupted if compaction hits mid-loop. Re-reading the file each round makes that impossible, and an interrupted run keeps its audit.

Display the findings table and `{findings_file}` to the user.

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

If "Stop here" → mark every `open` row in `{findings_file}` as `skipped`, display final report, and stop.

Otherwise apply the flag/default silently:
- `--severity=all` (default) → fix all findings
- `--severity=high` → filter to Critical+High (full audit) or High-only (mini audit)

### Step 3: Fix loop (max {--rounds} iterations, default 3)

Set `round = 1`. Mark rows excluded by the severity filter as `skipped` in `{findings_file}`. Each round's fix set is every row with Status `open`, `not-fixed`, or `partial` — **re-read from `{findings_file}` at the start of every round**, never recalled from context.

#### 3a: Codex fixes

For each finding in the round's fix set:
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
    {this round's fix set, re-read from {findings_file}, in file:line | severity | description format}

    For each issue report: FIXED / NOT FIXED / PARTIAL / REGRESSED
    Read the files at the reported locations. Do not assume correctness without reading.
```

After the verdicts arrive, update `{findings_file}`: set each verified row's Status (`fixed` / `not-fixed` / `partial` / `regressed`) and Round.

#### 3c: Evaluate

Read the statuses from `{findings_file}`, not from context.

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

Render from `{findings_file}` — counts and per-finding tables come from the file's rows, so the report cannot drift from the recorded verdicts. Include the file path in the report.

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
| Skipped | N |
| Total | N |

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

## Failure Handling

A Claude-backed call that does not return a usable result is **terminal for this
skill**. Stop and report; do not improvise a way to keep going.

This covers every non-success outcome: a runtime or transport error, a timeout,
a rate limit, an empty or truncated result, and a result that does not match the
shape this skill asked for. Absence of an error is not success — a call that
returns nothing has failed, however it exited.

**Never report a failed call as a result.** It is not `CLEAN`, not "no findings",
not a completed verification, not an empty plan. A verification that did not run
is `UNVERIFIED`, and saying so is the entire value of the step.

**Do not recover on your own initiative.** Unless the user asks for it: do not
retry the call, do not open a replacement session, do not switch to another
Claude execution path (a different MCP tool, a different skill, a direct
invocation), and do not fall back to doing the work yourself in place of the
delegate. A failed `claude_code_reply` in particular must not silently become a
new `claude_code` session — that discards the conversation the reply was meant
to continue, and the original work may still be running.

**Preserve the session.** Report any `session_id` the call returned, even on
failure, so the user can resume that exact session rather than start over.

**Say what may still be running.** A timeout or transport error does not
establish that the work on the other side stopped. Say so explicitly, so the
user does not start a second attempt that overlaps the first.

Then stop according to what the call could have changed:

| Call class | On failure |
|---|---|
| Read-only (`claude-plan`, `claude-review`, `audit`, `verify`, advisor `*_consult`) | Report the operation as blocked, with the error and any `session_id`. Nothing was changed. |
| Write-capable (`claude-debug`, `claude-implement`) | Stop before any further delegation and state explicitly whether partial workspace changes may exist — the delegate may have written files before failing. Recommend the user inspect `git status` / `git diff`. |
| Cycle (`audit-fix`) | Stop the current cycle. Retain the existing findings and their fix status; do not discard them and do not mark unattempted findings as resolved. Report which finding the cycle stopped on. |

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
