---
description: "Shared: load project config, run preflight discovery, present model/effort/sandbox choices"
user-invocable: false
---
<!-- Shared partial: dynamic model selection via codex-preflight -->
<!-- Referenced by all commands. Do not use as a standalone command. -->

## Model & Settings Selection

Before starting, discover which Codex models are currently available and check for project-specific configuration.

### Step 0: Load project config (if exists)

Check if `.cc-suite.md` exists in the current working directory. If it does, read it and extract these variables:

- `{config_default_model}` — Default model
- `{config_default_effort}` — Default effort
- `{config_default_sandbox}` — Default sandbox
- `{config_default_audit_type}` — Default audit type (mini or full)
- `{config_focus_instructions}` — Audit Focus additional instructions text
- `{config_skip_patterns}` — Skip patterns (glob list)
- `{config_project_instructions}` — Project-Specific Instructions text

If `.cc-suite.md` does not exist, leave all variables empty and use the calling command's built-in defaults. Do NOT ask the user to run `/init` — it's optional.

**Priority order** (highest wins):
1. User's explicit choice (from AskUserQuestion)
2. Project config (`.cc-suite.md`)
3. Command's built-in defaults

### Step A: Run preflight discovery

Run the preflight script to probe available models:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-preflight.sh"
```

Parse the JSON output. The structure is:

```json
{
  "status": "ok",
  "preflight_schema": 3,
  "codex_version": "...",
  "auth_mode": "...",
  "codex_cloud": false,
  "default_model": "<latest-available-general-model>",
  "models": ["<slug1>", "<slug2>", ...],
  "models_detail": [
    {"slug": "<slug1>", "description": "<description>"},
    ...
  ],
  "unavailable": [],
  "reasoning_efforts": ["low", "medium", "high"],
  "sandbox_levels": ["read-only", "workspace-write", "danger-full-access"]
}
```

### Step B: Handle errors

- If `status` is `"error"` → display the `error` message to the user and **STOP**. Common fixes:
  - `"codex CLI not found"` → tell user to run `npm install -g @openai/codex`
  - `"Not authenticated"` → tell user to run `codex login`
- If `models` is an empty array → tell user "No Codex models are currently available. Check your account/subscription and try `codex login`." and **STOP**.

### Step C: Present choices via AskUserQuestion

Build the `AskUserQuestion` options **dynamically** from the preflight results. Ask all questions at once:

**Question 1 — Model** (from `models` and `models_detail` arrays):

Build the option list dynamically from the preflight results:

1. For each model in the `models` array, look up its `description` from the `models_detail` array (match by `slug`).
2. If `models_detail` is empty or a model has no matching entry, use the model slug as the description.
3. Present each model as an option with its description.

**Determining the recommended model**:
1. If `{config_default_model}` is set AND it's in the available list → use that
2. Otherwise → use `default_model` from preflight, or the **first model** in the `models` array as a backward-compatible fallback. Preflight orders general-purpose models by the catalog's `latest` marker, then descending model version, with Codex priority and catalog order as tie-breakers. Review-only models are excluded from the default choice.

Do NOT hardcode any specific model name as "recommended" — always derive it from the preflight results or config.

**Question 2 — Reasoning effort:**

| Level | Best for |
|-------|----------|
| `minimal` | Smallest possible reasoning budget, when advertised by the selected model |
| `low` | Simple/mechanical tasks, quick checks |
| `medium` | Standard tasks — balanced speed and depth |
| `high` | Complex tasks — thorough, catches subtle issues |
| `xhigh` | Very complex tasks — extended reasoning |
| `max` | Hardest tasks — maximum advertised reasoning depth |
| `ultra` | Maximum reasoning with automatic task delegation, when advertised |

After the model choice is made, look up that model in `models_detail` and use its
`reasoning_efforts` list. Only offer levels present for the selected model. If the
selected model has no per-model metadata (older preflight output), fall back to
the top-level `reasoning_efforts` array for compatibility. Do not use the union
of all models' efforts for a model-specific choice.

Mark `{config_default_effort}` as "(Recommended)" only when it is supported by
the selected model; otherwise choose the calling command's recommendation from
the supported list and tell the user the configured effort was unavailable.

**Question 3 — Sandbox level** (only if the calling command uses sandbox):

| Level | Permissions |
|-------|-------------|
| `read-only` | Read-only, no file changes (dry run) |
| `workspace-write` | Write only within the working directory |
| `danger-full-access` | Full read/write/execute everywhere |

Mark `{config_default_sandbox}` as "(Recommended)" if set, otherwise use the calling command's recommendation.

### Step D: Apply project config to Codex calls

After the user makes their choices, when building the Codex runner call (see `commands/shared/codex-call.md`), you MUST apply config values as follows:

1. **Prompt preamble**: Start with the command's role persona, then MUST append:
   - `{config_focus_instructions}` (if non-empty)
   - `{config_project_instructions}` (if non-empty)

   These are NOT optional — if the config provides them, they MUST be folded into the prompt preamble on every Codex call (there is no separate developer-instructions channel in `codex exec`).

2. **Skip patterns**: Before sending files to Codex, you MUST filter out any files matching `{config_skip_patterns}`. If all files are filtered out, report that and stop.

See `commands/shared/codex-call.md` for the canonical call pattern that enforces these rules.
