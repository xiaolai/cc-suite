---
name: verify
description: Verification auditor — confirms fixes from a previous audit report
argument-hint: "<audit-report-file>"
---

## User Input

```text
$ARGUMENTS
```

## Model & Settings Selection

Follow the instructions in `commands/shared/model-selection.md` to discover available models and present choices.

- **Recommended model**: second available from preflight (verification needs less power). If only one model is available, use it.
- **Recommended reasoning effort**: `medium`
- **Include sandbox question**: No (verification always uses `read-only`)

## Workflow

**CRITICAL**: This command verifies fixes from a PREVIOUS audit. It does NOT discover new issues.

### Step 1: Input Parsing

`$ARGUMENTS` should contain or reference the previous audit report:
- If empty: Look for recent `audit-*.md` file in current directory
- If file path: Read that audit report
- If contains "Critical Issues": Use as inline report

If no audit report found:
```
No previous audit report found.

Options:
1. Run /audit first to generate baseline
2. Provide report: /verify audit-2025-11-18.md
3. Paste inline: /verify [audit report text]
```
And STOP.

**Note**: The audit report may contain 5 dimensions (mini audit) or 9 dimensions (full audit). Verify only the dimensions that appear in the report.

### Step 2: Verify with Codex

Follow `commands/shared/codex-call.md` for availability test and call pattern.

- **Command persona**: "You are a verification auditor. Only check issues from a previous audit report."
- **Sandbox**: `read-only`
- **Approval-policy**: `never`

```
prompt: "Your ONLY job is to confirm fixes from a previous audit.

## Previous Audit Report
{AUDIT_REPORT_CONTENT}

## Your Mission

1. **Extract Issue Checklist by Dimension**:
   Parse all issues organized by whatever dimensions appear in the audit report.
   Full audits have 9 dimensions; mini audits have 5. Only verify what's present.

2. **Verify Each Issue**:
   For each issue from the report:
   - Read the file at the exact location
   - Check if the issue still exists
   - Mark status:
     - FIXED — Issue resolved properly
     - NOT FIXED — Issue still present
     - PARTIAL — Partially addressed
     - MOVED — Code relocated, verify new location

3. **Quick Spot Check** (5 min max):
   - Only check files that were modified
   - Look for syntax errors, broken imports, type errors, or runtime exceptions introduced by fixes
   - DO NOT run comprehensive scan

## Requirements
- ONLY verify issues from the audit report
- Do NOT discover new issues systematically
- Be fast (2-10 minutes)
- Clear pass/fail per issue"
```

### Step 3: Report

```markdown
# Verification Report

**Date**: {today}
**Original Audit**: {audit date/file}
**Model**: {chosen_model} | **Effort**: {chosen_effort}
**Thread ID**: `{threadId}` _(use `/continue {threadId}` to iterate on findings)_
**Status**: PASSED / PARTIAL / FAILED

## Summary by Dimension

| Dimension | Fixed | Not Fixed | Partial | Total |
|-----------|-------|-----------|---------|-------|
| {for each dimension in report} | X | X | X | X |
| **TOTAL** | **X** | **X** | **X** | **X** |

## Verification Details

{For each dimension present:}

### {Dimension Name}
| Issue | File:Line | Status | Notes |
|-------|-----------|--------|-------|
| ... | ... | ... | ... |

## Remaining Issues (Not Fixed)

| Priority | Dimension | Issue | File:Line |
|----------|-----------|-------|-----------|
| ... | ... | ... | ... |

## New Issues Introduced (if any)

| Severity | Dimension | Issue | File:Line |
|----------|-----------|-------|-----------|
| ... | ... | ... | ... |

## Verdict

{PASSED / PARTIAL / FAILED}

## Next Steps
{What needs to be done if not passed}
```

### Step 4: Fallback

Follow `commands/shared/fallback.md`.

1. Parse the audit report to extract all issues by dimension
2. Read each file at the specified lines
3. Check if the issue still exists — mark FIXED, NOT FIXED, PARTIAL, or MOVED
4. Report in the same format as Step 3
