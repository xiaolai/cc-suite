---
name: setup
description: Check Codex readiness and manage the stop-time review gate
argument-hint: "[--enable-review-gate | --disable-review-gate]"
---

## User Input

```text
$ARGUMENTS
```

## Workflow

### Step 1: Parse flags

| Flag | Action |
|------|--------|
| `--enable-review-gate` | Enable the stop-time review gate, then show status |
| `--disable-review-gate` | Disable the stop-time review gate, then show status |
| (empty) | Just show current status |

If enabling the review gate, display a warning first:

```
WARNING: The stop-time review gate will run a Codex adversarial review every time
you end a session. This can:
- Add 1-5 minutes to session end
- Use Codex API credits
- Block session end if issues are found

This creates a Claude→Codex review loop that catches issues but increases usage.
```

Use `AskUserQuestion` with "Enable" and "Cancel" options.

### Step 2: Update review gate config

If the user chose to enable:

```bash
node -e "
  const { setConfig } = await import('${CLAUDE_PLUGIN_ROOT}/scripts/lib/state.mjs');
  setConfig(process.cwd(), 'stopReviewGate', true);
  console.log('Review gate enabled.');
"
```

If the user chose to disable:

```bash
node -e "
  const { setConfig } = await import('${CLAUDE_PLUGIN_ROOT}/scripts/lib/state.mjs');
  setConfig(process.cwd(), 'stopReviewGate', false);
  console.log('Review gate disabled.');
"
```

### Step 3: Run readiness checks

Check each prerequisite:

1. **Node.js**: `node --version` (required >= 18.18.0)
2. **Codex CLI**: `codex --version`
3. **Authentication**: `codex login status`

Antigravity is an independent optional backend. When Google-backed delegation is
needed, run `/cc-suite:google-preflight` separately; it checks `agy`, Google
authentication, model discovery, and the workspace MCP projection. This setup
command does not substitute the deprecated consumer Gemini CLI.

### Step 4: Display status report

```markdown
# Codex Toolkit Setup

Status: {ready / needs attention}

Checks:
- node: {version or "not found"}
- codex CLI: {version or "not found — install: npm install -g @openai/codex"}
- auth: {status or "not authenticated — run: ! codex login"}
- review gate: {enabled / disabled}

{Next steps if any checks failed}
```

### Step 5: Offer configuration

If all checks pass, use AskUserQuestion:

```
AskUserQuestion:
  question: "Codex is ready. What would you like to configure?"
  header: "Next step"
  options:
    - label: "Run /preflight"
      description: "Discover the latest available Codex model and test connectivity"
    - label: "Run /cc-suite:google-preflight"
      description: "Check the optional Antigravity backend and workspace MCP bridge"
    - label: "Run /init"
      description: "Generate a .cc-suite.md config for this project"
    - label: "Toggle review gate"
      description: "Enable or disable the stop-time adversarial review"
    - label: "Done"
      description: "Nothing to configure"
```
