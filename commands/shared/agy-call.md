---
description: "Shared: Antigravity CLI (agy) call pattern via the CLI runner — model selection, sandbox mapping, conversation resume, and the limits that differ from Codex"
user-invocable: false
---
<!-- Shared partial: agy call pattern. Referenced by any command delegating to Antigravity CLI. Do not use standalone. -->

## agy Call Pattern

All Antigravity CLI calls go through `scripts/agy-runner.mjs`, which shells out to
`agy -p`. The runner is killable, deadline-bounded, heartbeats into the job log, and
registers every call as a job — so `/cc-suite:status`, `/result`, and `/cancel` work
identically for `agy` and Codex jobs.

`agy` exposes **no MCP server mode**, so there is no MCP path to fall back on. The CLI
is the only channel.

> **The delegation boundary is injected for you.** `agy` reads the shared
> `.agents/skills/` tree, which contains cc-suite's own skills for delegating *to*
> Claude Code (`audit`, `verify`, the `claude-*` set). Antigravity's skill schema
> accepts only `name` and `description` — there is no `allow_implicit_invocation`
> switch like the one that guards these skills on the Codex side — so the prompt is
> the only place the hand-back can be refused. `scripts/agy-runner.mjs` prepends
> `lib/delegation-boundary.mjs` to every prompt it sends, on the foreground,
> background, and resume paths alike. Do not restate it in the command prompt; it is
> already there.

> **No availability ping.** Do not pre-probe `agy`. The first real runner call either
> completes or fails fast (a missing `agy` binary errors in seconds with an install
> hint). Model discovery through `scripts/agy-preflight.sh` is the intended exception
> when a command needs to choose a default model; do not add a second availability
> ping. On any non-`completed` status, go to the calling command's **Fallback** section.

### Three ways agy differs from Codex — read before using

1. **No reasoning-effort flag.** Effort is baked into the model name. `agy models`
   returns display names like `Gemini 3.1 Pro (High)` and `Gemini 3.5 Flash (Low)`.
   Pass the whole string to `--model`. **Never offer the user an effort picker for
   this backend** — `--effort` is accepted by the runner but ignored (and logged).

2. **No machine-readable output.** `agy -p` prints prose, not JSON. There is no cost
   or turn accounting, so `rawOutput` is the entire answer and nothing else is
   available. Do not promise the user token/cost figures for an `agy` job.

3. **Conversation ids are recovered, not reported.** `agy` never prints a conversation
   id. The runner recovers it by diffing `~/.gemini/antigravity-cli/conversations/`
   before and after the call. When two `agy` runs finish concurrently the diff is
   ambiguous and the runner returns `threadId: null` rather than guess. **A null
   `threadId` means resume is unavailable for that job** — say so instead of retrying.

### Sandbox mapping

`agy`'s `--sandbox` is a boolean ("terminal restrictions enabled"), not a level, so
cc-suite's three levels collapse onto two switches. The runner does this for you:

| cc-suite `--sandbox` | agy flags |
|---|---|
| `read-only` | `--sandbox` |
| `workspace-write` | `--mode accept-edits --dangerously-skip-permissions` |
| `danger-full-access` | `--dangerously-skip-permissions` |

Anything that writes needs `--dangerously-skip-permissions`: headless `-p` mode has no
TTY to answer a permission prompt, so without it the run blocks until the deadline and
is killed. Default to `read-only` unless the command genuinely needs to write.

### Canonical call (fresh)

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/agy-runner.mjs" \
  --kind agy \
  --model "{chosen_model}" \
  --sandbox {read-only | workspace-write | danger-full-access} \
  --timeout-ms {deadline_ms} \
  --summary "{brief description}" \
  -- "{prompt}"
```

Returns one JSON object on stdout:

```json
{"jobId":"agy-…","status":"completed","threadId":"<uuid|null>","rawOutput":"…"}
```

`status` is `completed` | `failed` | `stalled`. Exit code is non-zero unless
`completed`.

### Resume

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/agy-runner.mjs" \
  --kind agy --resume "{threadId}" --sandbox read-only \
  --timeout-ms {deadline_ms} -- "{follow-up prompt}"
```

Unlike `codex exec resume`, `agy --conversation` does **not** reject a sandbox flag, so
`--sandbox` may be passed on resume.

### Background

Add `--background`. Returns `{"jobId":"…","status":"queued"}` immediately; poll with
`/cc-suite:status` and collect with `/cc-suite:result`.

### Model discovery

`scripts/agy-preflight.sh` emits the same JSON shape as `codex-preflight.sh`
(5-minute cache; `AGY_PREFLIGHT_NO_CACHE=1` to bypass):

```json
{"backend":"agy","preflight_schema":2,"status":"ok","agy_version":"1.1.2",
 "default_model":"Gemini 3.1 Pro (High)","models":["Gemini 3.1 Pro (High)","…"],
 "reasoning_efforts":[],"sandbox_levels":["read-only","workspace-write","danger-full-access"],
 "workspace_mcp_registered":true,"claude_mcp_registered":true}
```

`reasoning_efforts` is deliberately empty — see limit (1).
`workspace_mcp_registered` is true when the cc-suite-generated workspace profile
declares a `claude-code` server whose arguments carry an exactly pinned
`claude-octopus@<semver>` — not merely when the string appears somewhere in the
file, which a comment or an unrelated entry could satisfy. `claude_mcp_registered`
is true when either the workspace or the global profile registers it, i.e.
whether the reverse direction (`agy` → Claude Code) is available at all; the
global profile is user-managed, so it is matched more loosely than the
workspace one.
