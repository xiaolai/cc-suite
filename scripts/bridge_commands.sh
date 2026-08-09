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
# Idempotent: a generated file is refreshed only while it is still cc-suite's —
# its content matches the hash recorded in .claude/skills/.cc-suite-commands.json,
# or matches what generation produces right now. Hand edits are left alone.

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
import hashlib, json, os, re, sys, tempfile
from pathlib import Path

MANIFEST_SCHEMA = 1
MANIFEST_PATH = Path(".claude/skills/.cc-suite-commands.json")
AGENTS_YAML = b"policy:\n  allow_implicit_invocation: false\n"


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


def skill_name(stem: str) -> str:
    """Normalize a command filename to the skill-name grammar: lowercase
    kebab-case ([a-z0-9] runs joined by single hyphens), capped so the full
    name with the cmd- prefix stays within the 64-character skill-name limit."""
    name = re.sub(r'[^a-z0-9]+', '-', stem.lower()).strip('-') or 'command'
    return name[:60].rstrip('-') or 'command'


class Unreadable:
    """A file that exists but could not be read. Distinct from None (absent),
    because absent means 'ours to create' and unreadable means 'we cannot tell
    whose it is' — treating the second as the first would overwrite a file we
    were never able to inspect."""

    __slots__ = ()

    def __repr__(self) -> str:  # pragma: no cover - diagnostic only
        return "<unreadable>"


UNREADABLE = Unreadable()


def read_bytes(path: Path):
    """Bytes, None when absent, or UNREADABLE when it exists but cannot be read.

    A caller that cannot read an existing file must skip that skill, not abort:
    one unreadable SKILL.md in a shared checkout used to take down the whole
    bridge — and with it init, repair, and update, which run under
    `set -euo pipefail`."""
    try:
        return path.read_bytes()
    except FileNotFoundError:
        return None
    except OSError:
        return UNREADABLE


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def default_file_mode() -> int:
    """What open() would have created: 0o666 & ~umask. The umask can only be
    read by setting it, so this runs once at import, before any file exists."""
    mask = os.umask(0)
    os.umask(mask)
    return 0o666 & ~mask


DEFAULT_FILE_MODE = default_file_mode()


