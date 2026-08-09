---
description: Fetch stored output from a completed Codex job
argument-hint: "[job-id]"
---

## User Input

```text
$ARGUMENTS
```

## Workflow

### Step 1: Resolve the job and read its stored result

Resolve the reference (empty → most recent finished job for this session; otherwise exact or prefix match) and load the stored result in one call:

```bash
node -e "
  const { resolveResultJob, readStoredJob } = await import('${CLAUDE_PLUGIN_ROOT}/scripts/lib/job-control.mjs');
  try {
    const reference = process.argv[1] || undefined;
    const { workspaceRoot, job } = resolveResultJob(process.cwd(), reference);
    const stored = readStoredJob(workspaceRoot, job.id);
    console.log(JSON.stringify({ job, stored }, null, 2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
" -- "$ARGUMENTS"
```

If the command exits non-zero, relay the single-line message it printed to stderr verbatim (it already distinguishes still-running jobs, unknown references, ambiguous prefixes, and no-finished-jobs) and STOP.

### Step 2: Check the stored payload

`stored` contains the raw Codex output and metadata. If `stored` is `null` or does not contain usable output, report `Result file missing or unreadable for job {job-id} — it may have been pruned. Run /cc-suite:status to see available jobs.` and STOP.

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
