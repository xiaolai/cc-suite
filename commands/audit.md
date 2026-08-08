---
description: Code auditor — full 9-dimension or fast 5-dimension audit with --full/--mini flag
argument-hint: "[scope] [--full | --mini] [--background | --wait]"
---

## User Input

```text
$ARGUMENTS
```

## Model & Settings Selection

Follow the instructions in `commands/shared/model-selection.md` to discover available models and present choices.

- **Recommended model**: first available from preflight (full) / second available (mini)
- **Recommended reasoning effort**: `high` (full) / `medium` (mini)
- **Include sandbox question**: No (audits always use `read-only`)

## Workflow

### Step 0: Parse Execution Mode

Parse `$ARGUMENTS` for `--background` or `--wait` flags (remove the flag from remaining arguments):

| Flag | Mode |
|------|------|
| `--background` | Background — spawn detached Codex runner, return job ID |
| `--wait` | Foreground (explicit) — same as default |
| Neither | Foreground (default) — run inline, block until complete |

### Step 1: Determine Audit Type

Parse `$ARGUMENTS` for `--full` or `--mini` flags (remove the flag from scope arguments):

| Condition | Audit type |
|-----------|------------|
| `--full` flag present | Full (9 dimensions) |
| `--mini` flag present | Mini (5 dimensions) |
| `{config_default_audit_type}` is set | Use config value |
| Neither flag nor config | Ask the user (below) |

If asking:

```
AskUserQuestion:
  question: "Which audit depth?"
  header: "Audit type"
  options:
    - label: "Mini (5 dimensions) (Recommended)"
      description: "Logic, duplication, dead code, refactoring debt, shortcuts — fast"
    - label: "Full (9 dimensions)"
      description: "Adds security, performance, compliance, dependencies, documentation — thorough"
```

Adjust recommended model/effort based on chosen type (full → first available model/`high`, mini → second available model/`medium`). If only one model is available, use it for both audit types.

### Step 2: Scope & Files

Follow `commands/shared/scope-parse.md` to parse remaining arguments, enforce skip patterns, and check for trivial scope.

Identify:
- Technology stack and languages
- Project structure and organization
- Entry points (main, routes, controllers)
- High-risk areas (auth, payments, data processing)

Skip non-code files (*.md, *.json, *.yaml, *.css, images) unless specifically requested.

For **mini audits**, also skip test files by default:
- `*.test.*`, `*.spec.*`, `*_test.*`, `*_spec.*`
- Files under `__tests__/`, `test/`, `tests/`, `spec/` directories
- Test helpers/fixtures: `**/fixtures/**`, `**/mocks/**`, `**/stubs/**`

This is because mini audits focus on production code quality; test files tend to have intentional duplication and simpler structure that would generate noise.

For **full audits**, include test files — they are needed for Dimension 7 (Testing & Validation).

### Step 3: Audit Execution

If `--background` mode was selected, follow the **Background Execution** section in `commands/shared/codex-call.md` instead of the inline execution below. Build the prompt as described in this step, then hand off to the background runner with `--kind audit`.

Follow `commands/shared/codex-call.md` for the call pattern (CLI runner) and **Job Tracking**.

- **Command persona**: "You are a thorough security and code quality auditor." (full) / "You are a fast code quality reviewer focused on logic, duplication, and dead code." (mini)
- **Sandbox**: `read-only`
- **Approval-policy**: `never`

**Batching**: If scope contains more than 20 code files, batch them into groups of 10 and process each batch sequentially. Display progress between batches: "Auditing batch {N}/{total}..."

For each code file, send the dimension prompt matching the chosen audit type:

#### Mini Audit (5 dimensions)

```
"Mini audit {filename} — focus on code quality:

**Dimension 1: Logic & Correctness**
- Race conditions, edge cases, off-by-one errors
- Async issues: missing await, unhandled promises
- State mutations: unexpected side effects, stale closures

**Dimension 2: Duplication**
- Copy-paste code, repeated patterns, DRY violations
- Near-duplicates: functions differing by 1-2 lines

**Dimension 3: Dead Code**
- Unused imports, unreachable branches, commented-out code
- Unused variables, orphaned functions

**Dimension 4: Refactoring Debt**
- Long functions (>30 lines), deep nesting (>3 levels)
- Unclear names, missing abstractions, god objects

**Dimension 5: Shortcuts & Patches**
- TODOs left behind, hardcoded values, workarounds
- Incomplete error handling, quick fixes, backward-compat shims

Report each issue as: file:line | dimension | severity(High/Medium/Low) | issue | fix"
```

#### Full Audit (9 dimensions)

