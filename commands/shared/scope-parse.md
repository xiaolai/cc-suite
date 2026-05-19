---
description: "Shared: parse audit scope arguments, enforce skip patterns, detect trivial changes"
user-invocable: false
---
<!-- Shared partial: scope parsing, trivial check, skip pattern enforcement -->
<!-- Referenced by: audit, audit-fix, bug-analyze (conditional). Do not use standalone. -->

## Scope Parsing

### Parse `$ARGUMENTS` to determine scope

| Input | Scope |
|-------|-------|
| (empty) | Uncommitted changes (`git diff HEAD --name-only`) |
| `staged` | Staged changes only (`git diff --cached --name-only`) |
| `commit -1` | Last commit (`git diff HEAD~1 --name-only`) |
| `commit -N` | Last N commits (`git diff HEAD~N --name-only`) |
| `--full` | Entire codebase (scan src/, lib/, app/) |
| `path/to/dir` or `path/to/file` | Specific directory or file |

**If scope is empty** (no changed files found), respond: "No changes detected in scope. Nothing to audit." and STOP.

### Skip Pattern Enforcement

If `{config_skip_patterns}` is set (from `.cc-suite.md`), filter the file list:

1. For each file in scope, check against every skip pattern (glob matching)
2. Remove any file that matches a skip pattern
3. If ALL files are filtered out, respond: "All files in scope are excluded by skip patterns in `.cc-suite.md`. Nothing to audit." and STOP.

### Trivial Scope Check

Before proceeding, analyze the diff to determine if the changes warrant analysis.

**Get the diff**:
- For uncommitted changes: `git diff HEAD`
- For staged: `git diff --cached`
- For commit ranges: `git diff HEAD~N`
- For specific paths: read the files directly

**Classify as trivial if ALL of the following are true**:
- Total code changes ≤ 5 lines (excluding blank lines and comments)
- Changes are purely mechanical: typo fixes, formatting, whitespace, import reordering, comment edits, version bumps in config files
- No logic, control flow, or data handling changes whatsoever

**NEVER classify as trivial if ANY of these apply**:
- Any change to logic, conditionals, loops, or data flow — even a single character (`>` vs `>=`)
- Files in security-sensitive paths (auth, crypto, permissions, payments, sessions)
- New dependencies added or removed
- Config changes that affect runtime behavior (env vars, feature flags, API endpoints)
- Changes to error handling or validation

**If trivial**, ask the user (use the calling command's description in the "Audit anyway" option):

```
AskUserQuestion:
  question: "This looks like a trivial change ({N} lines — {description, e.g. 'typo fix in comment'}). Analysis is unlikely to find anything. Proceed anyway?"
  header: "Scope"
  options:
    - label: "Skip (Recommended)"
      description: "Change is too minor to warrant analysis"
    - label: "Analyze anyway"
      description: "Run the analysis regardless"
```

If "Skip" → respond with "Scope too trivial — no issues expected." and STOP.
