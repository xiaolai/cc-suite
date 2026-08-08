---
description: Tear down the cc-suite artifacts in the current repo. Does not delete CLAUDE.md content or .claude/, only the bridge layer.
allowed-tools:
  - Bash
  - AskUserQuestion
---

# /cc-suite:unbridge

This is a destructive operation. Follow these steps in order.

## 1. Confirm intent

Ask the user via AskUserQuestion before doing anything. List exactly what will be removed:

- `AGENTS.md` (content will be restored to `CLAUDE.md` automatically — no manual copy needed)
- Legacy `GEMINI.md` — only if it contains nothing but `@AGENTS.md` (bare import); hybrid files are left alone
- `.agents/skills` symlink (not the `.claude/skills/` target it points to)
- `.agents/mcp_config.json` only if it carries cc-suite provenance; user-managed entries are preserved
- `.codex/prompts/` (if empty), `.codex/hooks.json`, `.codex/hooks.cc-suite.json`, `.codex/config.toml`
- Empty legacy `.gemini/skills/` and `.gemini/commands/` directories
- the cc-suite sentinel block in `.gitignore`

AGENTS.md restore behavior:
- `CLAUDE.md` is a bare `@AGENTS.md` import (nothing else) → content is restored to `CLAUDE.md` automatically
- `CLAUDE.md` has its own content → `AGENTS.md` is backed up as `AGENTS.md.cc-suite-backup` before removal; if that name already exists, a numbered suffix is added (`AGENTS.md.cc-suite-backup.1`, `.2`, …)
- `CLAUDE.md` does not exist → `AGENTS.md` content is moved to a new `CLAUDE.md`

What is **never** touched:
- `.claude/`, `.mcp.json`, custom `GEMINI.md`, and non-empty legacy `.gemini/` content

What is removed **only if cc-suite generated it**:
- `.codex/hooks.json` — only if it was written by `bridge_hooks.py` (carries a `_cc_bridge_version` marker) AND contains only the five shared events; otherwise left alone
- `.codex/config.toml` — only the cc-suite-mcp sentinel block is removed; other config is preserved

If the user does not confirm, stop.

## 2. Run the unbridge script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/unbridge.sh"
```

The script handles AGENTS.md content safely based on CLAUDE.md state (see conflict cases above). `.codex/hooks.json` and `.codex/config.toml` are only modified if cc-suite generated their content. If the script exits non-zero, report the error and stop.

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
