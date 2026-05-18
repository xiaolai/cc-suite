---
name: result
description: Fetch stored output from a completed Codex job
argument-hint: "[job-id]"
---

## User Input

```text
$ARGUMENTS
```

## Workflow

### Step 1: Resolve the job

Parse `$ARGUMENTS` to find the job:

| Input | Action |
|-------|--------|
| (empty) | Show the most recent completed job for this session |
| `<job-id>` | Show results for the specified job (prefix match supported) |

If the job is still running:
```
Job {id} is still running. Check /codex-toolkit:status and try again when it finishes.
```
And STOP.

If no completed jobs found:
```
No finished Codex jobs found. Run /audit, /implement, or /bug-analyze first.
```
And STOP.

### Step 2: Read the stored result

Read the job's result file from the state directory. The result file contains the raw Codex output and metadata.

### Step 3: Display the result

```markdown
# Codex Result

**Job**: {id}
**Kind**: {kind}
**Status**: {status}
**Duration**: {duration}
**Thread ID**: `{threadId}` _(use `/continue {threadId}` to iterate)_

---

{raw Codex output}

---

_Job: `{id}` | Thread: `{threadId}` | Run `/continue {threadId}` to follow up._
```

If the job failed, show the error message instead of the raw output.

### Step 4: Offer next steps

Based on the job kind:
- **audit**: "Fix issues with `/audit-fix`, verify with `/verify`, or drill deeper with `/continue {threadId}`"
- **implement**: "Review changes with `git diff`, run tests, or continue with `/continue {threadId}`"
- **bug-analyze**: "Apply the fix, or drill deeper with `/continue {threadId}`"
- **verify**: "Run `/audit` for a fresh scan, or `/audit-fix` to fix remaining issues"
