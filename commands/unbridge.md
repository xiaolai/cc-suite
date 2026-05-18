---
description: Tear down the cc-bridge artifacts in the current repo. Does not delete CLAUDE.md content or .claude/, only the bridge layer.
allowed-tools:
  - Bash
  - AskUserQuestion
---

# /cc-bridge:unbridge

This is a destructive operation. Follow these steps in order.

## 1. Confirm intent

Ask the user via AskUserQuestion before doing anything. List exactly what will be removed:

- `AGENTS.md` (content will be restored to `CLAUDE.md` automatically — no manual copy needed)
- `GEMINI.md`
- `.agents/skills` symlink (not the `.claude/skills/` target it points to)
- `.codex/prompts/` (if empty), `.codex/hooks.json`, `.codex/hooks.cc-bridge.json`, `.codex/config.toml`
- `.gemini/skills/`, `.gemini/commands/` (if empty)
- the cc-bridge sentinel block in `.gitignore`

And what is **never** touched:
- `CLAUDE.md` — restored from `AGENTS.md` before removal, or left alone if it has its own content
- `.claude/`, `.mcp.json`, any non-empty bridge files

If the user does not confirm, stop.

## 2. Run the unbridge script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/unbridge.sh"
```

The script restores `CLAUDE.md` from `AGENTS.md` automatically before deleting `AGENTS.md`, so no content is lost. If the script exits non-zero, report the error and stop.

## 3. Verify state

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

Show the output so the user can confirm the bridge is torn down.

## 4. Report

Print a summary in this format:

```
Unbridge complete:
  ✓ <artifact>   removed
  · <artifact>   skipped — <reason>
  ✓ CLAUDE.md    restored from AGENTS.md  (or: left alone — had own content)

.mcp.json and .claude/ were not modified.
```
