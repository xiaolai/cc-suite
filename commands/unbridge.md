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
- `.codex/prompts/` (if empty), `.codex/hooks.json` and `.codex/hooks.cc-suite.json` (each only if cc-suite generated it), `.codex/config.toml` (sentinel block only)
- Empty legacy `.gemini/skills/` and `.gemini/commands/` directories
- the cc-suite sentinel block in `.gitignore`

AGENTS.md restore behavior:
- cc-suite migrated a pre-existing `CLAUDE.md` at init → that original is restored to `CLAUDE.md` verbatim, without the scaffolding `AGENTS.md` wraps around it
- `CLAUDE.md` is a bare `@AGENTS.md` import (nothing else) → content is restored to `CLAUDE.md` automatically
- `CLAUDE.md` has its own content → `AGENTS.md` is backed up before removal
- `CLAUDE.md` does not exist → `AGENTS.md` content is moved to a new `CLAUDE.md`

Backups the script may leave behind — report every one it prints, they are files the user has to deal with:
- `AGENTS.md.cc-suite-backup` — written whenever `AGENTS.md` is about to be deleted and its content is not already preserved somewhere else. Two paths reach it:
  - `CLAUDE.md` has its own content, so the restore cannot happen — the backup is written unconditionally, even when `AGENTS.md` still matches `init.sh` output byte-for-byte.
  - The content *was* restored, but `AGENTS.md` no longer matches byte-for-byte what `init.sh` generated. init.sh tells users to write their instructions into `AGENTS.md`, so drift from the generated file is content that exists nowhere else.
- `CLAUDE.md.cc-suite-backup` — the pre-bridge `CLAUDE.md` that init saved, kept because it could not be restored (the current `CLAUDE.md` has content of its own). It is moved out of `.cc-suite/`, whose copy a later `/cc-suite:init` would overwrite.
- If either name is taken, a numbered suffix is added (`.1`, `.2`, …). An existing backup is never overwritten.

What is **never** touched:
- `.claude/`, `.mcp.json`, custom `GEMINI.md`, and non-empty legacy `.gemini/` content

What is removed **only if cc-suite generated it**:
- `.codex/hooks.json` — only if it was written by `bridge_hooks.py`: `_cc_bridge_version` must be exactly the string `"1"`, the only top-level keys may be `_cc_bridge_version` and `hooks`, and every event in it must be one of the five shared events. Anything else is left alone.
- `.codex/hooks.cc-suite.json` — the pending-merge side file, held to the same test. A hand-written or hand-edited file at that path is left alone.
- `.codex/config.toml` — only the cc-suite-mcp sentinel block is removed; other config is preserved. If the managed blocks are nested or interleaved, the file is left untouched and the script exits non-zero rather than risk splicing it.

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
  ! <backup>     kept — <what it holds>

.mcp.json and .claude/ were not modified.
```

Include one `!` line per backup file the script reported, naming what it holds. Omit the line entirely when there were none.
