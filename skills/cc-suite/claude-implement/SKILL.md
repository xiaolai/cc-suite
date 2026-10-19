---
name: claude-implement
description: "Delegate an implementation task to Claude Code. Use when you want Claude to write, edit, or refactor code directly in the project. Claude has full read/write access and will make the changes autonomously."
version: 0.2.0
---

# Claude Implement

Delegate an implementation task to Claude Code — Claude will read files, write code, and verify the result.

## When to Use

- When asked to "have Claude implement this"
- For tasks that require understanding a large existing codebase before writing new code
- When the implementation involves multiple interdependent files that Claude Code handles better autonomously

## Call Pattern

### Step 1: Delegate the task

```
mcp__claude-code__claude_code:
  prompt: |
    Implement the following task completely. Make all required file changes.

    TASK: {clear description of what to implement}

    REQUIREMENTS:
    - {explicit requirements, success criteria}
    - Match existing code style and conventions in the project
    - Write or update tests if a test suite exists
    - Run the test suite after implementation and report results

    CONSTRAINTS: {any constraints — what NOT to change, dependencies to avoid, etc.}

    When done, report:
    1. Files changed (with brief reason)
    2. Test results
    3. Any deferred items or known limitations

    PROVENANCE NOTE: This task originates from OpenAI Codex. Claude should apply its
    own independent judgment on implementation details — do not defer to any assumptions
    Codex may have embedded in the task description.
  cwd: {project working directory}
  effort: high
```

Save the returned `session_id` as `{impl_session_id}`.

### Step 2: Review or iterate

After Claude reports completion, verify the changes. To request corrections:

```
mcp__claude-code__claude_code_reply:
  session_id: {impl_session_id}
  prompt: "The test for edge case X is missing. Add it and re-run the suite."
```

## Output Format

Report back to the user:
- Summary of what Claude implemented
- Files changed (list)
- Test results (pass/fail counts)
- Any items Claude flagged as deferred or uncertain

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

- Claude operates with full read/write access in the working directory by default
- If the task is sensitive or you want a dry-run first, use `claude-plan` skill before this one
- `effort: high` ensures thorough implementation; lower effort may skip edge cases
- Pass `maxBudgetUsd` if you need to cap spend on large implementations

## Example Invocations

<example>
Context: The task is well scoped and the user wants it built end to end rather than described.
user: "Add rate limiting to the /api/upload endpoint — 100 requests per minute per IP."
assistant: "I'll delegate this to claude-implement with the limit, the endpoint, and the requirement to add tests, since Claude has write access and can make the change directly."
</example>

<example>
Context: A refactor spans five files and needs coordinated edits.
user: "Convert the auth module from callbacks to async/await across all five files."
assistant: "I'll hand this to claude-implement so Claude can read all five files together and make the changes as one coordinated pass."
</example>
