---
name: cancel
description: Cancel a running Codex background job
argument-hint: "[job-id]"
---

## User Input

```text
$ARGUMENTS
```

## Workflow

### Step 1: Find the job to cancel

Parse `$ARGUMENTS`:

| Input | Action |
|-------|--------|
| (empty) | Cancel the only active job (error if 0 or >1 active) |
| `<job-id>` | Cancel the specified job (prefix match supported) |

If no active jobs:
```
No active Codex jobs to cancel.
```
And STOP.

If multiple active jobs and no id specified:
```
Multiple jobs are active. Specify which one to cancel:

| Job | Kind | Status | Elapsed | Summary |
| --- | --- | --- | --- | --- |
{list of active jobs}

Usage: /codex-toolkit:cancel <job-id>
```
And STOP.

### Step 2: Kill the job process

1. Read the job's PID from the state file
2. Send SIGTERM to the process group (kills the job and any child processes)
3. Update the job status to `cancelled` in the state file
4. Log the cancellation

```bash
kill -- -{pid} 2>/dev/null || kill {pid} 2>/dev/null || true
```

### Step 3: Report

```markdown
# Codex Cancel

Cancelled {job-id}.

- Kind: {kind}
- Summary: {summary}
- Was running for: {elapsed}

Check `/codex-toolkit:status` for the updated queue.
```
