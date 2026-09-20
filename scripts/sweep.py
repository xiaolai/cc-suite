#!/usr/bin/env python3
"""cc-suite: find every project this machine has bridged, and clean up leftovers.

A per-project command can only fix the project it runs in. cc-suite is commonly
installed into dozens of repos at project scope, so a defect in what the bridge
*wrote* leaves every one of them holding a copy — and the SessionStart self-heal
only reaches a repo when a session actually opens there. This sweep closes that
gap: it works from the install records, so one up-to-date plugin can inspect and
repair every project without opening a session in each.

Today it carries exactly one repair, the dead `codex-cli` MCP registration
(scripts/prune_codex_mcp.sh — `codex mcp-server` no longer exists in Codex CLI,
so Claude Code fails to connect to it every session). Version drift is reported
but never "fixed": re-rendering a project's bridge is `/cc-suite:repair`'s job,
in that project, where the user can see it.

Read-only by default. `--fix` applies repairs, then re-verifies each project.

Usage:
    python3 sweep.py                  # report; exit 1 when a project needs action
    python3 sweep.py --json           # machine-readable report
    python3 sweep.py --fix            # apply the safe repairs, then re-verify
    python3 sweep.py --scan DIR       # also look for bridged projects under DIR
    python3 sweep.py --scan DIR --depth 3
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))
from codex_mcp_entry import (  # noqa: E402
    ABSENT, DEAD, FOREIGN, REASONS, SERVER_NAME, classify_document,
)

PLUGIN_ROOT = SCRIPT_DIR.parent
SCHEMA = 1

# Per-project mcp states, in report order.
UNPARSEABLE = "unparseable"
NO_FILE = "no_file"


def config_dir() -> Path:
    """Claude Code's config directory. CLAUDE_CONFIG_DIR wins when set, so a
    non-default install is swept instead of silently reporting nothing."""
    override = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    return Path(override).expanduser() if override else Path.home() / ".claude"


def current_version() -> str | None:
    try:
        manifest = json.loads((PLUGIN_ROOT / ".claude-plugin/plugin.json").read_text())
    except (OSError, ValueError):
        return None
    version = manifest.get("version")
    return version if isinstance(version, str) else None


def install_records() -> tuple[list[dict], list[str]]:
    """(cc-suite install records, notes). The file belongs to Claude Code, not to
    cc-suite: every level is shape-checked rather than trusted, so a schema
    change degrades to "found nothing" with a note instead of a traceback."""
    path = config_dir() / "plugins/installed_plugins.json"
    notes: list[str] = []
    if not path.is_file():
        return [], [f"no install records at {path}"]
    try:
        doc = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return [], [f"{path} is unreadable or not valid JSON"]
    plugins = doc.get("plugins") if isinstance(doc, dict) else None
    if not isinstance(plugins, dict):
        return [], [f"{path} has no plugins object — schema may have changed"]

    records = []
    for key, entries in plugins.items():
        if not (isinstance(key, str) and key.split("@")[0] == "cc-suite"):
            continue
        if isinstance(entries, dict):
            entries = [entries]
        if not isinstance(entries, list):
            notes.append(f"{key}: unexpected record shape — skipped")
            continue
        for entry in entries:
            if isinstance(entry, dict):
                records.append(entry)
    if not records:
        notes.append("cc-suite has no install records — nothing to sweep from")
    return records, notes


def looks_bridged(project: Path) -> bool:
    """Whether cc-suite ever bridged this directory. Used to keep --scan from
    reporting on every directory it walks past."""
    return any(
        (project / marker).exists()
        for marker in (".cc-suite.md", ".cc-suite", "AGENTS.md")
    )


def scan_for_projects(roots: list[Path], depth: int) -> list[Path]:
    """Directories under `roots` that look bridged, to `depth` levels. Needed
    because a user-scope install leaves no per-project record, so a repo bridged
    under one is invisible to install_records()."""
    skip = {".git", "node_modules", ".venv", "venv", "target", "dist", "build",
            "__pycache__", ".next", "Library", ".Trash", ".cache"}
    found = []
    for root in roots:
        root = root.expanduser()
        if not root.is_dir():
            continue
        stack = [(root, 0)]
        while stack:
            current, level = stack.pop()
            if looks_bridged(current):
                found.append(current)
            if level >= depth:
                continue
            try:
                children = list(current.iterdir())
            except OSError:
                continue
            for child in children:
                if child.is_dir() and not child.is_symlink() and child.name not in skip:
                    stack.append((child, level + 1))
    return found


def classify_project(project: Path) -> dict:
    """The state of one project's .mcp.json plus its agy projection."""
    mcp = project / ".mcp.json"
    if not mcp.exists():
        state: str | None = NO_FILE
    else:
        try:
            doc = json.loads(mcp.read_text(encoding="utf-8", errors="replace"))
        except (OSError, ValueError):
            state = UNPARSEABLE
        else:
            state = classify_document(doc)
            if state is None:
                state = UNPARSEABLE

    # The agy projection mirrors .mcp.json, so it holds its own copy of the dead
    # server. Only a cc-suite-owned projection is refreshable; a user-managed one
    # is reported for the user to edit.
    agy = project / ".agents/mcp_config.json"
    agy_has_entry = False
    agy_managed = False
    if agy.exists():
        try:
            doc = json.loads(agy.read_text(encoding="utf-8", errors="replace"))
        except (OSError, ValueError):
            doc = None
        servers = doc.get("mcpServers") if isinstance(doc, dict) else None
        agy_has_entry = isinstance(servers, dict) and SERVER_NAME in servers
        prov = project / ".agents/.cc-suite-mcp.provenance.json"
        agy_managed = prov.is_file()

    return {
        "mcp_state": state,
        "agy_stale_mirror": agy_has_entry,
        "agy_managed": agy_managed,
    }


