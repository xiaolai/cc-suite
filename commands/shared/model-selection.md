---
description: "Shared: load project config, run preflight discovery, present model/effort/sandbox choices"
user-invocable: false
---
<!-- Shared partial: dynamic model selection via codex-preflight -->
<!-- Referenced by the Codex-delegating commands. Do not use as a standalone command. -->

## Model & Settings Selection

Before starting, discover which Codex models are currently available and check for project-specific configuration.

### Step 0: Load project config (if exists)

Check if `.cc-suite.md` exists in the current working directory. If it does, read it and extract these variables:

- `{config_default_model}` — Default model. The literal value `latest` (case-insensitive) is a policy, not a slug: it means "track preflight's `default_model`" (see the recommendation rules in Step C — `latest` and unset resolve differently). Only a concrete slug acts as a pin.
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
    {"slug": "<slug1>", "description": "<description>", "reasoning_efforts": ["low", "medium", "high", ...]},
    ...
  ],
  "unavailable": [],
  "reasoning_efforts": ["low", "medium", "high"],
  "sandbox_levels": ["read-only", "workspace-write", "danger-full-access"]
}
```

### Step B: Handle errors

- If the script itself fails to run, prints nothing, or prints unparseable JSON → treat it exactly like `status: "error"`, using the raw output (or exit error) as the message.
- If `status` is `"error"` → display the `error` message to the user and **STOP**. Common fixes:
  - `"codex CLI not found"` → tell user to run `npm install -g @openai/codex`
  - `"Not authenticated"` → tell user to run `codex login`
- If `models` is an empty array → tell user "No Codex models are currently available. Check your account/subscription and try `codex login`." and **STOP**.

### Step C: Present choices via AskUserQuestion

Build the `AskUserQuestion` options **dynamically** from the preflight results. Ask the **model question first** — the effort options depend on which model is chosen — then ask the effort and sandbox questions together.

**Question 1 — Model** (from `models` and `models_detail` arrays):

1. For each model, look up its `description` from the `models_detail` array (match by `slug`); if `models_detail` is empty or a model has no matching entry, use the slug as the description.
2. If only **one** model is available, select it automatically — tell the user instead of asking a one-option question.
3. `AskUserQuestion` accepts at most four options: present the recommended model first, then the next models in `models` order, capped at four. Mention any omitted slugs in the question text ("also available via Other: …") — the user can type them via "Other".
4. If the user's "Other" answer is not in the `models` array, say it is not in the current catalog and re-ask.

**Determining the recommended model** (throughout, "preflight's default" means `default_model`, or the **first entry** in `models` as the backward-compatible fallback for older preflight output; preflight orders general-purpose models by the catalog's `latest` marker, then descending model version, with Codex priority and catalog order as tie-breakers, and deprioritizes review-only models so they are never the default while a general model exists):

1. If `{config_default_model}` is `latest` → recommend preflight's default.
2. If `{config_default_model}` is unset → use the calling command's built-in model recommendation (e.g. mini audit recommends the second available model); when the command has none, recommend preflight's default.
3. If `{config_default_model}` is a concrete slug AND it's in the available list → recommend that.
4. If `{config_default_model}` is a concrete slug that is NOT in the available list → the pin has gone stale. Recommend preflight's default instead, and state the reason in the recommended option's `description` (e.g. "replaces `.cc-suite.md`'s pin `{config_default_model}`, which is no longer in the Codex catalog"). Do not silently absorb this: **immediately after the model is determined** — after the user's answer, or after auto-selection when only one model is available — and before the command's main work starts or a background job is queued, offer to rewrite the `Default model` line in `.cc-suite.md` — options: `latest` (recommended — it tracks the catalog and cannot go stale again), the model just chosen, or keep the stale line as-is. `/cc-suite:diagnose` detects the same condition.

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
selected model has no per-model metadata, or its `reasoning_efforts` list is
missing or empty (older preflight output), fall back to the top-level
`reasoning_efforts` array for compatibility; if that is also empty, offer the
static options `low` / `medium` / `high`. Do not use the union of all models'
efforts for a model-specific choice.

If more than four levels are supported, present at most four: the window of four
consecutive supported levels (in the table's order) starting two below the
recommended level, clamped to the ends of the list — the user can type any other
supported level via "Other". If only one level is supported, select it
automatically and tell the user. If an "Other" answer is not in the supported
list, say so and re-ask.

Mark `{config_default_effort}` as "(Recommended)" only when it is supported by
the selected model; otherwise recommend the calling command's recommended effort
and tell the user the configured effort was unavailable. If the command's
recommendation is not supported either, recommend the highest supported level.

**Question 3 — Sandbox level** (only if the calling command uses sandbox):

| Level | Permissions |
|-------|-------------|
| `read-only` | Read-only, no file changes (dry run) |
| `workspace-write` | Write only within the working directory |
| `danger-full-access` | Full read/write/execute everywhere |

Mark `{config_default_sandbox}` as "(Recommended)" if set, otherwise use the calling command's recommendation.

### Step D: Apply project config to Codex calls

The prompt preamble is built ONLY by the canonical recipe in `commands/shared/codex-call.md` (persona, provenance disclosure, delegation boundary, optional conventions, config parts). Do not rebuild or partially restate it here — this partial's job is to supply the config values that recipe consumes:

1. **Preamble config parts**: `{config_focus_instructions}` and `{config_project_instructions}` feed parts 5 and 6 of the canonical preamble. They are NOT optional — when the config provides them, they MUST reach every Codex call's preamble (there is no separate developer-instructions channel in `codex exec`).

2. **Skip patterns**: Before sending files to Codex, you MUST filter out any files matching `{config_skip_patterns}`. If all files are filtered out, report that and stop.
