---
name: bug-analyze
description: Root cause analysis for user-described bugs using Codex
argument-hint: "<bug description> [--background | --wait]"
---

## Bug Description

```text
$ARGUMENTS
```

## Model & Settings Selection

Follow the instructions in `commands/shared/model-selection.md` to discover available models and present choices.

- **Recommended model**: first available from preflight
- **Recommended reasoning effort**: `high`
- **Include sandbox question**: No (bug analysis always uses `read-only`)

## Workflow

### Step 0: Parse Execution Mode

Parse `$ARGUMENTS` for `--background` or `--wait` flags (remove the flag from remaining arguments):

| Flag | Mode |
|------|------|
| `--background` | Background — spawn detached Codex runner, return job ID |
| `--wait` | Foreground (explicit) — same as default |
| Neither | Foreground (default) — run inline, block until complete |

### Step 1: Parse Bug Description

Extract from `$ARGUMENTS`:
- **Symptoms**: What behavior is observed?
- **Expected**: What should happen instead?
- **Context**: When/where does it occur?
- **Keywords**: Key terms to search for

If `$ARGUMENTS` is empty or too vague to extract actionable keywords, use AskUserQuestion to ask the user for a more specific bug description before proceeding.

### Step 2: Reconnaissance

Identify scope using symptoms and keywords:

1. **Search for related code**:
   - Use Grep to find keywords from bug description
   - Use Glob to find file patterns matching the bug description
   - Identify entry points and data flow paths

2. **Map the affected area**:
   - Which files/functions are involved?
   - What is the data flow?
   - What are the dependencies?

If the bug description references specific files or paths, use `commands/shared/scope-parse.md` for skip pattern enforcement against `{config_skip_patterns}`.

### Step 3: Deep Analysis with Codex

If `--background` mode was selected, follow the **Background Execution** section in `commands/shared/codex-call.md`. Build the prompt as described below, then hand off to the background runner with `--kind bug-analyze`.

Follow `commands/shared/codex-call.md` for availability test, call pattern, and **Job Tracking**.

- **Command persona**: "You are a root cause analyst. Trace bugs to their origin."
- **Sandbox**: `read-only`
- **Approval-policy**: `never`

For each affected file (files matching Grep results, files in the call chain, up to 10 files max):

```
prompt: "Analyze {filename} for potential causes of this bug:

BUG DESCRIPTION: {user's bug description}

Investigate:

1. **Logic Flow Analysis**
   - Trace execution path related to symptoms
   - Identify conditional branches that could cause the issue
   - Check loop conditions and termination
   - Look for off-by-one errors or boundary issues

2. **State Management**
   - Race conditions or timing issues
   - Stale state or cache problems
   - Mutation of shared state, async/await issues

3. **Data Flow**
   - Data transformations, type coercion
   - Null/undefined propagation
   - Truncation or overflow possibilities

4. **Error Handling**
   - Swallowed exceptions, missing error cases
   - Incomplete cleanup on failure

5. **Edge Cases**
   - Empty inputs, null/zero values, boundary conditions
   - Concurrent access, resource exhaustion

Report findings as:
- LIKELY CAUSE: {description} at {file:line}
- CONTRIBUTING FACTOR: {description} at {file:line}
- RELATED RISK: {description} at {file:line}"
```

### Step 4: Root Cause Identification

After analyzing all affected files:

1. **Correlate findings** — which issues appear across multiple files?
2. **Trace causality** — what triggers the chain of events?
3. **Identify the root** — what single change would prevent the bug?

### Step 5: Related Bug Detection

```
prompt: "Based on the root cause pattern found ({root cause}),
search the codebase for similar patterns that could cause related bugs.

Look for:
1. Same anti-pattern in other files
2. Similar logic that shares the same flaw
3. Code that depends on the buggy behavior
4. Copy-pasted code with the same issue

Report each as:
- RELATED BUG RISK: {file:line} - {description}"
```

### Step 6: Report

```markdown
# Bug Analysis Report

**Date**: {today}
**Bug**: {summary of user's description}
**Model**: {chosen_model} | **Effort**: {chosen_effort}
**Thread ID**: `{threadId}` _(use `/continue {threadId}` to drill deeper)_

## Executive Summary

**Root Cause**: {one-sentence description}
**Confidence**: High / Medium / Low
**Complexity**: Simple fix / Moderate / Requires refactoring

## Symptoms Explained

{How the root cause manifests as the observed symptoms}

## Root Cause Analysis

### Primary Cause
| Location | Description | Evidence |
|----------|-------------|----------|
| {file:line} | {what's wrong} | {why we know} |

### Contributing Factors
| Location | Description | Impact |
|----------|-------------|--------|
| {file:line} | {issue} | {how it contributes} |

## Data/Logic Flow

(Trace the data/execution flow step-by-step from the triggering input to the point of failure)

## Related Bugs Found

| Location | Risk Level | Description |
|----------|------------|-------------|
| {file:line} | High/Med/Low | {potential bug} |

## Recommended Fix

### Immediate Fix
1. {specific action at file:line}

### Proper Fix (if different)
(Describe the fuller fix when the immediate fix is a patch — what should be refactored and why)

### Test Cases to Add
1. {test case description}

## Prevention

- {coding practice}
- {review checklist item}
- {test strategy}
```

### Step 7: Fallback

Follow `commands/shared/fallback.md`. Use Grep to find related patterns:

- Key function/variable names from bug description
- Error handling: `catch|except|error`
- State mutations: `setState|set|update|mutate`
