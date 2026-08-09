"""TOML string and comment escaping, shared by the writer and its predictor.

`bridge_mcp.sh` writes `.codex/config.toml`; `diagnose.py` predicts what it
would write and compares. Two implementations of this cannot be allowed to
drift: when they did, a control character in a server's `command`, `args` or
`url` made the prediction differ from the file, and MCP parity reported a
permanent problem whose auto fix ran successfully and never converged.

Kept import-free of the rest of the tree so a script can add `scripts/lib` to
sys.path and import it with no package plumbing.
"""

from __future__ import annotations

_CTRL_ESCAPES = {
    "\\": "\\\\", "\b": "\\b", "\t": "\\t",
    "\n": "\\n", "\f": "\\f", "\r": "\\r",
}


def escape_ctrl(s: str) -> str:
    """Escape backslashes and every control character.

    A raw newline ends a TOML comment and terminates a basic string, so any
    JSON-decoded value or key interpolated into either must be escaped or it
    can inject arbitrary configuration.
    """
    out: list[str] = []
    for ch in s:
        esc = _CTRL_ESCAPES.get(ch)
        if esc is not None:
            out.append(esc)
        elif ch < " " or ch == "\x7f":
            out.append(f"\\u{ord(ch):04X}")
        else:
            out.append(ch)
    return "".join(out)


def quote_string(s: str) -> str:
    """`s` as a TOML basic string, quotes included."""
    return '"' + escape_ctrl(s).replace('"', '\\"') + '"'
