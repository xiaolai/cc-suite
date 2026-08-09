"""Shared validation for the claude-octopus version pin.

The pin is interpolated into MCP registrations (TOML tables, JSON entries) that
decide which package version every advisor and bridge boots. A loose value —
empty, `latest`, `1.2`, or injected TOML — silently defeats the pinning contract
while passing a non-empty or character-class check, so every consumer validates
through here rather than inventing its own rule.

Kept import-free of the rest of the tree so a script can add `scripts/lib` to
sys.path and import it with no package plumbing.
"""

from __future__ import annotations

import re
from pathlib import Path

# semver.org's official grammar for an exact version. Rejects `01.2.3`,
# `1.2.3-.`, `1.2.3-alpha..1`, `latest`, and the empty string.
EXACT_SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
    r"(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$"
)


class PinError(RuntimeError):
    """The pin is missing, empty, or not an exact semantic version."""


def is_exact_semver(value: object) -> bool:
    return isinstance(value, str) and bool(EXACT_SEMVER.match(value))


def validate_pin(pin: object, source: object = "claude-octopus-pin.txt") -> str:
    """Return `pin` unchanged when it is an exact semver, else raise PinError."""
    if not isinstance(pin, str) or not pin:
        raise PinError(f"claude-octopus pin is empty or missing: {source}")
    if not is_exact_semver(pin):
        raise PinError(
            f"invalid claude-octopus pin {pin!r} in {source}: "
            "expected an exact semver such as 1.2.3"
        )
    return pin


def read_pin(*candidates: Path) -> str:
    """Read and validate the pin from the first readable candidate path.

    Callers pass their own candidate order so this does not silently change
    which file a given script resolves.
    """
    searched = []
    for candidate in candidates:
        searched.append(str(candidate))
        try:
            raw = Path(candidate).read_text(encoding="utf-8")
        except OSError:
            continue
        return validate_pin("".join(raw.split()), candidate)
    raise PinError(
        "claude-octopus pin file not found (searched: " + ", ".join(searched) + ")"
    )
