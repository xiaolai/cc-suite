---
name: audit
description: "Ask Claude Code to audit a file or set of files and return structured findings. Claude reads the code with fresh eyes and independent judgment — Codex does not self-review. Supports mini (5-dimension) and full (9-dimension) depth."
version: 0.2.3
---

# Audit

Delegate an audit to Claude Code. Claude inspects the specified scope and returns a structured findings table. Codex does not fix anything — use `$audit-fix` for the full cycle.

## When to Use

- After writing a feature and wanting an independent quality check
- Before a commit or pull request
- When asked to "have Claude audit this"
- As the first step of a manual fix cycle

## Arguments

| Argument | Default | Effect |
|----------|---------|--------|
| `--full` | off | 9-dimension audit (adds security, performance, compliance, deps, docs) |
| `--mini` | on | 5-dimension audit (logic, duplication, dead code, refactoring, shortcuts) |
| file/dir path | cwd | Scope — one or more files or a directory |

## Call Pattern

### Step 1: Run the audit

```
mcp__claude-code__claude_code:
  prompt: |
    Audit the following code and report every issue with exact file:line locations.

    SCOPE: {files or directory to audit}

    {IF --mini or default}
    Audit dimensions (5):
    1. Logic errors — incorrect conditions, off-by-one, unhandled edge cases, race conditions
    2. Code duplication — copy-paste, near-duplicate logic that should be extracted
    3. Dead code — unreachable branches, unused variables/imports/exports, stale flags
    4. Refactoring opportunities — overly complex functions, poor naming, leaky abstractions
    5. Shortcuts and tech debt — TODO/FIXME/HACK markers, hardcoded values, missing validation

    {IF --full}
    Audit dimensions (9):
    1. Logic errors — incorrect conditions, off-by-one, unhandled edge cases, race conditions
    2. Code duplication — copy-paste, near-duplicate logic that should be extracted
    3. Dead code — unreachable branches, unused variables/imports/exports, stale flags
    4. Refactoring opportunities — overly complex functions, poor naming, leaky abstractions
    5. Shortcuts and tech debt — TODO/FIXME/HACK markers, hardcoded values, missing validation
    6. Security — injection, auth bypass, data exposure, missing input validation, insecure defaults
    7. Performance — N+1 queries, O(n²) loops, blocking I/O, unnecessary allocations
    8. Compliance and documentation — missing error handling, undocumented public APIs, license issues
    9. Dependencies — outdated packages, unnecessary deps, known-vulnerable versions

    For each finding report:
    - File:line
    - Severity: Critical / High / Medium / Low
    - Dimension (which of the above)
    - Issue description (one sentence — what is wrong)
    - Suggested fix (one sentence — what to do)

    If a file is clean on all dimensions, say so explicitly.

    PROVENANCE NOTE: The code was written by OpenAI Codex. Evaluate with full rigor —
    do not defer to it. Apply independent judgment on every finding.
  cwd: {project working directory}
  effort: high
  permissionMode: plan
```

Save the returned `session_id` as `{audit_session_id}`.

### Step 2: Follow up (optional)

To expand on a specific finding:

```
mcp__claude-code__claude_code_reply:
  session_id: {audit_session_id}
  prompt: "Expand on finding #N — exact mechanism and minimal fix."
```

## Output Format

Display findings as a table, then a severity summary:

| File:Line | Severity | Dimension | Issue | Fix |
|-----------|----------|-----------|-------|-----|
| ... | High | Logic | ... | ... |

**Summary**: Critical: N | High: N | Medium: N | Low: N | Total: N

If at least one finding, also write the table to `.cc-suite/audits/audit-{YYYYMMDD-HHMMSS}-findings.md` (create the directory if missing) with a `Status` column set to `open`, and report the path — a durable copy survives context compaction and lets a later `$audit-fix` pass start from this audit's exact output instead of re-auditing.

If clean: report CLEAN with the scope audited (no file is written).

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

- `permissionMode: plan` keeps Claude read-only — audit only, no writes
- Pass `session_id` to `$verify` after Codex applies fixes, to reuse the same Claude session
- For full projects, pass the top-level source directory rather than individual files

## Example Invocations

<example>
Context: Codex just implemented a feature and the user wants an independent opinion before merging.
user: "Have Claude look over what you just wrote before I merge it."
assistant: "I'll invoke audit on the changed files — Claude reads them cold and returns findings with file:line and severity, since Codex reviewing its own work is not an independent check."
</example>

<example>
Context: The user wants a deep pre-release pass over a whole module rather than a quick diff check.
user: "Do a thorough review of src/payments/ before we ship."
assistant: "I'll call audit with full depth for the 9-dimension pass, which adds security, dependency, and test-coverage dimensions over the 5-dimension mini audit."
</example>
