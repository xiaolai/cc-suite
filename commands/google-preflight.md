---
name: google-preflight
description: Check Antigravity CLI availability, authentication, models, and workspace MCP parity
allowed-tools:
  - Bash
---

# Google Backend Preflight

Check the supported Google terminal backend: Antigravity CLI (`agy`). This is
separate from `/cc-suite:preflight`, which checks Codex.

## Step 1: Run the preflight script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-preflight.sh"
```

Parse the JSON output from stdout. The probe is deadline-bounded and does not
fall back to the deprecated consumer Gemini CLI.

## Step 2: Display results

```markdown
## Antigravity CLI Preflight Results

**Backend**: {backend}
**Status**: {status}
**agy version**: {agy_version}
**Default model**: {default_model}
**Workspace MCP bridge**: {workspace_mcp_registered}
**Claude reverse bridge**: {claude_mcp_registered}

### Available Models

{models, one per row}
```

## Step 3: Handle errors

- `agy_not_found` → install with:
  `curl -fsSL https://antigravity.google/cli/install.sh | bash`
- `agy_not_authenticated` → run `agy` interactively and complete Google sign-in
- `agy_probe_timeout` → check network/authentication, then retry
- Empty `models` → do not continue with an agy delegation; run `agy` interactively

Do not silently substitute `gemini`. Enterprise users who intentionally retain
Gemini CLI should use that tool directly; cc-suite's project bridge targets agy.
