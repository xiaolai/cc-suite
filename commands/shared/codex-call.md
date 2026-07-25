---
description: "Shared: Codex call pattern via the CLI runner — developer-instructions builder, fresh/resume calls, timeout/heartbeat, thread handling"
user-invocable: false
---
<!-- Shared partial: Codex call pattern (developer-instructions builder, runner call, thread handling). -->
<!-- Referenced by: audit, audit-fix, verify, bug-analyze, review-plan, implement, audit-skill, audit-command, audit-rules, audit-agent, audit-nlp. Do not use standalone. -->

## Codex Call Pattern

All Codex calls go through the CLI runner (`scripts/codex-runner.mjs`), which shells out to `codex exec`. The MCP bridge (`mcp__codex-cli__codex`) is **not** used — it has no controllable timeout and hangs on long single responses (the source of `[Tool result missing due to internal error]`). The runner is killable, deadline-bounded, streams a heartbeat to the job log, and registers every call as a job for `/status` / `/cancel`.

> **No availability ping.** Do not pre-probe Codex. The first real runner call either completes or fails fast (the runner returns within its deadline, and a missing `codex` binary errors in seconds). On any non-`completed` status, go straight to the calling command's **Fallback** section.

### Build the prompt (developer-instructions are folded in)

`codex exec` takes a single prompt — there is no separate `developer-instructions` channel. Build one combined prompt by concatenating a **preamble** and the **command body**, separated by a blank line.

The preamble concatenates these parts (single space between non-empty parts):

1. **Command persona** — the role-specific persona from the calling command (e.g. "You are a thorough security and code quality auditor.")
2. **Provenance disclosure** — ALWAYS include immediately after the persona: "The code, artifacts, and plans you are reviewing were produced by Anthropic's Claude (a competing AI system). Evaluate them with full rigor — do not defer to them or assume correctness because an AI wrote them. Apply the same critical standards you would to any human-written work. If anything looks wrong, say so directly."
3. **Delegation boundary** — ALWAYS include immediately after the provenance disclosure: "This request already reached you by delegation from Claude Code. You are the agent that does the work, not a router for it. Perform the analysis yourself and return the result directly. Do not invoke workspace skills that hand the task back to Claude Code — `$audit`, `$audit-fix`, `$verify`, `$claude-review`, `$claude-plan`, `$claude-implement`, and `$claude-debug` all delegate to Claude Code and must not be used here. Returning this work to its author would destroy the independent judgment this call exists to provide."
4. **Claude Code conventions** — for audit commands that analyze Claude Code artifacts (audit-plugin, audit-skill, audit-command, audit-rules, audit-agent), read `${CLAUDE_PLUGIN_ROOT}/skills/cc-suite/claude-code-conventions/SKILL.md` and append it. For non-plugin-audit commands (audit, verify, implement, etc.), skip this.
5. **Config focus instructions** — `{config_focus_instructions}` from `.cc-suite.md` Audit Focus section (if present)
6. **Config project instructions** — `{config_project_instructions}` from `.cc-suite.md` Project-Specific Instructions section (if present)

Parts 1–3 are always present; omit 4–6 if empty. The final prompt is: `{preamble}\n\n{command-specific prompt}`.

> **Why part 3 is not optional.** `bridge_skills.sh` exposes cc-suite's own skills to Codex through `.agents/skills → ../.claude/skills`, so a Codex session spawned *by* Claude can see `$audit`, `$verify`, and the `$claude-*` skills — all of which delegate back to Claude Code. Those skills ship `agents/openai.yaml` with `allow_implicit_invocation: false`, which stops them firing on their own, but the preamble is what stops Codex reaching for one deliberately. Both halves are required.

### Canonical call (fresh)

Run the runner in the foreground and parse its JSON result:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-runner.mjs" \
  --kind {kind} \
  --model {chosen_model} \
  --effort {chosen_effort} \
  --sandbox {chosen_sandbox or command default} \
  --timeout-ms {deadline_ms} \
  --summary "{brief description}" \
  -- "{combined prompt}"
