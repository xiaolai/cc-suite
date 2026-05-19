---
name: status
description: Show active and recent Codex jobs — background tasks, running audits, completed results
argument-hint: "[job-id] [--all] [--json]"
---

## User Input

```text
$ARGUMENTS
```

## Workflow

### Step 1: Build status snapshot

Load the job state from the workspace state directory:

```bash
node -e "
  const { buildStatusSnapshot } = await import('${CLAUDE_PLUGIN_ROOT}/scripts/lib/job-control.mjs');
  const snapshot = buildStatusSnapshot(process.cwd(), { all: process.argv[1] === '--all' });
  console.log(JSON.stringify(snapshot, null, 2));
" -- "$(/bin/echo "$ARGUMENTS" | grep -o '\-\-all' || true)"
```

Parse the JSON output. The snapshot contains: `running` (active jobs), `latestFinished`, `recent` (completed jobs), `config` (review gate status), and `needsReview`.

### Step 2: Display status

Parse `$ARGUMENTS`:

| Input | Action |
|-------|--------|
| (empty) | Show all jobs for current session |
| `<job-id>` | Show details for a specific job |
| `--all` | Show all jobs across all sessions |
| `--json` | Output raw JSON instead of markdown |

#### Default view (no job-id)

```markdown
# Codex Toolkit Status

Review gate: {enabled / disabled}

## Active Jobs

| Job | Kind | Status | Phase | Elapsed | Thread ID | Summary |
| --- | --- | --- | --- | --- | --- | --- |
| {id} | {kind} | running | {phase} | {elapsed} | {threadId} | {summary} |

## Latest Finished

- {id} | {status} | {kind}
  Summary: {summary}
  Duration: {duration}
  Thread ID: {threadId}
  Continue: /continue {threadId}
  Result: /cc-suite:result {id}

## Recent Jobs

{list of recent completed/failed jobs}
```

If no jobs exist: "No jobs recorded yet. Run /audit, /implement, or /bug-analyze to create one."

#### Single job view (job-id provided)

```markdown
# Codex Job Details

**Job ID**: {id}
**Kind**: {audit | implement | bug-analyze | review-plan | verify}
**Status**: {running | completed | failed | cancelled}
**Started**: {ISO timestamp}
**Elapsed**: {hh:mm:ss}
**Thread ID**: `{threadId}` _(use `/continue {threadId}` to follow up)_

## Summary

{one-line summary from job state}

## Recent Output

{last 20 lines of progress if running, or full output if completed/failed}
```

### Step 3: Review gate status

If the stop-time review gate is enabled, append:

```
The stop-time review gate is enabled.
Ending the session will trigger a Codex adversarial review and block if it finds issues.
Disable with: /cc-suite:setup --disable-review-gate
```
