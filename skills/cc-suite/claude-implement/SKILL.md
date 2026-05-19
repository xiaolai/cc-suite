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

## Notes

- Claude operates with full read/write access in the working directory by default
- If the task is sensitive or you want a dry-run first, use `claude-plan` skill before this one
- `effort: high` ensures thorough implementation; lower effort may skip edge cases
- Pass `maxBudgetUsd` if you need to cap spend on large implementations
