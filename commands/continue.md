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

Uses the `mcp__codex-cli__codex-reply` MCP tool to continue a previous Codex session. The thread preserves full context from the original command, so you can:

> **Note**: Codex threads are **in-memory only** — they are lost when the MCP server restarts (e.g. after restarting Claude Code or the Codex MCP process). If a thread is no longer available, start a fresh session with /audit, /implement, or another command instead.

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

```
mcp__codex-cli__codex-reply with:
  threadId: {threadId}
  prompt: "{follow_up_prompt}"
```

**If `codex-reply` fails** (thread not found / expired / MCP server restarted):

```
Thread `{threadId}` is no longer available — Codex threads are in-memory only and are lost when the MCP server restarts.

Options:
- Start a fresh session: /audit, /implement, /bug-analyze, etc.
- Re-run the original command to create a new thread
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
