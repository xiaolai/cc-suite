#!/usr/bin/env bash
# cc-suite: expose .claude/commands/*.md as Claude skills under .claude/skills/cmd-<name>/.
#
# Skills are written to .claude/skills/ (Claude's native path), not .agents/skills/.
# The .agents/skills → .claude/skills symlink created by bridge_skills.sh makes them
# visible to Codex and Antigravity CLI (`agy`) automatically. Both tools read
# workspace skills from .agents/skills/.
#
# Each generated skill sets allow_implicit_invocation=false so users invoke
# with $cmd-<name> in Codex rather than having it fire automatically.
#
# Idempotent: skips any skill whose SKILL.md already exists.

set -euo pipefail

if [ ! -d .claude/commands ]; then
  printf '· .claude/commands/ does not exist — nothing to bridge\n'
  exit 0
fi

shopt -s nullglob
cmd_files=( .claude/commands/*.md )
shopt -u nullglob

if [ "${#cmd_files[@]}" -eq 0 ]; then
  printf '· no .md files in .claude/commands/ — nothing to bridge\n'
  exit 0
fi

python3 - "${cmd_files[@]}" <<'PY'
from __future__ import annotations
import re, sys
from pathlib import Path


def parse_frontmatter(text: str) -> tuple[dict[str, str], str]:
    """Return (meta, body) split at the closing --- of YAML frontmatter."""
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end == -1:
        return {}, text
    fm_text = text[3:end].strip()
    body = text[end + 4:].lstrip("\n")
    meta: dict[str, str] = {}
    for line in fm_text.splitlines():
        m = re.match(r'^([\w-]+):\s*(.*)', line)
        if m:
            val = m.group(2).strip().strip('"').strip("'")
            if val:
                meta[m.group(1)] = val
    return meta, body


def yaml_scalar(s: str) -> str:
    """Return a safely quoted YAML scalar if the value contains special chars."""
    if re.search(r'[:{}\[\],#&*!|>\'"%@`]', s) or s.startswith(' ') or s.endswith(' '):
        return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return s


def main() -> None:
    files = sys.argv[1:]
    skills_base = Path(".claude/skills")
    skills_base.mkdir(parents=True, exist_ok=True)
    count = 0
    for path_str in files:
        src = Path(path_str)
        name = src.stem
        skill_dir = skills_base / f"cmd-{name}"
        skill_file = skill_dir / "SKILL.md"

        if skill_file.exists():
            print(f"· cmd-{name}: already exists — skipped")
            continue

        text = src.read_text(encoding="utf-8")
        meta, body = parse_frontmatter(text)

        description = meta.get("description") or f"Run the {name} command."
        if "description" not in meta:
            print(f"! cmd-{name}: no description in frontmatter — using default", file=sys.stderr)

        skill_dir.mkdir(parents=True, exist_ok=True)
        (skill_dir / "agents").mkdir(exist_ok=True)

        desc_yaml = yaml_scalar(f"{description} Invoke explicitly with $cmd-{name} in Codex.")
        skill_md = (
            f"---\n"
            f"name: cmd-{name}\n"
            f"description: {desc_yaml}\n"
            f"---\n\n"
            f"{body.rstrip()}\n"
        )
        skill_file.write_text(skill_md, encoding="utf-8")

        # Disable auto-invocation: user must type $cmd-<name> explicitly.
        (skill_dir / "agents" / "openai.yaml").write_text(
            "policy:\n  allow_implicit_invocation: false\n",
            encoding="utf-8",
        )

        print(f"✓ cmd-{name}: .claude/skills/cmd-{name}/ (from .claude/commands/{name}.md)")
        count += 1

    if count > 0:
        last = Path(files[-1]).stem
        print(f"\n  Skills written to .claude/skills/ and visible to Codex via .agents/skills symlink.")
        print(f"  Invoke in Codex with $cmd-<name>  (e.g. $cmd-{last})")


if __name__ == "__main__":
    main()
PY
