---
name: audit-fix
description: Audit→fix→verify loop — finds issues, fixes them, verifies fixes, repeats until clean or you stop
argument-hint: "[scope] [--full | --mini]"
---

## User Input

```text
$ARGUMENTS
```

## What This Does

Runs a complete audit→fix→verify cycle:

1. **Audit** — find issues (full 9-dimension or mini 5-dimension)
2. **Fix** — Claude or Codex fixes the issues (your choice)
3. **Verify** — check that each fix actually resolved the issue
4. **Repeat** — if issues remain, loop back to fix

Continues until all issues are resolved or the user decides to stop.

## Model & Settings Selection

Follow the instructions in `commands/shared/model-selection.md` to discover available models and present choices.

- **Recommended model**: first available from preflight
- **Recommended reasoning effort**: `high`
- **Recommended sandbox level**: `workspace-write`
- **Include sandbox question**: Yes (fixes require write access)

> **Warning**: If the user selects `danger-full-access` sandbox, display a confirmation before proceeding: "You chose `danger-full-access` with no approval prompts — Codex will have unrestricted access. Continue?" Use `AskUserQuestion` with "Continue" and "Switch to workspace-write" options.

## Workflow

### Step 1: Determine audit type and scope

Follow the audit type selection logic in `commands/audit.md` Step 1 to parse `--full`/`--mini` flags from `$ARGUMENTS`, check `{config_default_audit_type}`, and ask the user if neither is set.

Follow `commands/shared/scope-parse.md` for remaining argument parsing, skip pattern enforcement, and trivial scope check.

### Step 2: Run initial audit

Follow `commands/shared/codex-call.md` for availability test and call pattern.

If Codex does not respond, fall back to a manual Claude audit per `commands/shared/fallback.md` and report the findings — but do not attempt the fix loop. The fix loop requires Codex to apply edits autonomously; without it, report what was found and ask the user to fix manually.

- **Command persona**: "You are a thorough code auditor. Report every issue with exact file:line locations."
- **Sandbox**: `read-only`
- **Approval-policy**: `never`

Use the audit prompts from `commands/audit.md` (full or mini, matching the chosen type). Run per file.

**Save the `threadId`** as `{audit_threadId}` for reuse in fix and verify steps.

Collect all findings into a structured audit report. Display it to the user.

If **no issues found** → report CLEAN and STOP.

### Step 3: Fix loop

**IMPORTANT**: Maximum **3 iterations** of the fix→verify cycle. After 3 rounds, stop and report remaining issues.

Set `iteration = 1`.

#### 3a: Ask before fixing

**Question 1 — Scope** (severity filter):

For a **full audit** (has Critical severity):
```
AskUserQuestion:
  question: "Found {N} issues ({critical} Critical, {high} High, {medium} Medium, {low} Low). Fix them?"
  header: "Fix scope"
  options:
    - label: "Fix all (Recommended)"
      description: "Fix all findings"
    - label: "Fix Critical + High only"
      description: "Only fix Critical and High severity issues"
    - label: "Stop here"
      description: "Keep the audit report, fix manually"
```

For a **mini audit** (uses High/Medium/Low only):
```
AskUserQuestion:
  question: "Found {N} issues ({high} High, {medium} Medium, {low} Low). Fix them?"
  header: "Fix scope"
  options:
    - label: "Fix all (Recommended)"
      description: "Fix all findings"
    - label: "Fix High only"
      description: "Only fix High severity issues"
    - label: "Stop here"
      description: "Keep the audit report, fix manually"
```

If "Stop here" → display final report and STOP.

**Question 2 — Who fixes**:

```
AskUserQuestion:
  question: "Who should fix these issues?"
  header: "Fixer"
  options:
    - label: "Claude (Recommended)"
      description: "Fix directly using Read/Edit — has full project context, precise edits"
    - label: "Codex"
      description: "Send to Codex for autonomous fixing — sandboxed, isolated"
```

Store as `{chosen_fixer}`.

#### 3b: Fix findings

##### If `{chosen_fixer}` is **Claude**:

1. For each finding in the filtered set:
   - Read the file, understand context, apply the smallest targeted fix via Edit
   - Fix all related locations if needed
2. Do NOT refactor surrounding code — only fix reported findings
3. Do NOT delete code unless the finding calls for removal (dead code, unused imports)
4. After fixing, run tests if a test runner is detected (check for `jest.config.*`, `vitest.config.*`, `pytest.ini`, `conftest.py`, `Cargo.toml` with `[dev-dependencies]`, `go.mod`, or a `test` script in `package.json`)
5. Show summary: `git diff --stat` + list of fixes applied

##### If `{chosen_fixer}` is **Codex**:

**Reuse the audit thread** via `codex-reply`:

