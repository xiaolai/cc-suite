---
name: grok-preflight
description: Check Grok Build (xAI) readiness — binary on PATH, authentication, and available models. Fast and local (no network round-trip).
allowed-tools:
  - Bash
---

# Grok Build Preflight

Verify Grok Build is ready before delegating to it. This is separate from
`/cc-suite:codex-preflight` (Codex) and `/cc-suite:agy-preflight` (Antigravity).

Unlike those two, this check is **fast and local** — it does not round-trip to
xAI. It confirms the `grok` binary is installed and that you're authenticated
(via `XAI_API_KEY` or a `~/.grok/auth.json` session), so `/cc-suite:grok` fails
fast with an actionable hint instead of hanging until the job deadline when Grok
isn't set up. Models are read from Grok's local cache; because Grok keeps model
and effort as separate flags, `reasoning_efforts` is a fixed enum.

## Step 1: Run the preflight script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/grok-preflight.sh"
```

Parse the single JSON object from stdout. Keys mirror `codex-preflight.sh`
(`status`, `grok_version`, `auth_mode`, `default_model`, `models`,
`models_detail`, `reasoning_efforts`, `sandbox_levels`).

## Step 2: Display results

```markdown
## Grok Build Preflight Results

**Status**: {status}
**grok version**: {grok_version}
**Auth mode**: {auth_mode}   (api_key or session)
**Default model**: {default_model}

### Available Models

| Model | Description |
|-------|-------------|
| {slug} | {display_name} — {description} |

### Options

- **Reasoning efforts**: {reasoning_efforts}
- **Sandbox levels**: read-only, workspace-write, danger-full-access
```

## Step 3: Handle errors

If `status` is `"error"`, show the message and the fix keyed on `error_code`:

- `grok_not_found` → install: `curl -fsSL https://x.ai/cli/install.sh | bash`
- `not_authenticated` → `grok login` (or set `XAI_API_KEY`)

> This is a local readiness check: it confirms the binary and that credentials
> exist, not that the token is still valid. An expired session still surfaces at
> call time as a `failed`/`stalled` job.

## Step 4: Summary

- Ready: "Grok is ready. Default model: {default_model}."
- Error: "Grok is not ready — {error}. Fix above, then retry."
