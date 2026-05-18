#!/usr/bin/env python3
"""
cc-bridge: mirror .claude/settings.json hooks → .codex/hooks.json.

Only events supported by both tools are copied:
  SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop
Claude-only events (Notification, SubagentStop, SessionEnd) are skipped with a notice.

Idempotent: writes a `_cc_bridge_version` marker into .codex/hooks.json and,
on re-run, updates that file in place if the marker is present. If a
.codex/hooks.json without the marker exists, it is treated as user-owned
and the new output is written to .codex/hooks.cc-bridge.json instead.

Atomic: writes to a temp file in the same directory, then os.replace()s,
so a concurrent reader never sees a partial file.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

SHARED_EVENTS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}
CLAUDE_ONLY = {"Notification", "SubagentStop", "SessionEnd"}
MARKER_KEY = "_cc_bridge_version"
MARKER_VALUE = "1"


def _extract_commands(handlers: list) -> list[str]:
    cmds: list[str] = []
    if not isinstance(handlers, list):
        return cmds
    for group in handlers:
        if not isinstance(group, dict):
            continue
        for hook in group.get("hooks", []) or []:
            if not isinstance(hook, dict):
                continue
            cmd = hook.get("command", "")
            if cmd:
                cmds.append(cmd)
    return cmds


def _validate_settings(claude: object, src: Path) -> tuple[dict | None, str | None]:
    """Validate .claude/settings.json shape enough that the rest of the script
    can rely on dict-shaped access."""
    if not isinstance(claude, dict):
        return None, f"{src}: top-level JSON must be an object, got {type(claude).__name__}"
    hooks = claude.get("hooks")
    if hooks is None:
        return {}, None  # No hooks section is fine.
    if not isinstance(hooks, dict):
        return None, f"{src}: 'hooks' must be an object, got {type(hooks).__name__}"
    for event, handlers in hooks.items():
        if not isinstance(handlers, list):
            return None, f"{src}: hooks['{event}'] must be a list, got {type(handlers).__name__}"
        for i, group in enumerate(handlers):
            if not isinstance(group, dict):
                return None, f"{src}: hooks['{event}'][{i}] must be an object"
            inner = group.get("hooks", [])
            if not isinstance(inner, list):
                return None, f"{src}: hooks['{event}'][{i}].hooks must be a list"
    return hooks, None


def _atomic_write(target: Path, content: str) -> None:
    """Write `content` to `target` atomically (same-dir tempfile + os.replace)."""
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(target.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, target)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


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

    hooks, err = _validate_settings(claude, src)
    if err is not None:
        print(f"! {err}", file=sys.stderr)
        return 1
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

    # Decide target: bridge-owned files (with our marker) update in place;
    # user-owned files are never silently overwritten — output goes to a
    # side file for the user to review and merge.
    Path(".codex").mkdir(exist_ok=True)
    primary = Path(".codex/hooks.json")
    target = primary
    if primary.exists():
        try:
            existing = json.loads(primary.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            existing = None
        if not isinstance(existing, dict) or existing.get(MARKER_KEY) != MARKER_VALUE:
            target = Path(".codex/hooks.cc-bridge.json")
            print(f"! .codex/hooks.json is user-owned (no cc-bridge marker) — wrote to {target} for review/merge")

    output = {MARKER_KEY: MARKER_VALUE, "hooks": mirrored}
    _atomic_write(target, json.dumps(output, indent=2) + "\n")
    print(f"✓ {target}: mirrored events {sorted(mirrored)}")
    if skipped:
        print(f"· skipped Claude-only events: {sorted(skipped)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
