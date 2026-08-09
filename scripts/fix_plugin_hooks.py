#!/usr/bin/env python3
"""cc-suite: set `plugin_hooks = true` under `[features]` in ~/.codex/config.toml.

Section-scoped and idempotent: an existing assignment inside `[features]` is
replaced; otherwise one is inserted there; a `plugin_hooks` key in any other
table is a different TOML key and is left alone. The result is parse-validated
with tomllib (or tomli on Python < 3.11) before writing; without a parser the
script refuses to write rather than commit an unverified regex edit.

Used as the auto-fix for the diagnose engine's `plugin_hooks` check.
"""

import os
import pathlib
import re
import sys
import tempfile


def apply(path: pathlib.Path) -> str:
    text = path.read_text() if path.exists() else ""
    # Tolerate leading whitespace and trailing comments on table headers —
    # both are valid TOML. Quoted keys / inline tables are rare in this file;
    # the semantic verification below refuses to write if the edit did not
    # actually take effect.
    header = r"^[ \t]*\[[ \t]*features[ \t]*\][ \t]*(?:#.*)?$"
    m = re.search(rf"(?ms)({header})(.*?)(?=^[ \t]*\[|\Z)", text)
    if m:
        body = m.group(2)
        if re.search(r"(?m)^\s*plugin_hooks\s*=", body):
            body = re.sub(
                r"(?m)^(\s*)plugin_hooks\s*=.*$", r"\1plugin_hooks = true", body, count=1
            )
        else:
            body = "\nplugin_hooks = true" + body
        text = text[: m.start(2)] + body + text[m.end(2) :]
    else:
        text = text.rstrip("\n") + ("\n\n" if text.strip() else "") + "[features]\nplugin_hooks = true\n"
    # A regex edit is only safe when its result can be semantically checked, so
    # an unavailable parser is a refusal, not a silent write.
    try:
        import tomllib
    except ModuleNotFoundError:
        try:
            import tomli as tomllib  # type: ignore[no-redef]
        except ModuleNotFoundError:
            sys.exit(
                f"cannot validate the edited TOML on Python {sys.version_info.major}."
                f"{sys.version_info.minor} (no tomllib, no tomli) — refusing to write; "
                f"add [features] plugin_hooks = true to {path} by hand"
            )
    try:
        parsed = tomllib.loads(text)
    except Exception as exc:  # noqa: BLE001 — refuse to write anything invalid
        sys.exit(f"refusing to write invalid TOML: {exc}")
    features = parsed.get("features")
    if not (isinstance(features, dict) and features.get("plugin_hooks") is True):
        sys.exit(
            "the edit would not result in features.plugin_hooks = true "
            "(unusual TOML layout?) — refusing to write; set it manually"
        )
    # Atomic commit: write a same-directory temp file, then replace. A direct
    # overwrite could truncate the user's global Codex config on interruption.
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        if path.exists():
            os.fchmod(fd, path.stat().st_mode & 0o7777)
        with os.fdopen(fd, "w") as tmp_file:
            tmp_file.write(text)
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    return f"plugin_hooks = true set under [features] in {path}"


if __name__ == "__main__":
    target = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path.home() / ".codex/config.toml"
    print(apply(target))
