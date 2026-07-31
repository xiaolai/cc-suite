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
