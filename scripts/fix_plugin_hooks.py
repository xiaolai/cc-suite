#!/usr/bin/env python3
"""cc-suite: set `plugin_hooks = true` under `[features]` in ~/.codex/config.toml.

Section-scoped and idempotent: an existing assignment inside `[features]` is
replaced; otherwise one is inserted there; a `plugin_hooks` key in any other
table is a different TOML key and is left alone. The result is parse-validated
with tomllib before writing (skipped on Python < 3.11, where the section-scoped
edit is still structurally safe).

Used as the auto-fix for the diagnose engine's `plugin_hooks` check.
"""

import pathlib
import re
import sys


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
    try:
        import tomllib

        parsed = tomllib.loads(text)
        features = parsed.get("features")
        if not (isinstance(features, dict) and features.get("plugin_hooks") is True):
            sys.exit(
                "the edit would not result in features.plugin_hooks = true "
                "(unusual TOML layout?) — refusing to write; set it manually"
            )
    except ModuleNotFoundError:
        pass
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — refuse to write anything invalid
        sys.exit(f"refusing to write invalid TOML: {exc}")
    path.write_text(text)
    return f"plugin_hooks = true set under [features] in {path}"


if __name__ == "__main__":
    target = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path.home() / ".codex/config.toml"
    print(apply(target))
