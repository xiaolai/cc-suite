---
name: claude-plan
description: "Ask Claude Code to produce an implementation plan before you write code. Use when the task is complex, touches multiple files, or has unclear requirements. Claude returns a numbered step-by-step plan with file paths and interfaces — you implement it."
version: 0.2.0
---

# Claude Plan

Ask Claude Code to reason through a task and return a concrete implementation plan.

## When to Use

- Before implementing a non-trivial feature
- When the task touches multiple interconnected files and the right approach is unclear
- When asked to "get Claude to plan this" or "have Claude figure out the design"

## Call Pattern

### Step 1: Request a plan

```
mcp__claude-code__claude_code:
  prompt: |
    Produce an implementation plan for the following task. Do NOT write any code.
    Return a numbered plan only.

    TASK: {description of what needs to be built or changed}

    CONSTRAINTS:
    - {any constraints: language, framework, existing patterns to follow, etc.}

    For each step include:
    - What to do (imperative)
    - Which file(s) to create or modify (exact paths)
    - Key interfaces or data structures to define
    - Dependencies on prior steps

    At the end, list: risk areas, open questions, and recommended test scenarios.

    PROVENANCE NOTE: This planning request originates from OpenAI Codex. Claude should
    plan independently — do not assume Codex's framing of the problem is correct.
  cwd: {project working directory}
  effort: high
  permissionMode: plan
```

Save the returned `session_id` as `{plan_session_id}`.

### Step 2: Clarify (optional)

```
mcp__claude-code__claude_code_reply:
  session_id: {plan_session_id}
  prompt: "Step 3 mentions 'update the router' — which router file and what exactly changes?"
```

### Step 3: Implement the plan

After receiving the plan, implement each step. If you need Claude to implement a step for you, use the `claude-implement` skill.

## Output Format

Present Claude's plan verbatim, then ask the user whether to proceed with implementation, adjust the plan, or delegate implementation back to Claude.

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

- `permissionMode: plan` prevents accidental file writes — planning only
- `effort: high` is strongly recommended for accurate plans; shallow effort produces vague steps
- Include the files and directory listings most closely related to the task in the prompt for better accuracy

## Example Invocations

<example>
Context: A large migration needs a design agreed before any code is written.
user: "Work out how we'd move this API from REST to GraphQL before anyone touches the code."
assistant: "I'll ask claude-plan for a numbered plan with file paths and interfaces, so we settle the design before implementation starts."
</example>

<example>
Context: Requirements are ambiguous and the user wants the shape of the work first.
user: "I want multi-tenancy in this schema but I'm not sure what it touches."
assistant: "I'll invoke claude-plan to map the affected files and produce a step-by-step plan — that surfaces the scope before we commit to an approach."
</example>