```
mcp__codex-cli__codex-reply with:
  threadId: {audit_threadId}
  prompt: "Fix the following findings from your audit. For each finding, make the smallest targeted fix at the exact file:line location.

FINDINGS TO FIX:
{filtered findings in file:line | severity | finding | fix format}

RULES:
- Fix each finding at the exact location reported
- Make minimal, targeted changes — do not refactor surrounding code
- Do not delete code unless the finding specifically calls for removal
- After fixing, run the project test suite (npm test, pytest, go test ./..., cargo test — whichever is detected)
- Report: what you fixed, what you couldn't fix, and the test results"
```

**Fallback**: If `codex-reply` fails (thread expired), use a fresh `mcp__codex-cli__codex` call following `commands/shared/codex-call.md`:
- **Command persona**: "You are an autonomous code fixer. Fix every finding precisely at the reported location. Do not introduce new findings."
- **Sandbox**: `{chosen_sandbox}`

Update `{audit_threadId}` to the new threadId from whichever call succeeded.

Display summary: `git diff --stat` + Codex's fix report.

#### 3c: Verify fixes

**If `{chosen_fixer}` was Codex** — continue the same thread:

```
mcp__codex-cli__codex-reply with:
  threadId: {audit_threadId}
  prompt: "Verify whether the following findings have been fixed. Check each file at the exact location.

ORIGINAL FINDINGS:
{the findings sent for fixing}

For each finding report:
- FIXED — finding resolved, no new problems introduced
- NOT FIXED — finding still present (explain why)
- PARTIAL — partially addressed (explain what remains)
- REGRESSED — fix introduced a new problem (describe it)"
```

**If `{chosen_fixer}` was Claude** — use a fresh Codex call for independent verification:
- **Command persona**: "You are a verification auditor. Only check findings from the provided audit report."
- **Sandbox**: `read-only`

**Fallback**: If `codex-reply` fails, use a fresh call (same as Claude-fixer path).

#### 3d: Evaluate results

- **All FIXED** → proceed to Step 4
- **Issues remain (NOT FIXED / PARTIAL / REGRESSED)** and `iteration < 3`:
  - Increment `iteration`, show remaining issues, ask:
    ```
    AskUserQuestion:
      question: "{remaining} issues remain after round {iteration-1}. Try fixing again?"
      header: "Continue"
      options:
        - label: "Fix remaining issues (Recommended)"
          description: "Send unfixed issues to {chosen_fixer} for another attempt"
        - label: "Switch fixer"
          description: "Try the other fixer (Claude↔Codex) on remaining issues"
        - label: "Stop here"
          description: "Accept current state, fix remaining issues manually"
    ```
  - "Fix remaining" → go to **3b** with remaining issues (same fixer)
  - "Switch fixer" → flip `{chosen_fixer}`, go to **3b**. If switching TO Codex and sandbox is `danger-full-access`, re-confirm with the user before proceeding (same warning as initial sandbox confirmation).
  - "Stop here" → proceed to Step 4
- **iteration = 3** → proceed to Step 4

### Step 4: Final report

```markdown
# Audit Fix Report

**Date**: {today}
**Scope**: {what was audited}
**Audit type**: Full (9-dim) / Mini (5-dim)
**Fixer**: {Claude / Codex}
**Model**: {chosen_model} | **Effort**: {chosen_effort} | **Sandbox**: {chosen_sandbox}
**Thread ID**: `{audit_threadId}` _(use `/continue {audit_threadId}` to iterate further — Codex only)_
**Rounds**: {iteration count}

## Result: {ACCEPTED / PARTIAL / UNCHANGED}

## Summary

| Status | Count |
|--------|-------|
| Fixed | {n} |
| Not Fixed | {n} |
| Partial | {n} |
| Regressed | {n} |
| Total | {n} |

## Fixed Issues

| File:Line | Severity | Issue | Status |
|-----------|----------|-------|--------|
| ... | ... | ... | FIXED |

## Remaining Issues (if any)

| File:Line | Severity | Issue | Status | Notes |
|-----------|----------|-------|--------|-------|
| ... | ... | ... | NOT FIXED | {why} |

## Changes Made

{git diff --stat output}

## Next Steps

- Review changes: `git diff`
- Run tests: {project test command — npm test, pytest, go test ./..., cargo test}
- Commit: if satisfied with the fixes
- Revert: `git checkout .` to undo all changes
- Continue: `/continue {audit_threadId}` to address remaining issues
```

### Verdicts

- **ACCEPTED** — all issues fixed, verification passed
- **PARTIAL** — 1+ issues fixed, 1+ issues remain
- **UNCHANGED** — user chose to stop before fixing, or Codex couldn't fix anything
