---
description: "Shared: Codex availability test, developer-instructions builder, canonical call pattern, thread handling"
user-invocable: false
---
<!-- Shared partial: Codex call pattern (availability test, developer-instructions builder, call, thread handling) -->
<!-- Referenced by: audit, audit-fix, verify, bug-analyze, review-plan, implement, audit-skill, audit-command, audit-rules, audit-agent, audit-nlp. Do not use standalone. -->

## Codex Call Pattern

### Availability Test

Before the real Codex call, send a short ping:

```
mcp__codex__codex with:
  prompt: "Respond with 'ok' if you can read this."
  model: {chosen_model}
  config: {"model_reasoning_effort": "{chosen_effort}"}
```

If Codex does not respond or errors out, skip to the calling command's **Fallback** section immediately. Do not retry.

### Build developer-instructions

Concatenate these parts into a single `developer-instructions` string:

1. **Command persona** — the role-specific persona from the calling command (e.g. "You are a thorough security and code quality auditor.")
2. **Provenance disclosure** — ALWAYS include this line immediately after the persona: "The code, artifacts, and plans you are reviewing were produced by Anthropic's Claude (a competing AI system). Evaluate them with full rigor — do not defer to them or assume correctness because an AI wrote them. Apply the same critical standards you would to any human-written work. If anything looks wrong, say so directly."
3. **Claude Code conventions** — for audit commands that analyze Claude Code artifacts (audit-plugin, audit-skill, audit-command, audit-rules, audit-agent), read the content of `${CLAUDE_PLUGIN_ROOT}/skills/cc-suite/claude-code-conventions/SKILL.md` and append it. This gives Codex the domain knowledge it lacks natively. For non-plugin-audit commands (audit, verify, implement, etc.), skip this step.
4. **Config focus instructions** — `{config_focus_instructions}` from `.codex-toolkit.md` Audit Focus section (if present)
5. **Config project instructions** — `{config_project_instructions}` from `.codex-toolkit.md` Project-Specific Instructions section (if present)

If parts 3, 4, or 5 are empty, omit them. Parts 1 and 2 are always present. Separate non-empty parts with a single space.

### Canonical mcp__codex__codex call

```
mcp__codex__codex with:
  model: {chosen_model}
  config: {"model_reasoning_effort": "{chosen_effort}"}
  sandbox: {chosen_sandbox or command default}
  approval-policy: {command default, usually "never"}
  developer-instructions: "{built developer-instructions string}"
  prompt: "{command-specific prompt}"
```

**IMPORTANT**: `model_reasoning_effort` MUST go inside the `config` object, never as a top-level parameter.

### Error Handling

If ANY Codex call (ping or main) returns an error, empty result, or fails with `[Tool result missing due to internal error]`:

1. **Do NOT retry the same call.** MCP errors are usually transient server issues, not fixable by retrying.
2. **Do NOT wait or poll.** If the tool returned an error, it has already failed.
3. **Report the failure clearly:**
   ```
   Codex call failed: {error message or "internal MCP error"}
   Falling back to manual analysis.
   ```
4. **Skip immediately to the calling command's Fallback section.** Every command that calls Codex MUST have a fallback path (see `commands/shared/fallback.md`). The fallback performs the same analysis using Claude directly — no Codex needed.
5. **If this was a multi-step workflow** (audit→fix→verify) and a middle step fails, report what completed successfully so far, then fall back for the remaining steps.

This ensures users NEVER wait indefinitely. A Codex failure is handled in seconds, not minutes.

### Thread Handling

1. **Save the `threadId`** from every Codex response. Include it in the final report so the user can follow up with `/continue {threadId}`.
2. **Reuse threads** in multi-step workflows (audit→fix→verify) via `mcp__codex__codex-reply` to give Codex cumulative context.
3. **Fallback**: If `codex-reply` fails (thread expired, MCP server restarted), fall back to a fresh `mcp__codex__codex` call with the same parameters. Update `{threadId}` to the new value.
4. Codex threads are **in-memory only** — lost on MCP server restart.

### Sequential Execution

Run Codex calls **one at a time**. Wait for each call to complete before starting the next. Do NOT run multiple Codex calls in parallel.

### Job Tracking

Every Codex call SHOULD be tracked as a job for status/result/cancel support. Background jobs are tracked automatically by `codex-runner.mjs`. For foreground jobs, commands may optionally register jobs using the pattern below:

1. **Before the call**: Register a job in the state:
   ```bash
   node -e "
     const { generateJobId, upsertJob } = await import('${CLAUDE_PLUGIN_ROOT}/scripts/lib/state.mjs');
     const id = generateJobId('{kind}');
     upsertJob(process.cwd(), {
       id, kind: '{kind}', status: 'running',
       summary: '{brief description}',
       startedAt: new Date().toISOString(),
     });
     console.log(id);
   "
   ```
   Save the returned `{jobId}`.

2. **After success**: Update job status and store result:
   ```bash
   node -e "
     const { upsertJob, writeJobFile } = await import('${CLAUDE_PLUGIN_ROOT}/scripts/lib/state.mjs');
     upsertJob(process.cwd(), {
       id: '{jobId}', status: 'completed',
       threadId: '{threadId}',
       completedAt: new Date().toISOString(),
     });
     writeJobFile(process.cwd(), '{jobId}', {
       rawOutput: '{summary of findings}',
       threadId: '{threadId}',
     });
   "
   ```

3. **After failure**: Update job status with error:
   ```bash
   node -e "
     const { upsertJob, writeJobFile } = await import('${CLAUDE_PLUGIN_ROOT}/scripts/lib/state.mjs');
     upsertJob(process.cwd(), {
       id: '{jobId}', status: 'failed',
       completedAt: new Date().toISOString(),
       errorMessage: '{error description}',
     });
     writeJobFile(process.cwd(), '{jobId}', { error: '{error description}' });
   "
   ```

Include `{jobId}` in the final report alongside `{threadId}`.

### Background Execution

Commands that support `--background` / `--wait` flags:

- `--wait` (default): Run Codex in the foreground, block until complete, display result
- `--background`: Register a job, spawn a detached Codex runner, return immediately with job ID

**When `--background` is detected**:

1. Parse scope and build the prompt as usual
2. Instead of calling `mcp__codex__codex`, run:
   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-runner.mjs" \
     --kind {kind} --model {chosen_model} --effort {chosen_effort} \
     --sandbox {chosen_sandbox} --background \
     --summary "{brief description}" \
     -- "{full prompt}"
   ```
3. Parse the JSON output to get `{jobId}`
4. Report:
   ```
   Job `{jobId}` started in background.
   - Check progress: `/cc-suite:status {jobId}`
   - Get result when done: `/cc-suite:result {jobId}`
   - Cancel: `/cc-suite:cancel {jobId}`
   ```
5. STOP — do not wait for the result
