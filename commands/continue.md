---
name: continue
description: Continue a previous Codex session — iterate on findings, request fixes, or drill deeper
argument-hint: "<threadId> <follow-up prompt>"
---

## User Input

```text
$ARGUMENTS
```

## What This Does

Continues a previous Codex session via `codex exec resume` (through the CLI runner). The session preserves full context from the original command, so you can:

> **Note**: Codex CLI sessions **persist on disk**, so they survive Claude Code / shell restarts (unlike the old in-memory MCP threads). A `threadId` from an earlier session can still be resumed later. If a session id is genuinely unknown, `codex exec resume --last` picks the most recent; otherwise start fresh with /audit, /implement, or another command.

- Iterate on audit findings: "Now fix the 3 Critical issues you found"
- Follow up on implementation: "Run the tests and fix any failures"
- Drill into bug analysis: "Show me the exact call stack for issue #2"
- Refine a review: "Explain the race condition you flagged in more detail"

## Workflow

### Step 1: Parse input

Extract the `threadId` and follow-up prompt from `$ARGUMENTS`:

| Input | Interpretation |
|-------|----------------|
| `<threadId> <prompt>` | Thread ID + follow-up message |
| `<threadId>` (no prompt) | Ask the user for the follow-up prompt |
| (empty) | Ask the user for both threadId and prompt |

**ThreadId detection heuristic**: Thread IDs are UUID-format strings (e.g., `019d10e8-5bf9-77e2-b518-f5256fa06b2c`) or short alphanumeric tokens. The first token in `$ARGUMENTS` is a threadId if it matches a UUID pattern (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) or is a single alphanumeric string with no spaces. Otherwise, treat the entire input as a prompt and ask for the threadId.

If `$ARGUMENTS` is empty or missing the threadId:

```
AskUserQuestion:
  question: "What is the thread ID from the previous Codex command?"
  header: "Thread ID"
  options:
    - label: "Paste thread ID"
      description: "The threadId shown in the output of your previous command"
    - label: "I don't have one"
      description: "Start a new session with /audit, /implement, etc. instead"
```

If the user doesn't have a threadId, suggest they run one of the main commands first and STOP.

If the follow-up prompt is missing:

```
AskUserQuestion:
  question: "What would you like to tell Codex?"
  header: "Follow-up"
  options:
    - label: "Fix the issues found"
      description: "Ask Codex to fix all Critical and High severity issues"
    - label: "Explain in more detail"
      description: "Ask Codex to elaborate on its findings"
    - label: "Run tests"
      description: "Ask Codex to run tests and report results"
```

### Step 2: Send follow-up to Codex

Resume the session through the CLI runner (per `commands/shared/codex-call.md`):

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-runner.mjs" \
  --kind continue --model {chosen_model} --effort {chosen_effort} \
  --sandbox read-only --timeout-ms 600000 \
  --resume {threadId} --summary "continue {threadId}" \
  -- "{follow_up_prompt}"
```

Parse the JSON result; the `rawOutput` is Codex's reply. Note: `resume` inherits the original session's sandbox — to grant write access, start a fresh command instead (e.g. `/implement`).

**If the runner returns `failed`/`stalled`** (session id not found, or deadline exceeded):

```
Session `{threadId}` could not be resumed (status: {status}). Job: {jobId} — inspect with /cc-suite:status {jobId}.

Options:
- Try `codex exec resume --last` if you meant the most recent session
- Start a fresh session: /audit, /implement, /bug-analyze, etc.
```
And STOP.

### Step 3: Display response

```markdown
## Codex Follow-up

**Thread ID**: `{threadId}`
**Prompt**: {follow_up_prompt}

---

{codex response}

---

_Thread ID: `{threadId}` — run `/continue {threadId}` to continue this conversation._
```

### Step 4: Offer to continue

```
AskUserQuestion:
  question: "What would you like to do next?"
  header: "Next step"
  options:
    - label: "Continue this conversation"
      description: "Send another follow-up to the same thread with /continue {threadId}"
    - label: "Start a new command"
      description: "Run /audit, /implement, /bug-analyze, or another command in a fresh session"
    - label: "Done"
      description: "No further action needed"
```
