#!/usr/bin/env python3
"""
cc-suite: mirror .claude/settings.json hooks → .codex/hooks.json.

Only events supported by both tools are copied:
  SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop
Claude-only events (Notification, SubagentStop, SessionEnd) are skipped with a notice.

Idempotent: writes a `_cc_bridge_version` marker into .codex/hooks.json and,
on re-run, updates that file in place if the marker is present. If a
.codex/hooks.json without the marker exists, it is treated as user-owned
and the new output is written to .codex/hooks.cc-suite.json instead.

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
    """Validate .claude/settings.json shape down to individual hook entries.

    We refuse to mirror a malformed file rather than propagating garbage into
    .codex/hooks.json where Codex would then reject it at runtime.
    """
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
            # matcher, when present, must be a string (it gets pattern-matched at runtime).
            if "matcher" in group and not isinstance(group["matcher"], str):
                return None, f"{src}: hooks['{event}'][{i}].matcher must be a string"
            inner = group.get("hooks", [])
            if not isinstance(inner, list):
                return None, f"{src}: hooks['{event}'][{i}].hooks must be a list"
            for j, hook in enumerate(inner):
                where = f"{src}: hooks['{event}'][{i}].hooks[{j}]"
                if not isinstance(hook, dict):
                    return None, f"{where} must be an object"
                htype = hook.get("type")
                if htype is None:
                    return None, f"{where}.type is required"
                if not isinstance(htype, str):
                    return None, f"{where}.type must be a string, got {type(htype).__name__}"
                if htype == "command":
                    cmd = hook.get("command")
                    if not isinstance(cmd, str) or not cmd:
                        return None, f"{where}.command must be a non-empty string"
                # Other types (prompt/agent) are parsed-but-skipped by Codex per its
                # current spec; we propagate them as-is but require them to be objects.
    return hooks, None


def _atomic_write(target: Path, content: str) -> None:
    """Write `content` to `target` atomically (same-dir tempfile + os.replace).

    Used when we have decided that overwriting target is intentional (e.g.,
    refreshing a bridge-owned file we previously created).
    """
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


def _exclusive_create(target: Path, content: str) -> bool:
    """Create `target` only if it does not already exist (race-free).

    Returns True on success, False if the file already exists (another writer
    won the race or the user manually created the file between our check and
    this call). The caller can then re-evaluate the target.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    try:
        fd = os.open(str(target), flags, 0o644)
    except FileExistsError:
        return False
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(content)
    return True


def _clear_stale_outputs(reason: str) -> None:
    """Remove previously mirrored output when there is nothing left to mirror,
    so hooks removed on the Claude side do not stay active in Codex. Only files
    carrying the cc-suite marker are deleted; user-owned files are left alone."""
    for path in (Path(".codex/hooks.json"), Path(".codex/hooks.cc-suite.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict) and data.get(MARKER_KEY) == MARKER_VALUE:
            path.unlink(missing_ok=True)
            print(f"· removed stale {path} ({reason})")


def _write_fallback(fallback: Path, content: str) -> bool:
    """Write mirror output to the review side file. The bridge owns this path,
    but if something without our marker already sits there, refuse rather than
    clobber what may be a user's in-progress merge or unrelated file."""
    if fallback.exists():
        try:
            existing = json.loads(fallback.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            existing = None
        if not (isinstance(existing, dict) and existing.get(MARKER_KEY) == MARKER_VALUE):
            print(
                f"! {fallback} exists without the cc-suite marker — refusing to overwrite; "
                "remove it and re-run",
                file=sys.stderr,
            )
            return False
    _atomic_write(fallback, content)
    return True


def main() -> int:
    src = Path(".claude/settings.json")
    if not src.exists():
        _clear_stale_outputs("source settings removed")
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
        _clear_stale_outputs("no hooks in source")
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
        _clear_stale_outputs("no Codex-compatible hooks in source")
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
    output_json = json.dumps({MARKER_KEY: MARKER_VALUE, "hooks": mirrored}, indent=2) + "\n"
    fallback = Path(".codex/hooks.cc-suite.json")

    if primary.exists():
        # Existing file: re-read, decide based on marker.
        try:
            existing = json.loads(primary.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            existing = None
        if isinstance(existing, dict) and existing.get(MARKER_KEY) == MARKER_VALUE:
            target = primary
            _atomic_write(target, output_json)
        else:
            target = fallback
            if not _write_fallback(target, output_json):
                return 1
            print(f"! .codex/hooks.json is user-owned (no cc-suite marker) — wrote to {target} for review/merge")
    else:
        # No existing primary: use O_EXCL create to win-or-lose atomically.
        # This closes the TOCTOU window where another process or the user
        # could create primary between our check and our write.
        if _exclusive_create(primary, output_json):
            target = primary
        else:
            # Lost the race — re-evaluate whether the newcomer is bridge-owned.
            try:
                newcomer = json.loads(primary.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                newcomer = None
            if isinstance(newcomer, dict) and newcomer.get(MARKER_KEY) == MARKER_VALUE:
                # Concurrent bridge run wrote the same shape — accept and refresh.
                target = primary
                _atomic_write(target, output_json)
            else:
                target = fallback
                if not _write_fallback(target, output_json):
                    return 1
                print(f"! .codex/hooks.json appeared during write (now user-owned) — wrote to {target}")
    print(f"✓ {target}: mirrored events {sorted(mirrored)}")
    if skipped:
        print(f"· skipped Claude-only events: {sorted(skipped)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
