---
name: agy
description: Delegate a prompt directly to Antigravity CLI with bounded execution and shared job tracking
argument-hint: "[--model <name>] [--sandbox read-only|workspace-write|danger-full-access] [--background] [--resume <conversation-id>] <prompt>"
allowed-tools:
  - Bash
  - AskUserQuestion
---

# /cc-suite:agy

Send a prompt to Antigravity CLI (`agy`) through the cc-suite runner. This is
the direct Claude → agy delegation surface; it is separate from Codex-backed
audit and implementation commands.

## User Input

```text
$ARGUMENTS
```

## Workflow

### Step 1: Parse the request

Extract these optional flags from `$ARGUMENTS` and leave the remaining text as
the prompt:

- `--model <name>` — pass the complete model display name, including effort
  suffixes such as `Gemini 3.1 Pro (High)`
- `--sandbox <read-only|workspace-write|danger-full-access>` — default
  `read-only`
- `--background` or `--wait` — default `--wait`
- `--resume <conversation-id>` — continue a prior agy conversation

If the prompt is empty, ask the user what they want agy to do and stop if they
do not provide one.

### Step 2: Choose a model when needed

If `--model` was omitted, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-preflight.sh"
```

If preflight returns an error, report its `error` and `error_code` and stop.
Otherwise use `default_model`. Do not ask for a reasoning-effort setting: agy
encodes effort in the model display name.

### Step 3: Run the request

Follow `commands/shared/agy-call.md` and invoke:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/agy-runner.mjs" \
  --kind agy \
  --model "{chosen_model}" \
  --sandbox {chosen_sandbox} \
  --timeout-ms 900000 \
  {--background if selected} \
  {--resume "{conversation_id}" if selected} \
  --summary "agy: {short prompt summary}" \
  -- "{prompt}"
```

Parse the single JSON object from stdout. For a foreground call, display
`rawOutput`, `jobId`, `status`, and `threadId`. For a background call, return
the queued `jobId` and tell the user to use `/cc-suite:status`,
`/cc-suite:result`, or `/cc-suite:cancel`.

On `failed` or `stalled`, report the error and job id. Do not retry the same
request automatically; the runner has already recorded the diagnostic log.