```
"Audit {filename} across all 9 dimensions:

**Dimension 1: Redundant & Low-Value Code**
- Dead code: unreachable paths, unused functions/imports, commented-out code
- Duplicate code: copy-paste patterns, repeated logic
- Useless code: unused variables, no-op operations, empty catch blocks

**Dimension 2: Security & Risk Management**
- Input validation: SQL injection, XSS, command injection, path traversal
- Sensitive data: hard-coded secrets, logged credentials, unencrypted data
- Auth/authz: weak passwords, broken access control, session issues
- Cryptography: weak algorithms, improper key management

**Dimension 3: Code Correctness & Reliability**
- Logic errors: edge cases, boundary conditions, race conditions
- Runtime risks: null dereference, array bounds, division by zero
- Error handling: missing try-catch, swallowed exceptions, silent failures
- Resource leaks: unclosed files, connections, memory

**Dimension 4: Compliance & Standards**
- Coding standards: naming conventions, code structure
- Framework conventions: proper API usage, deprecated features
- License compliance: GPL, MIT, Apache compatibility

**Dimension 5: Maintainability & Readability**
- Complexity: cyclomatic complexity >15, nested conditionals
- Size: functions >50 lines, classes >500 lines
- Magic numbers, DRY violations

**Dimension 6: Performance & Efficiency**
- Algorithm efficiency: O(n^2) that could be O(n log n)
- Database: N+1 queries, missing indexes, no pagination
- Memory: excessive allocations; I/O: blocking operations

**Dimension 7: Testing & Validation**
- Coverage gaps: critical paths without tests
- Test quality: flaky tests, missing edge cases, missing integration tests

**Dimension 8: Dependency & Environment Safety**
- Known CVEs, outdated/abandoned packages
- Config security: secrets in configs, missing .gitignore

**Dimension 9: Documentation & Knowledge Transfer**
- Missing docs: undocumented public APIs
- Outdated comments, incomplete setup instructions

Report each issue as: file:line | severity(Critical/High/Medium/Low) | dimension | issue | fix"
```

### Step 4: Report

Before rendering the report, if the audit produced at least one finding, write the merged findings to `.cc-suite/audits/audit-{YYYYMMDD-HHMMSS}-findings.md` (create the directory if missing) using the findings-file format from `commands/audit-fix.md` Step 2b, with every row's Status set to `open`. Mention the path in the report header. If the write fails, display the findings inline, note that no findings file was persisted, and continue — the report itself is the primary output. A durable findings file survives context compaction in long sessions and lets a later fix pass start from the audit's exact output instead of re-auditing.

#### Mini Report

```markdown
# Mini Audit Report

**Date**: {today}
**Scope**: {what was audited}
**Files**: {count}
**Model**: {chosen_model} | **Effort**: {chosen_effort}
**Thread ID**: `{threadId}` _(use `/continue {threadId}` to iterate on findings)_
**Verdict**: CLEAN / NEEDS ATTENTION / NEEDS WORK

## Findings

| File:Line | Dim | Severity | Issue | Fix |
|-----------|-----|----------|-------|-----|
| ... | ... | ... | ... | ... |

## Summary by Dimension

| Dimension | High | Medium | Low |
|-----------|------|--------|-----|
| 1. Logic & Correctness | X | X | X |
| 2. Duplication | X | X | X |
| 3. Dead Code | X | X | X |
| 4. Refactoring Debt | X | X | X |
| 5. Shortcuts & Patches | X | X | X |

## Action Items

1. **[High]** {action} - {file:line}
2. ...

## Notes

- For security/performance/dependency audits, run `/audit --full`
- For verification after fixes, run `/verify`
```

#### Full Report

```markdown
# Audit Report

**Date**: {today}
**Scope**: {what was audited}
**Files**: {count}
**Model**: {chosen_model} | **Effort**: {chosen_effort}
**Thread ID**: `{threadId}` _(use `/continue {threadId}` to iterate on findings)_

## Executive Summary

**Overall Risk Score**: Critical / High / Medium / Low

| Dimension | Critical | High | Medium | Low |
|-----------|----------|------|--------|-----|
| 1. Redundant Code | X | X | X | X |
| 2. Security | X | X | X | X |
| 3. Correctness | X | X | X | X |
| 4. Compliance | X | X | X | X |
| 5. Maintainability | X | X | X | X |
| 6. Performance | X | X | X | X |
| 7. Testing | X | X | X | X |
| 8. Dependencies | X | X | X | X |
| 9. Documentation | X | X | X | X |

**Verdict**: PASS / NEEDS WORK / BLOCKED

## Findings by Dimension

### Dimension 1: Redundant & Low-Value Code
| File:Line | Severity | Issue | Fix |
|-----------|----------|-------|-----|
| ... | ... | ... | ... |

### Dimension 2: Security & Risk Management
| File:Line | Severity | Issue | Fix |
|-----------|----------|-------|-----|

### Dimension 3: Code Correctness & Reliability
| File:Line | Severity | Issue | Fix |
|-----------|----------|-------|-----|

### Dimension 4: Compliance & Standards
| File:Line | Severity | Issue | Fix |
|-----------|----------|-------|-----|

### Dimension 5: Maintainability & Readability
| File:Line | Severity | Issue | Fix |
|-----------|----------|-------|-----|

### Dimension 6: Performance & Efficiency
| File:Line | Severity | Issue | Fix |
|-----------|----------|-------|-----|

### Dimension 7: Testing & Validation
| File:Line | Severity | Issue | Fix |
|-----------|----------|-------|-----|

### Dimension 8: Dependency & Environment Safety
| File:Line | Severity | Issue | Fix |
|-----------|----------|-------|-----|

### Dimension 9: Documentation & Knowledge Transfer
| File:Line | Severity | Issue | Fix |
|-----------|----------|-------|-----|

## Top Priority Actions

1. **[Critical]** {action} - {file:line}
2. **[High]** {action} - {file:line}

## Positive Observations
- (note any well-structured code patterns or commendable practices found)
```

### Step 5: Fallback

Follow `commands/shared/fallback.md`. Use Grep to search for common issues:

- Dead code markers: `TODO|FIXME|HACK|XXX|DEPRECATED`
- Security patterns: `password|api_key|secret|token|eval|exec|innerHTML`
- Error handling: `except:|catch.*{}|\.catch\(\)`
- Shortcut indicators: `workaround|temporary|quick fix`
