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

import re
import sys
from pathlib import Path

CONFIG = Path(".cc-suite.md")

# Managed sections: heading text -> the full section (heading + body) appended
# verbatim when that heading is absent from the file. Keep this the ONLY place the
# section templates live so init and migration never drift.
MANAGED_SECTIONS: dict[str, str] = {
    "Enabled Tools": """## Enabled Tools

Which coding agents cc-suite bridges in this project. Tick a tool to enable it,
then run `/cc-suite:bridge-tools`. Claude, Codex, and Antigravity use their own
bridges (on by default). Grok / opencode / Qwen / Kimi read AGENTS.md and shared
skills natively — only their MCP config is mirrored, each to its own format.

China note: Qwen, Kimi, and opencode work natively in mainland China; Grok Build
and Antigravity are effectively VPN-only there.

- [x] claude
- [x] codex
- [x] antigravity
- [ ] grok
- [ ] opencode
- [ ] qwen
- [ ] kimi
""",
}


def has_section(text: str, heading: str) -> bool:
    """True if an ATX heading with this exact text already exists (any level)."""
    pattern = rf"^[ \t]*#{{1,6}}[ \t]*{re.escape(heading)}[ \t]*$"
    return re.search(pattern, text, re.IGNORECASE | re.MULTILINE) is not None


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

    CONFIG.write_text(result + "\n", encoding="utf-8")
    print(f"✓ .cc-suite.md: added missing section(s): {', '.join(added)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
