---
name: migrate-google
description: Migrate a legacy Gemini CLI setup to Antigravity CLI and establish the cc-suite workspace bridge
argument-hint: "[--skip-import] [--keep-legacy]"
allowed-tools:
  - Bash
  - AskUserQuestion
---

# Migrate Google CLI Integration

Use this command once when moving an existing project from Gemini CLI to
Antigravity CLI (`agy`). It is intentionally conservative: custom legacy files
are not deleted automatically, and enterprise Gemini access remains an explicit
user choice.

## User Input

```text
$ARGUMENTS
```

Parse `$ARGUMENTS` for these optional flags before running Step 1:

| Flag | Effect |
|------|--------|
| `--skip-import` | Skip Step 2 entirely — do not import legacy extensions or global configuration |
| `--keep-legacy` | Retain every legacy `GEMINI.md` / `.gemini/` file and report them as kept rather than as remaining |
| (neither) | Run all four steps and prompt at the Step 2 import decision |

## Step 1: Inspect the legacy setup

Check for `gemini` on `PATH`, `GEMINI.md`, `.gemini/`, and existing `.agents/`
assets. Do not print credentials or the contents of global configuration files.

If `agy` is not installed, stop and show the official install command:

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

## Step 2: Import legacy extensions when present

If legacy Gemini extensions or global configuration are detected, ask:

```text
AskUserQuestion:
  question: "Import the detected Gemini CLI extensions/configuration into Antigravity?"
  header: "Import legacy"
  options:
    - label: "Import (Recommended)"
      description: "Run agy's official migration and convert supported extensions, skills, commands, and MCP entries"
    - label: "Skip import"
      description: "Create the cc-suite workspace bridge without changing global Google configuration"
    - label: "Cancel"
      description: "Make no changes"
```

If confirmed, run the official migration command:

```bash
agy plugin import gemini
```

This command may update the user's global Antigravity configuration. Report its
output and stop if it fails.

`--skip-import` skips this step. `--keep-legacy` is the default and documents
that custom `GEMINI.md`/`.gemini/` content is retained for enterprise users.

## Step 3: Establish the workspace bridge

Run the idempotent bridge sequence:

```bash
bash    "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"
bash    "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_skills.sh"
bash    "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_codex.sh"
bash    "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_claude.sh"
bash    "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_hooks.py"
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_agents.py"
```

If any script above exits non-zero, report which script failed along with its
error output, then stop before Step 4 — a partial bridge is worse than none.

The MCP bridge produces both `.codex/config.toml` and the generated,
gitignored `.agents/mcp_config.json`. The `.agents/skills` symlink exposes the
same workspace skills to Codex and agy.

## Step 4: Verify

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-preflight.sh"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

Display:

```markdown
## Google CLI Migration

**agy**: {status from agy-preflight.sh}
**Bridge**: {status from status.sh}
**Legacy import**: imported / skipped (--skip-import) / none detected

### Legacy files still present

| Path | Disposition |
|------|-------------|
| {path} | kept (--keep-legacy) / kept (custom content) |

(Write "none" when no legacy files remain.)
```

Do not remove custom `GEMINI.md` or `.gemini` content without a separate user
confirmation; use `/cc-suite:unbridge` only for cc-suite-generated artifacts and
bare `@AGENTS.md` imports.
