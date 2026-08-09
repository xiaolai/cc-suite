"""Fence-aware Markdown heading scanning for `.cc-suite.md`.

`.cc-suite.md` is a document that both configures cc-suite and documents itself,
so it routinely contains a fenced example of the very section being looked for.
A scanner that ignores fences reads the example instead of the real section —
migration skips a section that is genuinely missing, and the tool selection is
parsed out of a code sample.

Kept import-free of the rest of the tree so a script can add `scripts/lib` to
sys.path and import it with no package plumbing.
"""

from __future__ import annotations

import re

# Per CommonMark: at most three leading spaces (four makes an indented code
# block), and a fence is three or more backticks or tildes.
_FENCE_RE = re.compile(r"^(?P<indent> {0,3})(?P<fence>`{3,}|~{3,})(?P<info>.*)$")


def strip_fenced_blocks(text: str) -> str:
    """`text` with every fenced code block's content blanked out.

    Lines are replaced rather than removed so line numbers, and therefore any
    offsets a caller computed against the original, still line up.
    """
    out: list[str] = []
    fence: str | None = None
    for line in text.splitlines():
        m = _FENCE_RE.match(line)
        if m:
            marker = m.group("fence")
            if fence is None:
                # A backtick fence's info string may not contain a backtick.
                if marker[0] == "`" and "`" in m.group("info"):
                    out.append(line)
                    continue
                fence = marker
                out.append("")
                continue
            if marker[0] == fence[0] and len(marker) >= len(fence) and not m.group("info").strip():
                fence = None
            out.append("")
            continue
        out.append("" if fence is not None else line)
    # splitlines() drops a trailing newline; restore it so a caller that slices
    # by offset sees the same length of document.
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def heading_pattern(heading: str) -> re.Pattern[str]:
    """Matches a real ATX heading with exactly this text, at any level.

    Requires whitespace after the opening hashes (`##Enabled Tools` is not a
    heading), permits an optional closing hash run (`## Enabled Tools ##`), and
    allows at most three leading spaces.
    """
    return re.compile(
        rf"^ {{0,3}}#{{1,6}}[ \t]+{re.escape(heading)}(?:[ \t]+#+)?[ \t]*$",
        re.IGNORECASE,
    )


def has_section(text: str, heading: str) -> bool:
    """True when a real, unfenced ATX heading with this text exists."""
    pattern = heading_pattern(heading)
    return any(pattern.match(line) for line in strip_fenced_blocks(text).splitlines())
