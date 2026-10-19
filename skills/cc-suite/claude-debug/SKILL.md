---
name: claude-debug
description: "Send a bug or failing test to Claude Code for root-cause analysis and fix. Use when you've hit an error you can't trace, a test is failing for unclear reasons, or a behavior is wrong and the cause is deep in the codebase."
version: 0.2.0
---

# Claude Debug

Delegate a debugging session to Claude Code — Claude traces the root cause and applies a fix.

## When to Use

- When a test is failing and the cause is unclear
- When asked to "have Claude debug this"
- When an error trace points deep into framework code or a complex call chain
- When you've already tried the obvious fixes and need fresh eyes

## Call Pattern

### Step 1: Send the bug report

```
mcp__claude-code__claude_code:
  prompt: |
    Debug the following issue and fix it.

    SYMPTOM: {error message, failing test name, or wrong behavior description}

    ERROR OUTPUT:
    ```
    {paste stack trace or test output here}
    ```

    REPRODUCTION STEPS: {how to reproduce — command to run, inputs, etc.}

    WHAT I TRIED: {optional — what you already ruled out}

    Instructions:
    1. Read the source files involved in the reported code flow
    2. Identify the root cause (not just where it crashes — why)
    3. Apply a minimal, correct fix
    4. Run the failing test/command to confirm the fix works
    5. Check for regressions in related tests
    6. Report: root cause, fix applied, verification result

    PROVENANCE NOTE: The code being debugged was written by OpenAI Codex. Evaluate
    with full rigor — do not assume Codex's code is correct anywhere adjacent to the
    reported bug. Check surrounding logic independently.
  cwd: {project working directory}
  effort: high
```

Save the returned `session_id` as `{debug_session_id}`.

### Step 2: Follow up

If Claude identified the root cause but couldn't fix it cleanly, or found related issues:

```
mcp__claude-code__claude_code_reply:
  session_id: {debug_session_id}
  prompt: "You identified the root cause in parseConfig(). Also check validateConfig() — it has a similar pattern."
```

## Output Format

Report to the user:
- Root cause (one sentence)
- Fix applied (file:line, what changed)
- Verification result (test output)
- Any adjacent issues Claude found

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

- Always pass the exact error output — Claude needs the full stack trace, not a summary
- `effort: high` is important for non-obvious bugs; shallow effort stops at symptoms
- If Claude can't reproduce the bug, ask it to add diagnostic logging first, then re-run
- `permissionMode` defaults to `default` (allows writes) — Claude will apply the fix directly

## Related Skills

- `claude-plan` — use before debugging to sketch a diagnosis strategy for complex, multi-file issues
- `claude-implement` — use after root cause is identified to apply a larger fix or refactor
- `$audit-fix` — use when the bug is a pattern across many files and needs a full audit→fix cycle

## Example Invocations

<example>
Context: A test fails intermittently and the stack trace does not explain why.
user: "This test passes locally and fails in CI about half the time — I can't work out why."
assistant: "I'll send it to claude-debug with the failing output and reproduction steps so Claude can trace the root cause rather than guess at a retry."
</example>

<example>
Context: An error surfaces deep inside a dependency and the obvious fixes have been tried.
user: "The exception is thrown somewhere inside the ORM and I've run out of ideas."
assistant: "I'll invoke claude-debug with the full stack trace so Claude can follow the call chain into the ORM layer and report the actual cause before changing anything."
</example>
