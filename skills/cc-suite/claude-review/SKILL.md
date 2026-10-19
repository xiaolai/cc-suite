---
name: claude-review
description: "Delegate a code review task to Claude Code via the claude_code MCP tool. Use when you want Claude's judgment on architecture, security, correctness, test coverage, or code quality for files you've just written or modified."
version: 0.2.0
---

# Claude Review

Delegate a code review to Claude Code and get back structured findings.

## When to Use

- After writing or modifying code and wanting a second opinion
- When asked to "get Claude to review this"
- When a review requires deep context that would benefit from a fresh Claude session

## Call Pattern

### Step 1: Start a review

Call `claude_code` with a structured review prompt:

```
mcp__claude-code__claude_code:
  prompt: |
    Review the following code for correctness, security, and quality.

    SCOPE: {files or description of what to review}

    Evaluate:
    1. Correctness — logic errors, edge cases, off-by-one, race conditions
    2. Security — injection, auth bypass, data exposure, input validation
    3. Quality — readability, maintainability, test coverage, naming
    4. Architecture — coupling, abstraction leaks, layer violations

    For each finding report:
    - File:line
    - Severity: Critical / High / Medium / Low
    - Category
    - Issue description
    - Suggested fix

    PROVENANCE NOTE: The code being reviewed was written by OpenAI Codex. Evaluate
    with full rigor — do not defer to it. Apply independent judgment on every finding.
  cwd: {project working directory}
  effort: high
  permissionMode: plan
```

Save the returned `session_id` as `{review_session_id}`.

### Step 2: Follow up (optional)

To ask about specific findings or request deeper analysis on a section:

```
mcp__claude-code__claude_code_reply:
  session_id: {review_session_id}
  prompt: "Expand on finding #3 — what's the exact attack vector and what's the minimal fix?"
```

## Output Format

Display the review findings in a structured table:

| File:Line | Severity | Category | Issue | Fix |
|-----------|----------|----------|-------|-----|
| ... | Critical | Security | ... | ... |

Follow with a summary count by severity and a recommended action (fix now vs fix later vs acceptable risk).

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

- `permissionMode: plan` prevents Claude from modifying files — review is read-only
- Set `effort: high` for thorough analysis; use `medium` for quick spot-checks
- Pass `cwd` to anchor relative file paths in findings
- If the project has a test suite, mention it in the prompt so Claude can assess coverage gaps

## Related Skills

- `claude-debug` — use when findings point to a specific bug that needs root-cause tracing
- `claude-implement` — use after review to have Claude apply the suggested fixes autonomously
- `$audit-fix` — use when review reveals a recurring pattern that needs a systematic fix cycle

## Example Invocations

<example>
Context: Auth code was just modified and the user wants a second opinion focused on security.
user: "Look over the auth changes I just made — mainly worried about security."
assistant: "I'll delegate to claude-review with security as the lead dimension, alongside correctness and architecture."
</example>

<example>
Context: The user wants a cold read of a diff, not the opinion of whoever wrote it.
user: "Get a fresh pair of eyes on this PR's test coverage."
assistant: "I'll start a claude-review session so Claude reads the diff without prior context and reports structured findings on coverage."
</example>
