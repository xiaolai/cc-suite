---
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
| {job-id} | {kind} | running | {elapsed} | {summary} |

Usage: /cc-suite:cancel <job-id>
```
And STOP.

### Step 2: Kill the job process

1. Read the job's PID from the state file. If the state file does not exist or is unreadable, report "Job {job-id} not found or already complete." and stop.
2. Send SIGTERM to the process group (kills the job and any child processes)
3. Update the job status to `cancelled` in the state file
4. Log the cancellation

```bash
kill -- -{pid} 2>/dev/null || kill {pid} 2>/dev/null || true
```

Verify the process terminated:

```bash
sleep 0.5 && kill -0 {pid} 2>/dev/null && echo "warning: process still running" || echo "terminated"
```

If the process was already gone before SIGTERM (stale PID), mark the job as `cancelled` in the state file and report success — the job was already terminated.

### Step 3: Report

```markdown
# Codex Cancel

Cancelled {job-id}.

- Kind: {kind}
- Summary: {summary}
- Was running for: {elapsed}

Check `/cc-suite:status` for the updated queue.
```
