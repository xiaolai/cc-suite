---
description: Cancel a running Codex background job
argument-hint: "[job-id]"
---

## User Input

```text
$ARGUMENTS
```

## Workflow

### Step 1: Resolve, terminate, and persist

One call resolves the reference (empty → the only active job; otherwise exact or prefix match among active jobs), terminates the job's process tree, confirms the exit, and records the cancellation:

```bash
node -e "
  const { cancelJob } = await import('${CLAUDE_PLUGIN_ROOT}/scripts/lib/job-control.mjs');
  try {
    const reference = process.argv[1] || undefined;
    const result = cancelJob(process.cwd(), reference);
    console.log(JSON.stringify(result, null, 2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
" -- "$ARGUMENTS"
```

Do **not** shell out to `kill` directly. `cancelJob` verifies that the recorded PID still belongs to this job (via its recorded process start time) before signalling — a bare `kill -- -{pid}` on a recycled PID would terminate an unrelated process. It also escalates SIGTERM → SIGKILL and only reports success once the process is confirmed gone.

If the command errors:

- `"No active Codex jobs to cancel."` → relay it and STOP.
- `"Multiple jobs are active..."` → list the active jobs (via `buildStatusSnapshot` as in `/cc-suite:status`) and STOP:
  ```
  Multiple jobs are active. Specify which one to cancel:

  | Job | Kind | Status | Elapsed | Summary |
  | --- | --- | --- | --- | --- |
  | {job-id} | {kind} | running | {elapsed} | {summary} |

  Usage: /cc-suite:cancel <job-id>
  ```
- `"No job found for ..."` / `"...is ambiguous..."` → relay it and STOP.

### Step 2: Report the actual outcome

The result carries `outcome`, `terminated`, and `detail`. Report what really happened rather than assuming the kill worked:

| `outcome` | Meaning | Report |
|-----------|---------|--------|
| `terminated` | Signalled and confirmed exited | Cancelled {job-id}. |
| `already-exited` | Process was already gone (or its PID had been recycled) | Cancelled {job-id} — it had already finished. |
| `not-confirmed` | SIGTERM and SIGKILL sent, process still alive | Cancelled {job-id} in the job list, but **the process has not exited yet** — {detail}. |
| `unverifiable` | Job predates process-identity tracking; not signalled | Marked {job-id} cancelled, but **it was not signalled** — {detail}. |
| `no-pid` | No PID recorded (queued, worker never started) | Marked {job-id} cancelled — {detail}. |
| `signal-failed` | Signalling raised an error | Marked {job-id} cancelled, but **termination failed** — {detail}. |

```markdown
# Codex Cancel

{verdict line from the table above}

- Kind: {job.kind}
- Summary: {job.summary}
- Was running for: {elapsed}

Check `/cc-suite:status` for the updated queue.
```
