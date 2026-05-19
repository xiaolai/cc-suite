---
name: bridge-hooks
description: Mirror .claude/settings.json hooks into .codex/hooks.json so Codex runs the same hook scripts on the overlapping events.
allowed-tools:
  - Bash
  - Read
---

# /cc-suite:bridge-hooks

Translate the `hooks` section of `.claude/settings.json` into `.codex/hooks.json`. Only events that both tools support are mirrored:

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse`
- `PostToolUse`
- `Stop`

Claude-only events (`Notification`, `SubagentStop`, `SessionEnd`) are skipped with a notice.

The handler shape (event → matcher → handler → `type: "command"`) is the same in both tools, so no command rewriting is needed; the same shell commands (typically invoking `.claude/hooks/*.py`) run from both tools.

Existing `.codex/hooks.json` is **never silently overwritten** — if it exists, the script writes a `.codex/hooks.cc-suite.json` alongside and tells the user to review/merge.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/bridge_hooks.py"
```

Report which events were mirrored and which were skipped. Success criterion: script exits 0 and `.codex/hooks.json` (or `.codex/hooks.cc-suite.json`) is written with at least one event entry.
