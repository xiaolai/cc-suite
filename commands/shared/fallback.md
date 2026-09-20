---
description: "Shared: manual analysis fallback when Codex is unavailable or returns empty"
user-invocable: false
---
<!-- Shared partial: fallback rules when Codex returns empty or fails -->
<!-- Referenced by: audit, audit-fix, verify, bug-analyze, review-plan, audit-skill, audit-command, audit-rules, audit-agent, audit-nlp. Do not use standalone. -->

## Fallback — Manual Analysis

**CRITICAL**: If Codex returns empty, errors out, or provides incomplete results, you MUST perform the task manually. Never stop just because Codex failed.

### Steps

1. **Read each file in scope as determined by scope-parse.md** using the Read tool
2. **Analyze** using the calling command's dimensions, criteria, or review framework
3. **Use Grep** to search for common patterns specific to the task (e.g. security markers, dead code indicators, TODO/FIXME/HACK)
4. **Report findings** in the same structured format the calling command specifies

### Rules

- Do NOT say "Codex didn't return findings" and stop
- Do NOT skip dimensions or criteria — cover everything the calling command requires
- Do NOT reduce quality — manual analysis should match the same standard as a Codex-powered analysis
- If the fallback was triggered by a ping failure, note "Codex unavailable — manual analysis" in the report header

### Diagnostic header (when Codex was unavailable, not just empty)

When the fallback was triggered because Codex couldn't be reached (runner returned `failed`/`stalled`, `codex` binary missing, deadline exceeded) — as opposed to Codex responding with no findings — the user needs to know **why** so they can restore Codex mode. Before producing the fallback output, run two quick checks and put the diagnostic block at the top of the report.

Checks — the two things the CLI runner actually needs, the binary and a live
login. Do **not** inspect `.mcp.json`: delegation runs `codex exec`, so no MCP
registration is involved, and reporting one as the cause sends the user to fix an
unrelated file (cc-suite ≤2.0.1 did exactly that).

```bash
which codex 2>/dev/null || true
command -v codex >/dev/null 2>&1 && codex login status 2>&1 | head -3
```

Required block at the top of the fallback report:

```
**Codex unavailable — manual analysis.** To restore Codex mode:
- codex binary on PATH: {yes — <path> / no}
- codex login: {Logged in using … / not logged in / unknown}
- Suggested fix: {install codex from https://github.com/openai/codex if not found, `codex login` if not logged in, or `/cc-suite:codex-preflight` for a live auth + model probe}
- Full diagnostic: `/cc-suite:diagnose`
```

Without this block, users see degraded output and don't know it's degraded or how to fix it.
