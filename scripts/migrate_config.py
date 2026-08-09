#!/usr/bin/env python3
"""Top up .cc-suite.md with cc-suite-managed sections, non-destructively.

As cc-suite gains features it adds new sections to the per-project .cc-suite.md
(e.g. `## Enabled Tools` for the multi-tool bridge). Projects initialized before a
section existed would otherwise never get it. This script is the single source of
truth for those managed sections: it appends any that are absent and leaves all
existing content untouched.

Idempotent. Callers:
  - /cc-suite:init  — after creating the base config, and as the "Add missing
    sections" option when a config already exists.
  - /cc-suite:update — non-interactive migration after a plugin update.
  - /cc-suite:repair — refresh path.

No-op (exit 0) when .cc-suite.md does not exist — init creates it first.
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
import textwrap
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import bridge_tools  # noqa: E402  (canonical tool-profile registry)

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from md_sections import has_section  # noqa: E402

CONFIG = Path(".cc-suite.md")


def _join(names: list[str]) -> str:
    if len(names) < 3:
        return " and ".join(names)
    return ", ".join(names[:-1]) + f", and {names[-1]}"


def _enabled_tools_section() -> str:
    """The `## Enabled Tools` section, rendered from the bridge's tool-profile
    registry. The inventory, the default selection, and the China tiers all come
    from `bridge_tools.PROFILES`/`DEFAULT_TOOLS`, so adding or renaming a tool
    there cannot leave this template describing a different set of tools.

    Prose stays in paragraphs on purpose: `bridge_tools.parse_enabled_tools()`
    reads a leading `- <tool>` bullet as a selection, so a bulleted sentence
    starting with a tool name would enable that tool.
    """
    profiles = bridge_tools.PROFILES
    defaults = set(bridge_tools.DEFAULT_TOOLS)
    own = [t for t, p in profiles.items() if p.get("bridged_by") == "existing"]
    registry = [t for t, p in profiles.items() if p.get("bridged_by") == "registry"]
    native_cn = [t for t, p in profiles.items() if p.get("china_tier") == "A"]
    vpn_cn = [t for t, p in profiles.items() if p.get("china_tier") == "C"]
    intro = textwrap.fill(
        "Which coding agents cc-suite bridges in this project. Tick a tool to "
        "enable it, then run `/cc-suite:bridge-tools`. "
        f"{_join(own)} use their own bridges (ticked by default). "
        f"{_join(registry)} read AGENTS.md and shared skills natively — only "
        "their MCP config is mirrored, each to its own format.",
        width=80,
    )
    china = textwrap.fill(
        f"China note: {_join(native_cn)} work natively in mainland China; "
        f"{_join(vpn_cn)} are effectively VPN-only there.",
        width=80,
    )
    checklist = "\n".join(
        f"- [{'x' if tool_id in defaults else ' '}] {tool_id}" for tool_id in profiles
    )
    return f"## Enabled Tools\n\n{intro}\n\n{china}\n\n{checklist}\n"


# Managed sections: heading text -> the full section (heading + body) appended
# verbatim when that heading is absent from the file. Keep this the ONLY place the
# section templates live so init and migration never drift.
MANAGED_SECTIONS: dict[str, str] = {
    "Enabled Tools": _enabled_tools_section(),
}

# Fence-aware heading detection lives in scripts/lib/md_sections.py because
# bridge_tools.py needs the same rule when it reads `## Enabled Tools`; a second
# copy is how one of them ended up reading a fenced example as the real section.


def main() -> int:
    if not CONFIG.exists():
        print("· .cc-suite.md not present — nothing to migrate (run /cc-suite:init first)")
        return 0

    text = CONFIG.read_text(encoding="utf-8")
    added: list[str] = []
    result = text.rstrip("\n")

    for heading, body in MANAGED_SECTIONS.items():
        if not has_section(text, heading):
            result += "\n\n" + body.rstrip("\n")
            added.append(heading)

    if not added:
        print("· .cc-suite.md already has all managed sections")
        return 0

    # Atomic commit: write a same-directory temp file, then replace — a direct
    # overwrite could truncate the config on interruption.
    fd, tmp_name = tempfile.mkstemp(dir=CONFIG.parent, prefix=f".{CONFIG.name}.", suffix=".tmp")
    try:
        os.fchmod(fd, CONFIG.stat().st_mode & 0o7777)
        with os.fdopen(fd, "w", encoding="utf-8") as tmp_file:
            tmp_file.write(result + "\n")
        os.replace(tmp_name, CONFIG)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    print(f"✓ .cc-suite.md: added missing section(s): {', '.join(added)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