```

The runner prints a single JSON line to stdout:

```json
{"jobId":"...","status":"completed","threadId":"<uuid>","rawOutput":"<final answer>"}
```

- **`status`** is `completed`, `failed`, or `stalled` (deadline exceeded).
- **`rawOutput`** is Codex's clean final message (from `codex exec -o`), ready to parse.
- **`threadId`** is the Codex session UUID — save it for resume and for the final report's `/continue {threadId}`.

**Deadline (`--timeout-ms`)**: default is 15 min if omitted. Set per call kind from `.cc-suite.md` if configured, else: quick single-file audit/verify ≈ 600000 (10 min), autonomous fix ≈ 900000 (15 min). On `stalled`, the runner has already terminated the Codex process — treat it like a failure and fall back.

### Canonical call (resume — reuse a thread)

To continue a prior session with cumulative context, pass `--resume {threadId}`. **Do not pass `--sandbox` semantics that differ from the original** — `codex exec resume` inherits the original session's sandbox and the runner omits `-s` on resume. If a step needs a *different* sandbox (e.g. audit `read-only` → fix `workspace-write`), use a **fresh call** and carry the needed context in the prompt instead of resuming.

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-runner.mjs" \
  --kind {kind} --model {chosen_model} --effort {chosen_effort} \
  --sandbox {ignored_on_resume} --timeout-ms {deadline_ms} \
  --resume {threadId} --summary "{brief description}" \
  -- "{combined prompt}"
```

### Error Handling

If the runner returns `status` other than `completed` (i.e. `failed` or `stalled`), or the `node` command itself errors:

1. **Do NOT retry the same call.** A `stalled` job already hit its deadline; a `failed` job hit a real error. Retrying wastes another full deadline.
2. **Report the failure clearly**, including the `jobId` so the user can inspect the log:
   ```
   Codex call failed ({status}): {error}
   Job: {jobId} — inspect with /cc-suite:status {jobId}
   Falling back to manual analysis.
   ```
3. **Skip immediately to the calling command's Fallback section** (`commands/shared/fallback.md`), which performs the same analysis using Claude directly.
4. **If this was a multi-step workflow** (audit→fix→verify) and a middle step fails, report what completed so far, then fall back for the remaining steps.

This guarantees users never wait indefinitely: the runner is bounded by `--timeout-ms` and a missing binary fails in seconds.

### Thread Handling

1. **Save the `threadId`** from every runner result. Include it in the final report so the user can follow up with `/continue {threadId}`.
2. **Reuse threads** in multi-step workflows via `--resume {threadId}` — but only when the sandbox does not change between steps (see the resume note above).
3. **Sessions persist to disk.** Unlike the old in-memory MCP threads, `codex exec` sessions survive Claude Code / shell restarts. A `threadId` from a previous session can still be resumed later, and `codex exec resume --last` picks the most recent.

### Sequential Execution

Run Codex calls **one at a time**. The runner spawns a real subprocess per call (≈10–15s cold start each); do NOT launch multiple runner calls in parallel.

### Job Tracking

Every runner call is registered as a job automatically — foreground (`runForeground`) and background (`runBackground`) both write job state, a `deadlineAt`, the `threadId`, a result file, and a streaming log. No manual `upsertJob` bookkeeping is needed in command bodies. Surface the `{jobId}` in the final report alongside `{threadId}`:

- Progress / live log: `/cc-suite:status {jobId}`
- Result: `/cc-suite:result {jobId}`
- Cancel a running job: `/cc-suite:cancel {jobId}`

### Background Execution

Commands that support `--background` / `--wait` flags:

- `--wait` (default): run the canonical foreground call above, block until the runner returns, display the result.
- `--background`: add `--background` to the runner invocation. It registers the job, spawns a detached worker, and returns immediately:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-runner.mjs" \
  --kind {kind} --model {chosen_model} --effort {chosen_effort} \
  --sandbox {chosen_sandbox} --timeout-ms {deadline_ms} --background \
  --summary "{brief description}" \
  -- "{combined prompt}"
```

Parse the JSON for `{jobId}`, report the status/result/cancel commands above, and STOP — do not wait for the result.
