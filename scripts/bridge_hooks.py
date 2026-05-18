#!/usr/bin/env python3
"""
cc-bridge: mirror .claude/settings.json hooks → .codex/hooks.json.

Only events supported by both tools are copied:
  SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop
Claude-only events (Notification, SubagentStop, SessionEnd) are skipped with a notice.

Existing .codex/hooks.json is never silently overwritten; if present, the
output is written to .codex/hooks.cc-bridge.json for manual review/merge.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

SHARED_EVENTS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}
CLAUDE_ONLY = {"Notification", "SubagentStop", "SessionEnd"}


def _extract_commands(handlers: list) -> list[str]:
    cmds: list[str] = []
    for group in handlers:
        for hook in group.get("hooks", []):
            cmd = hook.get("command", "")
            if cmd:
                cmds.append(cmd)
    return cmds


def main() -> int:
    src = Path(".claude/settings.json")
    if not src.exists():
        print("· .claude/settings.json does not exist — nothing to bridge")
        return 0
    try:
        claude = json.loads(src.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"! .claude/settings.json is not valid JSON: {e}", file=sys.stderr)
        return 1
    hooks = claude.get("hooks") or {}
    if not hooks:
        print("· .claude/settings.json has no hooks section — nothing to bridge")
        return 0

    mirrored: dict[str, list] = {}
    skipped: list[str] = []
    for event, handlers in hooks.items():
        if event in SHARED_EVENTS:
            mirrored[event] = handlers
        elif event in CLAUDE_ONLY:
            skipped.append(event)
        else:
            skipped.append(f"{event} (unknown)")

    if not mirrored:
        print("· no Codex-compatible hook events found in .claude/settings.json")
        return 0

    # Warn about relative .claude/ paths — verify Codex invokes from repo root.
    for event, handlers in mirrored.items():
        for cmd in _extract_commands(handlers):
            if re.search(r'(?<![/\w])\.claude/', cmd) and not cmd.startswith("/"):
                print(
                    f"⚠ {event}: hook command uses a relative .claude/ path.\n"
                    f"  Codex runs hooks from the project root, so this should resolve correctly,\n"
                    f"  but verify if your hook uses os.getcwd() or relative imports: {cmd!r}"
                )

    Path(".codex").mkdir(exist_ok=True)
    target = Path(".codex/hooks.json")
    if target.exists():
        target = Path(".codex/hooks.cc-bridge.json")
        print(f"! .codex/hooks.json already exists — wrote to {target} for review/merge")

    output = {"_cc_bridge_version": "1", "hooks": mirrored}
    target.write_text(
        json.dumps(output, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"✓ {target}: mirrored events {sorted(mirrored)}")
    if skipped:
        print(f"· skipped Claude-only events: {sorted(skipped)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
