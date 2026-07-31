---
name: verify
description: "Ask Claude Code to verify that a list of reported issues has been fixed. Continues the same Claude session from a prior audit if session_id is available, so Claude has full context of what it flagged. Returns FIXED / NOT FIXED / PARTIAL / REGRESSED per issue."
version: 0.2.3
---

# Verify

Ask Claude Code to check whether previously reported audit findings have been resolved. Claude re-reads the files at the reported locations and renders a verdict per issue. Codex provides the issue list; Claude provides the verdict.

## When to Use

- After Codex has applied fixes from a `$audit` run
- To confirm a manual fix was applied at the correct location
- As the final step of a `$audit-fix` cycle

## Arguments

| Argument | Effect |
|----------|--------|
| `session_id` | Claude session from the prior `$audit` — reuses full audit context |
| issue list | Paste or reference the findings to verify (file:line + description) |

## Call Pattern

### Option A: Continue the audit session (preferred)

If `{audit_session_id}` is available from a prior `$audit` or `$audit-fix` run:

```
mcp__claude-code__claude_code_reply:
  session_id: {audit_session_id}
  prompt: |
    The following issues from your audit have been addressed. Verify each one.

    ISSUES TO VERIFY:
    {paste findings in "file:line | severity | issue description" format}

    For each issue report one of:
    - FIXED — issue resolved fully, no new problems introduced
    - NOT FIXED — issue still present at the reported location (explain why)
    - PARTIAL — partially addressed; describe what remains
    - REGRESSED — fix introduced a new problem (describe it)

    Read the files at the reported locations. Do not assume a fix is correct
    without reading the current code.
```

### Option B: Fresh verification session

When no prior session is available:

```
mcp__claude-code__claude_code:
  prompt: |
    Verify whether the following issues have been fixed.

    ISSUES TO VERIFY:
    {paste findings in "file:line | severity | issue description" format}

    For each issue:
    1. Read the file at the reported location
    2. Check if the issue is resolved
    3. Report: FIXED / NOT FIXED / PARTIAL / REGRESSED

    For NOT FIXED and PARTIAL: explain what is still wrong.
    For REGRESSED: describe the new problem introduced.

    Apply independent judgment — do not accept surface-level changes that
    mask the underlying issue.
  cwd: {project working directory}
  effort: high
  permissionMode: plan
```

Save the returned `session_id` as `{verify_session_id}`.

## Output Format

| File:Line | Severity | Issue | Verdict | Notes |
|-----------|----------|-------|---------|-------|
| ... | High | ... | FIXED | — |
| ... | High | ... | NOT FIXED | condition still inverted |
| ... | Medium | ... | PARTIAL | null check added but empty-string case missing |

**Result**: N fixed, N not fixed, N partial, N regressed

## Notes

- Always prefer Option A when a session is available — Claude retains full audit context and can make more precise verdicts
- If all issues are FIXED, report success and suggest committing
- If any are NOT FIXED or REGRESSED, feed those back into `$audit-fix` or fix manually

## Example Invocations

<example>
Context: Codex has applied fixes for issues Claude raised in an earlier audit.
user: "Codex says it fixed everything from the last review — is that true?"
assistant: "I'll continue the prior Claude session through verify, so Claude checks its own findings and returns FIXED / NOT FIXED / PARTIAL / REGRESSED for each one."
</example>

<example>
Context: There is a findings list from a previous day but no session id to resume.
user: "Here's yesterday's findings list — check whether these are actually resolved now."
assistant: "No session_id is available, so I'll start a fresh verify session and have Claude re-read each reported location before giving a verdict."
</example>
