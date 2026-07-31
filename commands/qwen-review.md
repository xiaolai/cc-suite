---
name: qwen-review
description: Send a bounded, read-only review to Qwen Code with sandboxing, isolated target copies, strict completion detection, verified hashes, and limited session resume.
argument-hint: "[--model <id>] [--target <workspace-file>]... [--background] [--debug-capture] <review prompt>"
allowed-tools:
  - Bash
  - AskUserQuestion
---

# /cc-suite:qwen-review

Ask **Qwen Code** for independent critique without giving it implementation
authority. The runner always uses Safe Mode, Plan mode, and `stream-json`.
There is no write-enabled option.

The command is intentionally narrower than `/cc-suite:grok`: Qwen is a critic
here, not a second editor. Its answer is critique, not evidence. The calling
agent must verify material findings and retain final judgment.

## User Input

```text
$ARGUMENTS
```

## Workflow

### Step 1: Parse the bounded review

Extract these optional flags; the remaining text is the review prompt:

- `--model <id>` — Qwen model id. Omit to use Qwen's configured default.
- `--target <workspace-file>` — allow one exact file to be opened with
  `read_file`. Repeat for multiple files. Directories, globs, symlink escapes,
  and paths outside the workspace are rejected.
- `--background` or `--wait` — default `--wait`.
- `--debug-capture` — persist raw stdout/stderr for troubleshooting. Warn that
  raw capture can contain the complete reviewed files; leave it off normally.

If the prompt is empty, ask what Qwen should review and stop if no prompt is
provided.

If the user did not explicitly authorize sending each target's contents to
Qwen, ask once before continuing. A direct user request naming the target and
asking for Qwen review is authorization. Never include `.env`, credentials,
tokens, cookies, private keys, or unrelated workspace files.

### Step 2: Check local readiness

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/qwen-preflight.sh"
```

Parse the single JSON object. If `status` is `"error"`, report `error_code` and
`error`, then stop. This preflight is local and does not send a model prompt or
inspect credentials.

### Step 3: Run the review

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/qwen-runner.mjs" \
  --kind qwen-review \
  {--model "{model}" if given} \
  {--target "{target}" for every exact target} \
  --max-resumes 2 \
  --attempt-timeout-ms 300000 \
  --idle-timeout-ms 240000 \
  --timeout-ms 900000 \
  {--background if selected} \
  {--debug-capture only if explicitly selected} \
  --summary "qwen review: {short prompt summary}" \
  -- "{prompt}"
```

The runner:

1. Injects the shared delegation boundary.
2. Copies declared files into a private temporary workspace, then starts Qwen
   with `--safe-mode --sandbox --approval-mode plan`.
3. Denies every known non-review tool at Qwen's CLI boundary and checks the
   actual init event before accepting later events: no exposed tools or calls
   for prompt-only review, or exactly `read_file` with a bounded call budget for
   isolated target copies. Any unexpected advertised tool fails closed. The
   stream observer also rejects undeclared paths.
4. Accepts success only after a non-empty terminal `result`, `is_error=false`,
   and process exit code 0.
5. Verifies target hashes after every attempt.
6. Resumes the same Qwen session at most twice after a genuinely incomplete
   exit. Policy, parsing, terminal-error, exit-mismatch, and hash failures are
   never resumed.

The runner deletes temporary copies after the job and on catchable termination
signals. An uncatchable `SIGKILL` can still leave a private temporary directory
behind. This narrows Qwen's workspace view, but it is still defense in depth
rather than a claim of perfect OS isolation. Do not send secrets.

### Step 4: Report and adjudicate

Parse the runner's single JSON object.

- **Foreground**: display `rawOutput`, `jobId`, `status`, `threadId`, attempt
  count, and `targetsVerified`.
- **Background**: display the queued `jobId` and point to
  `/cc-suite:status`, `/cc-suite:result`, and `/cc-suite:cancel`.
- **Failed/stalled**: report `errorCode`, `error`, job id, and attempt summary.
  Do not substitute another model while claiming Qwen completed.

After displaying the critique, independently verify every material finding
against the declared targets or primary sources. State which findings are
accepted, rejected, or unresolved.