def needs_action(info: dict) -> bool:
    return info["mcp_state"] in DEAD or info["mcp_state"] == UNPARSEABLE or (
        info["agy_stale_mirror"]
    )


def run(script: str, cwd: Path) -> tuple[bool, str]:
    """Run one plugin script in `cwd`. The CURRENT plugin's scripts are used, not
    the version recorded for that project — a stale install is exactly what the
    sweep exists to repair."""
    proc = subprocess.run(
        ["bash", str(SCRIPT_DIR / script)],
        cwd=str(cwd), capture_output=True, text=True,
    )
    output = (proc.stdout + proc.stderr).strip()
    return proc.returncode == 0, output


def fix_project(project: Path, info: dict) -> dict:
    """Repair one project. Prune first; refresh the agy projection only when the
    project actually has a cc-suite-owned one carrying the stale mirror.

    bridge_mcp.sh owns two projections and re-renders both, so this also rewrites
    that project's .codex/config.toml sentinel block. Same servers, but re-emitted
    at the end of the file — a tracked config.toml can show a one-time relocation
    diff, which the caller is expected to report rather than leave for the user to
    discover. That is why it runs only for projects with the stale mirror, never
    as a blanket refresh."""
    actions: list[str] = []
    if info["mcp_state"] in DEAD:
        ok, output = run("prune_codex_mcp.sh", project)
        actions.append(f"prune_codex_mcp.sh: {'ok' if ok else 'FAILED'} — {output}")
        if not ok:
            return {"actions": actions, "fixed": False}
    if info["agy_stale_mirror"]:
        if info["agy_managed"]:
            ok, output = run("bridge_mcp.sh", project)
            actions.append(f"bridge_mcp.sh: {'ok' if ok else 'FAILED'} — {output}")
        else:
            actions.append(
                ".agents/mcp_config.json has no cc-suite provenance — left alone; "
                f"remove the {SERVER_NAME} entry by hand"
            )
    after = classify_project(project)
    return {"actions": actions, "fixed": not needs_action(after), "after": after}


def detail(info: dict) -> str:
    state = info["mcp_state"]
    parts = []
    if state in DEAD:
        parts.append(f"dead {SERVER_NAME} entry — {REASONS[state]}")
    elif state == UNPARSEABLE:
        parts.append(".mcp.json unreadable or not the shape cc-suite writes")
    elif state == FOREIGN:
        parts.append(f"{SERVER_NAME} entry is not cc-suite's — left alone")
    elif state == ABSENT:
        parts.append("no dead registration")
    else:
        parts.append("no .mcp.json")
    if info["agy_stale_mirror"]:
        parts.append(
            "agy projection still lists it"
            + ("" if info["agy_managed"] else " (user-managed — hand edit)")
        )
    return "; ".join(parts)


def collect(scan_roots: list[Path], depth: int) -> dict:
    records, notes = install_records()
    version = current_version()

    recorded: dict[Path, str | None] = {}
    user_scope = False
    stale: list[str] = []
    for entry in records:
        raw = entry.get("projectPath")
        if not isinstance(raw, str) or not raw:
            if entry.get("scope") == "user":
                user_scope = True
            continue
        project = Path(raw)
        entry_version = entry.get("version")
        # Keep the newest recorded version when a project has several records.
        if project not in recorded or (entry_version or "") > (recorded[project] or ""):
            recorded[project] = entry_version if isinstance(entry_version, str) else None

    projects: dict[Path, dict] = {}
    for project, rec_version in sorted(recorded.items()):
        if not project.is_dir():
            stale.append(str(project))
            continue
        info = classify_project(project)
        info["recorded_version"] = rec_version
        info["source"] = "install-record"
        projects[project] = info

    for project in sorted(scan_for_projects(scan_roots, depth)):
        if project in projects:
            continue
        info = classify_project(project)
        info["recorded_version"] = None
        info["source"] = "scan"
        # A scanned directory with nothing to report is noise; keep only the ones
        # that either need action or were clearly bridged.
        if needs_action(info) or info["mcp_state"] == FOREIGN:
            projects[project] = info

    if user_scope and not scan_roots:
        notes.append(
            "a user-scope install is present, so projects bridged without a "
            "project-scope record are invisible here — add --scan <dir> to look"
        )
    return {
        "schema": SCHEMA,
        "plugin_version": version,
        "projects": {str(p): i for p, i in projects.items()},
        "stale_records": sorted(stale),
        "notes": notes,
    }


