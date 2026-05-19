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

## Notes

- `permissionMode: plan` prevents accidental file writes — planning only
- `effort: high` is strongly recommended for accurate plans; shallow effort produces vague steps
- Include the files and directory listings most closely related to the task in the prompt for better accuracy
