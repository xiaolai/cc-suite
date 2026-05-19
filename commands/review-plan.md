---
name: review-plan
description: Send a plan to Codex for architectural review — checks consistency, completeness, feasibility, ambiguity, and risk
argument-hint: "[plan-file] [--background | --wait]"
---

## User Input

```text
$ARGUMENTS
```

## When to Use

Use `/review-plan` when:
- A plan will drive more than 2 hours of implementation work
- The plan touches multiple subsystems or shared interfaces
- You want an independent read on feasibility before delegating to Codex
- A prior implementation attempt failed and you suspect the plan was at fault

## What This Does

Sends a plan document to Codex running in an isolated context for independent review. Codex reads the plan (and optional context files), then evaluates it across 5 dimensions that matter for plans — not code quality, but **buildability**.

## Model & Settings Selection

Follow the instructions in `commands/shared/model-selection.md` to discover available models and present choices.

- **Recommended model**: first available from preflight
- **Recommended reasoning effort**: `high`
- **Include sandbox question**: No (plan review always uses `read-only`)

## Workflow

### Step 0: Parse Execution Mode

Parse `$ARGUMENTS` for `--background` or `--wait` flags (remove the flag from remaining arguments):

| Flag | Mode |
|------|------|
| `--background` | Background — spawn detached Codex runner, return job ID |
| `--wait` | Foreground (explicit) — same as default |
| Neither | Foreground (default) — run inline, block until complete |

### Step 1: Determine Scope

Parse `$ARGUMENTS` to find the plan:

| Input | Interpretation |
|-------|----------------|
| (empty) | Look for `dev-memo/plan.md`, then `plan.md`, then ask |
| `path/to/plan.md` | Use that file |
| `path/to/plan.md +context1.md +context2.md` | Plan file + additional context files |

Read the plan file. If it references other documents (design docs, specs, AGENTS.md), read those too — they become context.

### Step 2: Send Plan for Review

If `--background` mode was selected, follow the **Background Execution** section in `commands/shared/codex-call.md`. Build the prompt as described below, then hand off to the background runner with `--kind review-plan`.

Follow `commands/shared/codex-call.md` for availability test, call pattern, and **Job Tracking**.

- **Command persona**: "You are an architecture reviewer evaluating plan feasibility."
- **Sandbox**: `read-only`
- **Approval-policy**: `on-failure` (intentional divergence from `never` — plan review benefits from a human gate when Codex signals a problem, since a bad plan causes downstream rework)

Send a SINGLE Codex call with the full plan (no per-file splitting):

```
prompt: |
  Read these files, then evaluate the plan across all 5 dimensions below.
  Be critical — flag anything that would cause problems during implementation.

  Files to read:
  - {plan_file}
  - {additional context file 1 (if provided)}
  - {additional context file 2 (if provided)}

  ## Dimension 1: Internal Consistency
  Do decisions contradict each other? (conflicting requirements, data model mismatches, dependency inversions)

  ## Dimension 2: Completeness
  What's missing? (error paths, startup/shutdown, edge cases, migration, configuration)

  ## Dimension 3: Feasibility
  Can this be built as described? (API correctness, technology mismatches, performance assumptions, undeclared dependencies)

  ## Dimension 4: Ambiguity
  Where would an implementer get stuck? (vague specs, undefined behavior, multiple interpretations, missing examples)

  ## Dimension 5: Risk & Sequencing
  What's the hardest part, and is the build order correct? (high-risk items buried late, unacknowledged dependencies, single points of failure)

  ## Output Format
  For each dimension:
  **[Dimension N: Name]**
  | # | Severity | Finding | Location | Recommendation |
  |---|----------|---------|----------|----------------|

  Then:
  **Overall Verdict**: READY TO BUILD / NEEDS REVISION / MAJOR GAPS
  **Top 3 Risks** (ordered by impact)
  **Strongest aspects** of the plan
```

### Step 3: Present Findings

Display Codex's review. Add your own assessment if you disagree or notice something Codex missed.

```markdown
# Plan Review

**Plan**: {filename}
**Model**: {chosen_model} | **Effort**: {chosen_effort}
**Thread ID**: `{threadId}` _(use `/continue {threadId}` to iterate on findings)_
**Verdict**: READY TO BUILD / NEEDS REVISION / MAJOR GAPS

## Findings by Dimension

### 1. Internal Consistency
{findings table or "No issues found"}

### 2. Completeness
{findings table}

### 3. Feasibility
{findings table}

### 4. Ambiguity
{findings table}

### 5. Risk & Sequencing
{findings table}

## Top Risks
1. ...
2. ...
3. ...

## Strengths
- ...

## Additional Notes
(Note any observations not captured in the dimension tables — e.g., assumptions the reviewer found implicit but not stated, external dependencies not in scope, or tensions between stated requirements)
```

### Step 4: Fallback

Follow `commands/shared/fallback.md`.

1. Read the plan using the Read tool
2. Walk through all 5 dimensions as described above
3. Cross-reference: for each decision, check if it conflicts with any other
4. Trace data flow: follow a message from input to output — does every step exist?
5. Report in the same format
