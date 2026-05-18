---
description: Initialize the Claude / Codex / Gemini bridge in the current repo — AGENTS.md as single source, symlinked skills, optional MCP and hooks.
argument-hint: "[--private] [--description \"...\"]"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskUserQuestion
---

# /cc-bridge:init

You are setting up the cross-tool bridge between Claude Code, Codex CLI, and Gemini CLI in the **current working directory**. Treat the cwd as the project root.

## 1. Gather inputs

Parse `$ARGUMENTS`:

- `--private` → privacy = private (AI config files gitignored).
- `--description "..."` → use as the project's one-line description.

If `--description` is not provided, read the project root for clues (`pyproject.toml` `description = ...`, `package.json` `"description"`, root README's first sentence). Synthesize one line. If nothing usable, ask the user via AskUserQuestion.

If `--private` is not present, default to public (recommended) but confirm with AskUserQuestion if you have any reason to doubt.

## 2. Inspect existing state

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

Show the output. This tells the user what already exists so they know what will change.

## 3. Apply the core bridge

Run the init script with the gathered inputs:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" \
  --description "<one-line description>" \
  $( [ "$privacy" = "private" ] && echo --private )
```

The script is idempotent and:

- Migrates any existing root `CLAUDE.md` content to `AGENTS.md` if `AGENTS.md` does not yet exist (the original content is preserved). If both exist, leaves both alone and warns.
- Writes `CLAUDE.md` and `GEMINI.md` as thin `@AGENTS.md` imports (only if their current content is missing or already an `@AGENTS.md` import — never clobbers substantive content silently).
- Creates `.codex/prompts/`, `.gemini/skills/`, `.gemini/commands/` with `.gitkeep`.
- Creates a minimal `.codex/config.toml` if one doesn't exist.
- Symlinks `.agents/skills` → `.claude/skills` if `.claude/skills/` exists (Codex's skill scan path).
- Writes a `.gitignore` block (idempotent — appended only if the cc-bridge sentinel is missing).
- If `--private`, the .gitignore block additionally gitignores all bridge artifacts.

If the script exits non-zero, report the error output and stop.

## 4. Register Codex as a tool for Claude (optional)

Ask the user via AskUserQuestion whether to register the Codex MCP server in `.mcp.json`, so Claude Code can invoke Codex as a tool. If yes:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/mcp_codex.sh"
```

This adds (or merges) the `codex-cli` MCP server to the repo's `.mcp.json`.

## 5. Mirror project MCP servers to Codex (optional)

Ask the user via AskUserQuestion whether to mirror existing `.mcp.json` servers into `.codex/config.toml`, so Codex can see them. If yes:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_mcp.sh"
```

This adds a sentinel-guarded `[mcp_servers.*]` block to `.codex/config.toml` for each server in `.mcp.json` not already declared there. Skips entries already present. Note: these entries are only active after the project is trusted in Codex (see `/cc-bridge:status`).

If the script exits non-zero, report the error and show which servers were skipped.

## 6. Mirror hooks to Codex (optional)

If `.claude/settings.json` has a `hooks` section, ask the user via AskUserQuestion whether to mirror them to `.codex/hooks.json`. If yes:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_hooks.py"
```

Only events both tools support are mirrored (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`). Claude-only events (`Notification`, `SubagentStop`, `SessionEnd`) are skipped with a notice.

If the script exits non-zero, report the error and stop.

## 7. Bridge commands as skills (optional)

If `.claude/commands/` exists and has `.md` files, ask the user via AskUserQuestion whether to expose them as Codex skills. If yes:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_commands.sh"
```

Codex has no project-scoped slash commands; this converts each command to a `.agents/skills/cmd-<name>/SKILL.md` with explicit-only invocation (`$cmd-<name>` in Codex).

## 8. Report

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"` once more and show the full output.

Then print a summary in this format:

```
Bridge initialized:
  ✓ <item>   <what changed or was left alone>
  · <item>   skipped — <reason>
  ! <item>   warning — <detail>

Edit `AGENTS.md` to update shared instructions for all three tools.
```

One line per bridge artifact touched. If any step had warnings, list them under a "Warnings:" section.