def report(result: dict, fixes: dict[str, dict] | None) -> None:
    projects = result["projects"]
    # A repaired project is reported by what was DONE to it, never by its state
    # afterwards: grouping on the post-fix state moved every success into "Clean"
    # and dropped its action lines, so a run that rewrote 31 repos printed no
    # evidence that anything had happened.
    attempted = dict(fixes or {})
    pending = {
        p: i for p, i in projects.items() if needs_action(i) and p not in attempted
    }
    clean = {
        p: i for p, i in projects.items() if p not in attempted and p not in pending
    }

    print(f"cc-suite sweep — {len(projects)} project(s) known to this machine")
    if result["plugin_version"]:
        print(f"running plugin version: {result['plugin_version']}")

    if attempted:
        repaired = sum(1 for o in attempted.values() if o["fixed"])
        print(f"\n  Repaired ({repaired} of {len(attempted)})")
        for path in sorted(attempted):
            outcome = attempted[path]
            print(f"  {'✓' if outcome['fixed'] else '!'} {path}")
            print(f"      was: {outcome['before']}")
            for line in outcome["actions"]:
                print(f"      → {line}")
            if outcome["fixed"]:
                print("      ✓ clean now")
            else:
                print(f"      ! still needs attention: {detail(projects[path])}")

    if pending:
        print(f"\n  Needs action ({len(pending)})")
        for path, info in sorted(pending.items()):
            print(f"  ! {path}")
            print(f"      {detail(info)}")
    elif not attempted:
        print("\n  ✓ no project needs action")

    drift = {
        p: i for p, i in projects.items()
        if i.get("recorded_version") and i["recorded_version"] != result["plugin_version"]
    }
    if drift:
        print(f"\n  Version drift ({len(drift)}) — reported only, run /cc-suite:update there")
        for path, info in sorted(drift.items()):
            print(f"  · {path}  (recorded {info['recorded_version']})")

    if clean:
        print(f"\n  Clean ({len(clean)})")
        for path, info in sorted(clean.items()):
            print(f"  ✓ {path}  — {detail(info)}")

    if result["stale_records"]:
        print(f"\n  Stale install records ({len(result['stale_records'])}) — path no longer exists")
        for path in result["stale_records"]:
            print(f"  · {path}")

    for note in result["notes"]:
        print(f"\n  · {note}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Sweep every cc-suite project on this machine.")
    parser.add_argument("--fix", action="store_true",
                        help="apply the safe repairs instead of only reporting")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--scan", action="append", default=[], metavar="DIR",
                        help="also look for bridged projects under DIR (repeatable)")
    parser.add_argument("--depth", type=int, default=3,
                        help="how many levels --scan descends (default 3)")
    args = parser.parse_args()

    result = collect([Path(d) for d in args.scan], max(0, args.depth))

    fixes: dict[str, dict] = {}
    if args.fix:
        for path, info in result["projects"].items():
            if needs_action(info):
                outcome = fix_project(Path(path), info)
                # Captured before the state is overwritten below: the report has
                # to be able to say what each project looked like going in.
                outcome["before"] = detail(info)
                fixes[path] = outcome
        # Re-read so the reported state is the state on disk, not the plan.
        for path, outcome in fixes.items():
            if "after" in outcome:
                result["projects"][path].update(outcome["after"])

    if args.json:
        print(json.dumps({**result, "fixes": fixes}, indent=2))
    else:
        report(result, fixes if args.fix else None)

    remaining = [p for p, i in result["projects"].items() if needs_action(i)]
    if not args.json:
        if remaining and not args.fix:
            print(f"\n  Run with --fix to repair {len(remaining)} project(s).")
        elif remaining:
            print(f"\n  {len(remaining)} project(s) still need a human — listed above.")
        elif args.fix:
            print("\n  ✓ every project is clean. Restart Claude Code in any session "
                  "that was already open — MCP config is read at session start.")
    return 1 if remaining else 0


if __name__ == "__main__":
    sys.exit(main())
