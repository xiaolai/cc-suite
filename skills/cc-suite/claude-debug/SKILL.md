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

## Notes

- Always pass the exact error output — Claude needs the full stack trace, not a summary
- `effort: high` is important for non-obvious bugs; shallow effort stops at symptoms
- If Claude can't reproduce the bug, ask it to add diagnostic logging first, then re-run
- `permissionMode` defaults to `default` (allows writes) — Claude will apply the fix directly