def atomic_write(path: Path, data: bytes) -> None:
    """Same-directory temp file + rename, so no reader ever sees a half-written
    skill and an interrupted run leaves the previous content intact. mkstemp
    creates at 0600 and os.replace carries that mode onto the destination, so
    the mode is restored explicitly: an existing file keeps its own, a new one
    gets the umask default."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".cc-suite-tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        try:
            mode = os.stat(path).st_mode & 0o7777
        except FileNotFoundError:
            mode = DEFAULT_FILE_MODE
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def load_manifest() -> dict[str, dict]:
    """Recorded hashes of what cc-suite last generated, per skill name."""
    raw = read_bytes(MANIFEST_PATH)
    if raw is None:
        return {}
    if raw is UNREADABLE:
        print(f"! {MANIFEST_PATH}: unreadable — every existing skill is treated as "
              "hand-edited and left alone", file=sys.stderr)
        return {}
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        doc = None
    if not isinstance(doc, dict) or doc.get("schema") != MANIFEST_SCHEMA:
        print(f"! {MANIFEST_PATH}: unreadable provenance — every existing skill is "
              "treated as hand-edited and left alone", file=sys.stderr)
        return {}
    skills = doc.get("skills")
    if not isinstance(skills, dict):
        return {}
    return {k: v for k, v in skills.items() if isinstance(k, str) and isinstance(v, dict)}


def main() -> None:
    files = sys.argv[1:]
    skills_base = Path(".claude/skills")
    skills_base.mkdir(parents=True, exist_ok=True)
    manifest = load_manifest()
    updated = dict(manifest)
    count = 0
    last_name = ""
    seen: dict[str, str] = {}
    for path_str in files:
        src = Path(path_str)
        name = skill_name(src.stem)
        if name != src.stem:
            print(f"! {src.name}: skill name normalized to cmd-{name}", file=sys.stderr)
        if name in seen:
            print(
                f"! {src.name}: skill name cmd-{name} collides with {seen[name]} — skipped",
                file=sys.stderr,
            )
            continue
        seen[name] = src.name
        key = f"cmd-{name}"
        skill_dir = skills_base / key
        skill_file = skill_dir / "SKILL.md"
        yaml_file = skill_dir / "agents" / "openai.yaml"

        text = src.read_text(encoding="utf-8")
        meta, body = parse_frontmatter(text)

        description = meta.get("description") or f"Run the {name} command."
        if "description" not in meta:
            print(f"! cmd-{name}: no description in frontmatter — using default", file=sys.stderr)

        desc_yaml = yaml_scalar(f"{description} Invoke explicitly with $cmd-{name} in Codex.")
        skill_md = (
            f"---\n"
            f"name: cmd-{name}\n"
            f"description: {desc_yaml}\n"
            f"---\n\n"
            f"{body.rstrip()}\n"
        ).encode("utf-8")

        record = manifest.get(key, {})
        skill_actual = read_bytes(skill_file)
        yaml_actual = read_bytes(yaml_file)
        # Absent counts as owned: a file cc-suite is about to create, or one an
        # interrupted run never finished writing, is ours to (re)generate.
        # Content equal to what generation produces is ours whatever the
        # provenance says — rewriting it would change nothing, and adopting it
        # re-establishes provenance for skills written before it existed or by
        # a run interrupted before the manifest landed.
        if skill_actual is UNREADABLE or yaml_actual is UNREADABLE:
            which = "SKILL.md" if skill_actual is UNREADABLE else "agents/openai.yaml"
            print(f"· cmd-{name}: {which} exists but could not be read — left alone")
            continue

        skill_owned = (skill_actual is None or skill_actual == skill_md
                       or sha(skill_actual) == record.get("skill_sha256"))
        yaml_owned = (yaml_actual is None or yaml_actual == AGENTS_YAML
                      or sha(yaml_actual) == record.get("agents_sha256"))

        if not skill_owned:
            # Nothing in this directory is written: an unowned SKILL.md means
            # the whole skill is the user's, including a deliberately deleted
            # agents/openai.yaml, which cc-suite must not keep resurrecting.
            print(f"· cmd-{name}: SKILL.md edited by hand or predates provenance — "
                  f"left alone (delete .claude/skills/cmd-{name}/ to regenerate)")
            continue

        if not yaml_owned and yaml_actual != AGENTS_YAML:
            print(f"· cmd-{name}: agents/openai.yaml edited by hand — left alone")

        # openai.yaml first, SKILL.md last: SKILL.md is what the next run reads
        # to decide ownership, so an interrupted generation must not leave it
        # behind alone. Both writes are atomic.
        wrote_yaml = yaml_owned and yaml_actual != AGENTS_YAML
        if wrote_yaml:
            atomic_write(yaml_file, AGENTS_YAML)
        wrote_skill = skill_actual != skill_md
        if wrote_skill:
            atomic_write(skill_file, skill_md)

        new_record = {"source": str(src), "skill_sha256": sha(skill_md)}
        # A hand-edited openai.yaml keeps whatever hash it had (usually none),
        # so it stays unowned and is never overwritten on a later run.
        agents_sha = sha(AGENTS_YAML) if yaml_owned else record.get("agents_sha256")
        if agents_sha is not None:
            new_record["agents_sha256"] = agents_sha
        updated[key] = new_record

        if skill_actual is None:
            print(f"✓ cmd-{name}: .claude/skills/cmd-{name}/ (from .claude/commands/{src.name})")
        elif wrote_skill:
            print(f"✓ cmd-{name}: refreshed from .claude/commands/{src.name}")
        elif wrote_yaml:
            print(f"✓ cmd-{name}: restored missing agents/openai.yaml")
        else:
            print(f"· cmd-{name}: up to date")
            continue
        count += 1
        last_name = name

    if updated != manifest:
        atomic_write(
            MANIFEST_PATH,
            (json.dumps({"schema": MANIFEST_SCHEMA, "skills": updated}, indent=2,
                        sort_keys=True) + "\n").encode("utf-8"),
        )

    if count > 0:
        print(f"\n  Skills written to .claude/skills/ and visible to Codex via .agents/skills symlink.")
        print(f"  Invoke in Codex with $cmd-<name>  (e.g. $cmd-{last_name})")


if __name__ == "__main__":
    main()
PY
