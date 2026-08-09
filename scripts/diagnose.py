#!/usr/bin/env python3
"""cc-suite structured diagnostic engine.

The single source of truth for "is this project's cc-suite setup healthy?".
The `/cc-suite:diagnose` command and the Codex-facing diagnose skill are thin
wrappers around this engine: they run it, render its buckets, apply the fix
commands it emits, then run it again and diff the two results.

Every check is classified with awareness of the project's Enabled Tools
selection (.cc-suite.md `## Enabled Tools`), so an artifact that is absent
because its tool was deselected is `expected_absent`, not an issue.

Usage:
    python3 diagnose.py            # human-readable buckets
    python3 diagnose.py --json     # machine-readable report
    python3 diagnose.py --no-preflight   # skip the model-pin check's preflight
    python3 diagnose.py --boot-test      # include the network-dependent
                                         # claude-octopus boot/handshake check

Check statuses:
    healthy          — verified fine
    issue            — needs fixing; `fix.auto` holds runnable commands,
                       otherwise `fix.manual` explains the human step
    info             — worth knowing, nothing to fix (never blocks "healthy")
    expected_absent  — absent because the tool is disabled or there is
                       nothing to bridge
    manual           — real gap that only the user can close
    skipped          — check not runnable here (missing binary, preflight
                       error, development checkout, …)

Exit code: 0 when no `issue`/`manual` checks, 1 otherwise (the JSON is the
real contract; the exit code is a convenience for shell callers).
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))
from toml_escape import quote_string  # noqa: E402
PLUGIN_ROOT = SCRIPT_DIR.parent
ROOT = Path.cwd()
SCHEMA = 1

sys.path.insert(0, str(SCRIPT_DIR))
import bridge_agents  # noqa: E402  (canonical advisor frontmatter parser)
import bridge_agy_mcp  # noqa: E402  (canonical Antigravity server translation)
import bridge_hooks  # noqa: E402  (canonical hook-mirror events + marker)
import bridge_tools  # noqa: E402  (registry + enabled-tools parsing)

CLAUDE_SENTINEL_OPEN = ">>> cc-suite-claude-mcp >>>"
CLAUDE_SENTINEL_CLOSE = "<<< cc-suite-claude-mcp <<<"
MCP_SENTINEL_OPEN = "# >>> cc-suite-mcp >>>"
MCP_SENTINEL_CLOSE = "# <<< cc-suite-mcp <<<"
CODEX_CANONICAL = {"type": "stdio", "command": "codex", "args": ["mcp-server"]}


def check(cid: str, label: str, status: str, detail: str,
          auto: list[str] | None = None, manual: str | None = None,
          restart_required: bool = False) -> dict:
    return {
        "id": cid,
        "label": label,
        "status": status,
        "detail": detail,
        "fix": {"auto": auto or [], "manual": manual, "restart_required": restart_required}
        if (auto or manual) else None,
    }


def script(name: str) -> str:
    # shlex.quote: these strings are executed by the wrapper's shell — a path
    # containing quotes/backticks/$() must never become shell-active.
    return shlex.quote(str(PLUGIN_ROOT / "scripts" / name))


def _read(path: Path) -> str | None:
    # errors="replace": a non-UTF-8 artifact must degrade to inspectable text,
    # not crash the whole engine or masquerade as a missing file.
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def _load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError):
        return None


def _source_servers() -> tuple[dict[str, object], bool]:
    """(.mcp.json's mcpServers, source usable). A missing file is usable-and-empty
    — that is exactly how the bridges treat it — while a broken shape is not
    usable: comparing a projection against it would invent findings."""
    path = ROOT / ".mcp.json"
    if not path.exists():
        return {}, True
    doc = _load_json(path)
    if not isinstance(doc, dict):
        return {}, False
    servers = doc.get("mcpServers")
    if servers is None:
        return {}, True
    if not isinstance(servers, dict):
        return {}, False
    return servers, True


# ── individual checks ────────────────────────────────────────────────────────

def check_agents_md() -> dict:
    p = ROOT / "AGENTS.md"
    if not p.is_file():
        return check("agents_md", "AGENTS.md", "issue",
                     "missing — no shared instruction file",
                     auto=[f"bash {script('init.sh')}"])
    size = p.stat().st_size
    if size > 32768:
        return check("agents_md", "AGENTS.md", "manual",
                     f"{size} bytes — exceeds Codex's 32 KiB limit (silent truncation)",
                     manual="trim AGENTS.md below 32 KiB")
    return check("agents_md", "AGENTS.md", "healthy", f"{size} bytes")


def check_claude_md() -> dict:
    p = ROOT / "CLAUDE.md"
    text = _read(p)
    if text is None:
        return check("claude_md", "CLAUDE.md", "issue", "missing — Claude sessions get no instructions",
                     auto=[f"bash {script('init.sh')}"])
    if text.strip() == "@AGENTS.md":
        return check("claude_md", "CLAUDE.md", "healthy", "@AGENTS.md import")
    if re.search(r"^@AGENTS\.md\s*$", text, re.M):
        return check("claude_md", "CLAUDE.md", "manual",
                     "@AGENTS.md import plus other content (hybrid) — Claude reads extra "
                     "instructions the other tools do not",
                     manual="merge the extra content into AGENTS.md, leaving CLAUDE.md as a "
                            "pure @AGENTS.md import")
    return check("claude_md", "CLAUDE.md", "manual",
                 "substantive content, not an @AGENTS.md import — Claude and the other tools read different instructions",
                 manual="merge the content into AGENTS.md (or run /cc-suite:init, which migrates it)")


def check_legacy_google() -> list[dict]:
    out = []
    if (ROOT / "GEMINI.md").is_file() or (ROOT / ".gemini").is_dir():
        out.append(check("legacy_google", "GEMINI.md / .gemini/", "manual",
                         "legacy Google artifacts present — may be deliberate (enterprise Gemini) or leftover",
                         manual="run /cc-suite:migrate-google to migrate or consciously retain them"))
    return out


def check_skills_links(enabled: list[str]) -> list[dict]:
    out = []
    link = ROOT / ".claude/skills/cc-suite"
    if link.is_symlink():
        if link.exists():
            out.append(check("claude_skills_link", ".claude/skills/cc-suite", "healthy",
                             f"→ {os.readlink(link)}"))
        else:
            out.append(check("claude_skills_link", ".claude/skills/cc-suite", "issue",
                             "symlink broken", auto=[f"bash {script('bridge_skills.sh')}"]))
    elif link.is_dir():
        out.append(check("claude_skills_link", ".claude/skills/cc-suite", "issue",
                         "real directory, not a symlink — skills go stale on plugin updates",
                         manual="remove the directory, then run bridge_skills.sh"))
    else:
        out.append(check("claude_skills_link", ".claude/skills/cc-suite", "issue",
                         "missing — plugin skills not exposed", auto=[f"bash {script('bridge_skills.sh')}"]))

    agents_link = ROOT / ".agents/skills"
    # Every bridged tool except Claude itself reads `.agents/skills` — Codex,
    # agy, Grok Build, opencode and Kimi CLI (README, "What each tool picks up
    # on its own"). Naming only Codex and Antigravity made diagnose call a
    # broken symlink "expected absent" on a claude+opencode project, where
    # status.sh correctly flags it. Claude alone reads .claude/skills directly,
    # so the link really is unnecessary there.
    needed = any(tool != "claude" for tool in enabled)
    if not needed:
        out.append(check("agents_skills_link", ".agents/skills", "expected_absent",
                         "no tool that reads .agents/skills is enabled"))
    elif agents_link.is_symlink():
        target = os.readlink(agents_link)
        if target != "../.claude/skills":
            out.append(check("agents_skills_link", ".agents/skills", "manual",
                             f"points at {target} — cc-suite will not overwrite a user symlink",
                             manual="remove it and run bridge_skills.sh to restore ../.claude/skills"))
        elif agents_link.exists():
            out.append(check("agents_skills_link", ".agents/skills", "healthy", "→ ../.claude/skills"))
        else:
            out.append(check("agents_skills_link", ".agents/skills", "issue", "symlink broken",
                             auto=[f"bash {script('bridge_skills.sh')}"]))
    elif agents_link.is_dir():
        out.append(check("agents_skills_link", ".agents/skills", "manual",
                         "real directory, not a symlink",
                         manual="merge its content into .claude/skills, remove it, run bridge_skills.sh"))
    else:
        out.append(check("agents_skills_link", ".agents/skills", "issue",
                         "missing — Codex, agy, Grok, opencode and Kimi cannot see the shared skills",
                         auto=[f"bash {script('bridge_skills.sh')}"]))
    return out


def check_stale_nested_symlinks() -> list[dict]:
    out = []
    legit = {ROOT / ".claude/skills/cc-suite", ROOT / ".agents/skills",
             ROOT / ".agents/skills/cc-suite"}
    for base in (ROOT / ".claude/skills", ROOT / ".agents/skills"):
        if not base.is_dir():
            continue
        for p in base.rglob("cc-suite"):
            if p in legit or not p.is_symlink():
                continue
            if len(p.relative_to(ROOT).parts) > 4:
                continue
            try:
                target = os.readlink(p)
            except OSError:
                continue
            rel = str(p.relative_to(ROOT))
            cid = f"stale_nested_symlink:{rel}"
            if "skills/cc-suite" in target:
                out.append(check(cid, rel, "issue",
                                 f"stale nested symlink (ln -sf residue) → {target}",
                                 auto=[f"rm {shlex.quote(str(p))}", f"bash {script('bridge_skills.sh')}"]))
            else:
                out.append(check(cid, rel, "info",
                                 f"unexpected cc-suite symlink → {target} (not cc-suite residue; left alone)"))
    return out


def check_cache_freshness() -> dict:
    link = ROOT / ".claude/skills/cc-suite"
    if not link.is_symlink():
        return check("cache_freshness", "plugin cache", "skipped", "no skills symlink to compare")
    target = os.readlink(link)
    m = re.search(r"/(\d+\.\d+\.\d+)/", target)
    if not m:
        return check("cache_freshness", "plugin cache", "skipped",
                     "symlink target has no semver (development checkout)")
    manifest = _load_json(PLUGIN_ROOT / ".claude-plugin/plugin.json")
    installed = manifest.get("version") if isinstance(manifest, dict) else None
    if not installed:
        return check("cache_freshness", "plugin cache", "skipped", "plugin manifest unreadable")
    if m.group(1) == installed:
        return check("cache_freshness", "plugin cache", "healthy", f"skills symlink at v{installed}")
    return check("cache_freshness", "plugin cache", "issue",
                 f"skills symlink at v{m.group(1)}, installed plugin is v{installed}",
                 manual="run `claude plugin update cc-suite@xiaolai`, then restart Claude Code and run "
                        "/cc-suite:bridge-skills in the new session (re-bridging from this session would "
                        "repoint to the old cache)",
                 restart_required=True)


def check_codex_artifacts(enabled: list[str]) -> list[dict]:
    out = []
    if "codex" not in enabled:
        out.append(check("codex_artifacts", ".codex/", "expected_absent", "Codex is not enabled"))
        return out
    cfg = ROOT / ".codex/config.toml"
    text = _read(cfg)
    if text is None:
        out.append(check("codex_config", ".codex/config.toml", "issue", "missing",
                         auto=[f"bash {script('init.sh')}"]))
    else:
        toml_error = None
        try:
            import tomllib
            tomllib.loads(text)
        except ModuleNotFoundError:
            pass
        except Exception as exc:  # noqa: BLE001
            toml_error = str(exc)
        if toml_error:
            out.append(check("codex_config", ".codex/config.toml", "issue",
                             f"invalid TOML — Codex ignores the whole file: {toml_error}",
                             manual="repair the TOML by hand, then re-run diagnose"))
        else:
            out.append(check("codex_config", ".codex/config.toml", "healthy", "parses"))

    if (ROOT / ".codex/prompts").is_dir():
        out.append(check("codex_prompts", ".codex/prompts/", "healthy", ""))
    else:
        out.append(check("codex_prompts", ".codex/prompts/", "issue", "missing",
                         auto=[f"bash {script('init.sh')}"]))

    settings_path = ROOT / ".claude/settings.json"
    settings = _load_json(settings_path)
    if settings_path.exists() and not isinstance(settings, dict):
        out.append(check("codex_hooks", ".codex hooks", "manual",
                         ".claude/settings.json is unreadable — cannot judge whether hooks need bridging",
                         manual="fix .claude/settings.json, then re-run diagnose"))
        return out
    src_hooks = settings.get("hooks") if isinstance(settings, dict) else None
    has_hooks = bool(src_hooks)
    # What bridge_hooks.py would mirror right now — the parity target. Comparing
    # against it is what turns "the file parses" into "the file is current".
    expected = sorted(e for e in src_hooks if e in bridge_hooks.SHARED_EVENTS) \
        if isinstance(src_hooks, dict) else []
    hooks = ROOT / ".codex/hooks.json"
    side = ROOT / ".codex/hooks.cc-suite.json"
    primary = _load_json(hooks) if hooks.is_file() else None
    bridge_owned = (isinstance(primary, dict)
                    and primary.get(bridge_hooks.MARKER_KEY) == bridge_hooks.MARKER_VALUE)
    if side.is_file() and not bridge_owned:
        out.append(check("codex_hooks", ".codex hooks", "manual",
                         ".codex/hooks.cc-suite.json is a pending merge (the active hooks file is "
                         "user-owned) — the bridged hooks are NOT live yet",
                         manual="review and merge .codex/hooks.cc-suite.json into .codex/hooks.json"))
        return out
    residue = " (leftover .codex/hooks.cc-suite.json — safe to delete)" if side.is_file() else ""
    if hooks.is_file():
        if primary is None or not isinstance(primary, dict):
            out.append(check("codex_hooks", ".codex hooks", "issue",
                             ".codex/hooks.json is invalid JSON — Codex hooks will not fire",
                             auto=[f"python3 {script('bridge_hooks.py')}"]))
        elif not bridge_owned:
            if expected:
                out.append(check("codex_hooks", ".codex hooks", "issue",
                                 ".codex/hooks.json is user-owned (no cc-suite marker) and the "
                                 f"Claude hooks {expected} are not bridged",
                                 auto=[f"python3 {script('bridge_hooks.py')}"]))
            else:
                out.append(check("codex_hooks", ".codex hooks", "info",
                                 "user-owned .codex/hooks.json — cc-suite has nothing to bridge "
                                 "into it and will not overwrite it"))
        else:
            mirrored_obj = primary.get("hooks")
            mirrored = sorted(mirrored_obj) if isinstance(mirrored_obj, dict) else None
            if mirrored is None:
                out.append(check("codex_hooks", ".codex hooks", "issue",
                                 ".codex/hooks.json carries the cc-suite marker but has no hooks object",
                                 auto=[f"python3 {script('bridge_hooks.py')}"]))
            elif mirrored != expected:
                out.append(check("codex_hooks", ".codex hooks", "issue",
                                 f"bridged hooks are stale: Codex has {mirrored}, "
                                 f".claude/settings.json now mirrors {expected}",
                                 auto=[f"python3 {script('bridge_hooks.py')}"]))
            else:
                out.append(check("codex_hooks", ".codex hooks",
                                 "info" if residue else "healthy",
                                 f"bridged {mirrored}{residue}"))
    elif expected:
        out.append(check("codex_hooks", ".codex hooks", "issue",
                         ".claude/settings.json has hooks but they are not bridged to Codex",
                         auto=[f"python3 {script('bridge_hooks.py')}"]))
    elif has_hooks:
        out.append(check("codex_hooks", ".codex hooks", "expected_absent",
                         "no Codex-compatible hook events to bridge"))
    else:
        out.append(check("codex_hooks", ".codex hooks", "expected_absent", "no hooks to bridge"))
    return out


def check_mcp_codex_cli(enabled: list[str]) -> dict:
    if "codex" not in enabled:
        return check("mcp_codex_cli", ".mcp.json → codex-cli", "expected_absent", "Codex is not enabled")
    doc = _load_json(ROOT / ".mcp.json")
    if doc is None:
        if (ROOT / ".mcp.json").exists():
            return check("mcp_codex_cli", ".mcp.json → codex-cli", "issue", ".mcp.json unreadable",
                         manual="fix the JSON by hand, then run mcp_codex.sh")
        return check("mcp_codex_cli", ".mcp.json → codex-cli", "issue",
                     "no .mcp.json — Claude cannot invoke Codex as an MCP tool",
                     auto=[f"bash {script('mcp_codex.sh')}", f"bash {script('bridge_mcp.sh')}"],
                     restart_required=True)
    if not isinstance(doc, dict) or (
        "mcpServers" in doc and not isinstance(doc["mcpServers"], dict)
    ):
        # mcp_codex.sh refuses these shapes, so an auto-fix would just fail.
        return check("mcp_codex_cli", ".mcp.json → codex-cli", "issue",
                     ".mcp.json has an invalid shape (top level or mcpServers is not an object)",
                     manual="fix the JSON structure by hand, then run mcp_codex.sh")
    servers = doc.get("mcpServers")
    entry = servers.get("codex-cli") if isinstance(servers, dict) else None
    if entry == CODEX_CANONICAL:
        return check("mcp_codex_cli", ".mcp.json → codex-cli", "healthy", "codex mcp-server registered")
    if entry is None:
        return check("mcp_codex_cli", ".mcp.json → codex-cli", "issue", "codex-cli not registered",
                     auto=[f"bash {script('mcp_codex.sh')}", f"bash {script('bridge_mcp.sh')}"],
                     restart_required=True)
    return check("mcp_codex_cli", ".mcp.json → codex-cli", "issue",
                 "stale registration (legacy npm form) — the MCP server loads with the wrong API",
                 auto=[f"bash {script('mcp_codex.sh')}", f"bash {script('bridge_mcp.sh')}"],
                 restart_required=True)


def expected_pin() -> str | None:
    try:
        return "".join((SCRIPT_DIR / "lib/claude-octopus-pin.txt").read_text().split()) or None
    except OSError:
        return None


def registered_octopus_version(config_text: str) -> str | None:
    start = config_text.find(CLAUDE_SENTINEL_OPEN)
    end = config_text.find(CLAUDE_SENTINEL_CLOSE)
    if start == -1 or end == -1 or end < start:
        return None
    m = re.search(r"claude-octopus@([0-9][^\"]*)", config_text[start:end])
    return m.group(1) if m else None


def check_claude_code_registration(enabled: list[str]) -> dict:
    if "codex" not in enabled:
        return check("claude_code_reg", ".codex/config.toml → claude-code", "expected_absent",
                     "Codex is not enabled")
    text = _read(ROOT / ".codex/config.toml")
    if text is None:
        return check("claude_code_reg", ".codex/config.toml → claude-code", "issue",
                     "no .codex/config.toml", auto=[f"bash {script('mcp_claude.sh')}"])
    pin = expected_pin()
    if CLAUDE_SENTINEL_OPEN in text:
        start = text.find(CLAUDE_SENTINEL_OPEN)
        end = text.find(CLAUDE_SENTINEL_CLOSE)
        if end < start:
            return check("claude_code_reg", ".codex/config.toml → claude-code", "issue",
                         "cc-suite-claude-mcp sentinel block is unpaired/mangled",
                         auto=[f"bash {script('mcp_claude.sh')}"])
        block = text[start:end]
        live = registered_octopus_version(text)
        block_ok = ("[mcp_servers.claude-code]" in block
                    and "tool_timeout_sec" in block
                    and re.search(r'(?m)^\s*args\s*=.*claude-octopus@', block))
        if pin and live == pin and block_ok:
            return check("claude_code_reg", ".codex/config.toml → claude-code", "healthy",
                         f"claude-code pinned @{pin}")
        if pin and live == pin:
            return check("claude_code_reg", ".codex/config.toml → claude-code", "issue",
                         "pin matches but the managed block is incomplete "
                         "(table, args, or tool_timeout_sec missing)",
                         auto=[f"bash {script('mcp_claude.sh')}"])
        return check("claude_code_reg", ".codex/config.toml → claude-code", "issue",
                     f"claude-code pinned @{live or '?'} but the plugin expects @{pin or '?'}",
                     auto=[f"bash {script('mcp_claude.sh')}"])
    if re.search(r'^\s*\[mcp_servers\.(claude-code|"claude-code")\]\s*$', text, re.M):
        return check("claude_code_reg", ".codex/config.toml → claude-code", "info",
                     "claude-code registered by another source (not cc-suite-managed) — left alone")
    return check("claude_code_reg", ".codex/config.toml → claude-code", "issue",
                 "claude-code not registered — Codex cannot delegate to Claude",
                 auto=[f"bash {script('mcp_claude.sh')}"])


def _codex_name(name: str) -> str:
    if re.fullmatch(r"[a-zA-Z0-9_-]+", name):
        return name
    return re.sub(r"[^a-zA-Z0-9_-]+", "-", name).strip("-_") or "mcp-server"


def _parse_codex_tables(config: str) -> dict[str, dict]:
    """Real `[mcp_servers.<name>]` tables → their parsed state:

        owner   — the Claude MCP name recorded by bridge_mcp.sh's
                  `# Claude MCP name:` comment, or None when absent.
        managed — the table sits inside the cc-suite MCP sentinel block, so
                  bridge_mcp.sh owns it and rewrites it on every run.
        keys    — raw `key = value` text of the table's own keys. Sub-tables
                  (`[mcp_servers.x.env]`) are separate tables and excluded.

    Every table header resets the current table: without that, a later
    `# Claude MCP name:` comment in an unrelated table would rewrite the
    recorded owner of the preceding one. A substring match would additionally
    accept commented-out tables and let normalized-name collisions mask a
    missing mirror.
    """
    tables: dict[str, dict] = {}
    current: dict | None = None
    managed = False
    for line in config.splitlines():
        s = line.strip()
        if s == MCP_SENTINEL_OPEN:
            managed = True
            continue
        if s == MCP_SENTINEL_CLOSE:
            managed = False
            continue
        if s.startswith("[") and s.endswith("]"):
            m = re.match(r"^\[mcp_servers\.([a-zA-Z0-9_-]+)\]$", s)
            current = (tables.setdefault(m.group(1),
                                         {"owner": None, "managed": managed, "keys": {}})
                       if m else None)
            continue
        if current is None:
            continue
        c = re.match(r"^# Claude MCP name: (.*)$", line)
        if c:
            current["owner"] = c.group(1)
            continue
        kv = re.match(r"^([A-Za-z0-9_-]+)[ \t]*=[ \t]*(.*)$", s)
        if kv:
            current["keys"].setdefault(kv.group(1), kv.group(2).strip())
    return tables


# The same escaper bridge_mcp.sh writes with. A second implementation here
# escaped only backslash and quote, so any control character in a command, arg
# or url made this prediction differ from the file that was actually written —
# and MCP parity reported a permanent problem that re-running never fixed.
_qs = quote_string


def _desired_codex_keys(cfg: object) -> dict[str, str] | None:
    """The `key = value` lines bridge_mcp.sh emits for one .mcp.json server, or
    None when it refuses to mirror the entry (unsupported transport, missing or
    invalid field). Must stay in step with bridge_mcp.sh's `_toml_block` — env
    values are deliberately not mirrored, so they are not compared either."""
    if not isinstance(cfg, dict):
        return None
    transport = cfg.get("type", "stdio")
    if transport == "stdio":
        cmd = cfg.get("command")
        if not cmd or not isinstance(cmd, str):
            return None
        args = cfg.get("args")
        if args is not None and (
            not isinstance(args, list) or not all(isinstance(a, str) for a in args)
        ):
            return None
        env = cfg.get("env")
        if env is None:
            env = {}
        if not isinstance(env, dict) or not all(isinstance(k, str) for k in env):
            return None
        keys = {"command": _qs(cmd)}
        if args:
            keys["args"] = "[" + ", ".join(_qs(a) for a in args) + "]"
        return keys
    if transport in ("sse", "http", "streamable_http"):
        url = cfg.get("url")
        if not url or not isinstance(url, str):
            return None
        token = cfg.get("bearer_token_env_var")
        if token is not None and not isinstance(token, str):
            return None
        keys = {"url": _qs(url)}
        if token:
            keys["bearer_token_env_var"] = _qs(token)
        return keys
    return None


def check_mcp_parity(enabled: list[str]) -> dict:
    if "codex" not in enabled:
        return check("mcp_parity", "MCP parity → Codex", "expected_absent", "Codex is not enabled")
    source, source_ok = _source_servers()
    if not source_ok:
        return check("mcp_parity", "MCP parity → Codex", "skipped",
                     ".mcp.json is unreadable — the desired projection cannot be derived")
    servers = {name: cfg for name, cfg in source.items() if name != "codex-cli"}
    if not servers:
        return check("mcp_parity", "MCP parity → Codex", "expected_absent",
                     "no additional project MCP servers to mirror")
    tables = _parse_codex_tables(_read(ROOT / ".codex/config.toml") or "")

    def table_for(name: str) -> dict | None:
        table = tables.get(_codex_name(name))
        if table is None:
            return None
        owner = table["owner"]
        if owner is None:
            return table if _codex_name(name) == name else None
        expected = name.replace("\\", "\\\\").replace("\r", "\\r").replace("\n", "\\n")
        return table if owner == expected else None

    missing: list[str] = []
    stale: list[str] = []
    unmanaged: list[str] = []
    for name, cfg in servers.items():
        table = table_for(name)
        if table is None:
            missing.append(name)
            continue
        desired = _desired_codex_keys(cfg)
        if desired is None:
            # bridge_mcp.sh cannot mirror this entry at all, so whatever is in
            # the config came from somewhere else — never call it fresh.
            unmanaged.append(f"{name} (not mirrorable by cc-suite)")
            continue
        drift = sorted(k for k, v in desired.items() if table["keys"].get(k) != v)
        if not drift:
            continue
        if table["managed"]:
            stale.append(f"{name} ({', '.join(drift)})")
        else:
            unmanaged.append(f"{name} ({', '.join(drift)})")

    problems = []
    if missing:
        problems.append(f"not mirrored to .codex/config.toml: {', '.join(missing)}")
    if stale:
        problems.append(f"mirrored with stale values: {', '.join(stale)}")
    if problems:
        return check("mcp_parity", "MCP parity → Codex", "issue", "; ".join(problems),
                     auto=[f"bash {script('bridge_mcp.sh')}"])
    if unmanaged:
        return check("mcp_parity", "MCP parity → Codex", "info",
                     f"{len(servers)} server(s) mirrored; user-declared table(s) differ from "
                     f".mcp.json and are not cc-suite-managed: {', '.join(unmanaged)}")
    return check("mcp_parity", "MCP parity → Codex", "healthy", f"{len(servers)} server(s) mirrored")


def check_agy_cli(enabled: list[str]) -> dict:
    if "antigravity" not in enabled:
        return check("agy_cli", "agy CLI", "expected_absent", "Antigravity is not enabled")
    if shutil.which("agy"):
        return check("agy_cli", "agy CLI", "healthy", "on PATH")
    return check("agy_cli", "agy CLI", "manual",
                 "not found on PATH — Antigravity delegation and preflight are unavailable",
                 manual="install Antigravity CLI: curl -fsSL https://antigravity.google/cli/install.sh | bash")


def _desired_agy_servers(source: dict[str, object]) -> tuple[dict[str, dict], str | None]:
    """The exact server map bridge_agy_mcp.py would write, plus a note when part
    of it could not be derived. Built with that module's own translation and its
    own delegation reservation so the comparison cannot drift from what the
    bridge actually emits; its progress reporting is suppressed because this is a
    read-only probe.

    ReservedNameConflict propagates: in that state the bridge writes nothing at
    all, so the caller has to report the conflict rather than per-server
    differences against a projection that will never be made."""
    desired: dict[str, dict] = {}
    sink = io.StringIO()
    # The bridge rejects bad input by exiting, so a read-only probe has to catch
    # SystemExit as well as ordinary errors: a source it refuses is a note here,
    # never a crash of the whole engine.
    with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
        for name, cfg in source.items():
            try:
                translated = bridge_agy_mcp.translate_server(name, cfg)
            except (Exception, SystemExit):  # noqa: BLE001
                return desired, f"{name} could not be translated — projection not fully verified"
            if translated is not None:
                desired[name] = translated
        try:
            bridge_agy_mcp.apply_delegation_reservation(desired)
        except bridge_agy_mcp.ReservedNameConflict:
            raise
        except (Exception, SystemExit):  # noqa: BLE001
            return desired, "claude-octopus pin unreadable — claude-code delegation not verified"
    return desired, None


def check_agy_mcp(enabled: list[str]) -> dict:
    if "antigravity" not in enabled:
        return check("agy_mcp", ".agents/mcp_config.json", "expected_absent", "Antigravity is not enabled")
    target = ROOT / ".agents/mcp_config.json"
    source, source_ok = _source_servers()
    desired: dict[str, dict] = {}
    note: str | None = None
    if not source_ok:
        note = ".mcp.json is unreadable — only provenance was verified"
    else:
        try:
            desired, note = _desired_agy_servers(source)
        except bridge_agy_mcp.ReservedNameConflict as exc:
            # Judged before any target-state branch, and with no auto fix: while
            # that name is taken the bridge refuses to write anything, so every
            # `bash bridge_mcp.sh` offered below would loop on exit 2 while
            # naming a symptom instead of the cause.
            return check("agy_mcp", ".agents/mcp_config.json", "issue", str(exc),
                         manual="rename the 'claude-code' server in .mcp.json — cc-suite "
                                "reserves that name for agy → Claude delegation — then run "
                                f"bash {script('bridge_mcp.sh')}")
    if not target.is_file():
        if not source_ok:
            # The bridge exits 2 on an unreadable .mcp.json, so it can never
            # create this target. Naming the missing file and offering to run
            # the bridge points at the symptom and hands over a button that
            # loops — the cause was already computed one branch above.
            return check("agy_mcp", ".agents/mcp_config.json", "issue",
                         "missing, and .mcp.json is unreadable so the bridge cannot create it",
                         manual="repair .mcp.json (it is not valid JSON), then run "
                                f"bash {script('bridge_mcp.sh')}")
        return check("agy_mcp", ".agents/mcp_config.json", "issue",
                     "missing — agy cannot see the workspace MCP surface",
                     auto=[f"bash {script('bridge_mcp.sh')}"])
    prov_path = ROOT / ".agents/.cc-suite-mcp.provenance.json"
    if not prov_path.is_file():
        return check("agy_mcp", ".agents/mcp_config.json", "info",
                     "user-managed config — cc-suite will not overwrite it")
    doc = _load_json(target)
    servers = doc.get("mcpServers") if isinstance(doc, dict) else None
    if not isinstance(servers, dict):
        return check("agy_mcp", ".agents/mcp_config.json", "issue",
                     "target exists but is invalid (no mcpServers object)",
                     auto=[f"bash {script('bridge_mcp.sh')}"])
    prov = _load_json(prov_path)
    managed = prov.get("managed_servers") if isinstance(prov, dict) else None
    if not isinstance(managed, list) or not all(isinstance(n, str) for n in managed):
        return check("agy_mcp", ".agents/mcp_config.json", "issue",
                     "cc-suite provenance file is invalid",
                     auto=[f"bash {script('bridge_mcp.sh')}"])
    problems: list[str] = []
    conflicting: list[str] = []
    lost = sorted(set(managed) - set(servers))
    if lost:
        problems.append(f"managed server(s) missing from the config: {', '.join(lost)}")
    if source_ok:
        absent = sorted(n for n in desired if n not in servers)
        stale = sorted(n for n in desired
                       if n in servers and n in set(managed) and servers[n] != desired[n])
        conflicting[:] = sorted(n for n in desired
                                if n in servers and n not in set(managed) and servers[n] != desired[n])
        if absent:
            problems.append(f"not projected from .mcp.json: {', '.join(absent)}")
        if stale:
            problems.append(f"projected with stale values: {', '.join(stale)}")
        if conflicting:
            problems.append(
                "user-owned entr(y/ies) shadow the desired projection "
                f"(the bridge refuses to overwrite them): {', '.join(conflicting)}")
    if problems:
        if conflicting:
            # bridge_agy_mcp.py refuses to write at all while a user-owned entry
            # shadows the projection, so nothing here is auto-fixable — not even
            # the absent/stale entries reported alongside it. Emitting an auto
            # would also suppress this manual hint, which is the only actionable
            # instruction (see commands/diagnose.md).
            return check("agy_mcp", ".agents/mcp_config.json", "issue", "; ".join(problems),
                         manual="remove or rename the user-owned entries first — the bridge "
                                "refuses to overwrite them — then run "
                                f"bash {script('bridge_mcp.sh')}")
        return check("agy_mcp", ".agents/mcp_config.json", "issue", "; ".join(problems),
                     auto=[f"bash {script('bridge_mcp.sh')}"])
    detail = f"{len(servers)} server(s), cc-suite-managed"
    if note:
        return check("agy_mcp", ".agents/mcp_config.json", "info", f"{detail} — {note}")
    return check("agy_mcp", ".agents/mcp_config.json", "healthy", detail)


def _advisor_block_complete(name: str, body: str, pin: str | None) -> bool:
    """A cc-suite advisor block is only real when it carries the registration
    bridge_agents.py writes: the server's own table, the npx launcher, and the
    pinned claude-octopus package."""
    quoted = re.escape(name)
    pkg = re.escape(f"claude-octopus@{pin}") if pin else "claude-octopus@"
    return bool(
        re.search(rf'(?m)^\[mcp_servers\.(?:{quoted}|"{quoted}")\]$', body)
        and re.search(r'(?m)^command[ \t]*=[ \t]*"npx"[ \t]*$', body)
        and re.search(rf"(?m)^args[ \t]*=.*{pkg}", body)
    )


def _codex_advisor_blocks(config: str, pin: str | None) -> dict[str, bool]:
    """Advisor name → its managed Codex block is complete. Parsing the sentinel
    pair (rather than testing for the opening marker as a substring) is what
    makes a commented-out, truncated, or unclosed block fail instead of pass."""
    blocks: dict[str, bool] = {}
    name: str | None = None
    body: list[str] = []
    for line in config.splitlines():
        s = line.rstrip()
        if s.startswith(bridge_agents.SENTINEL_OPEN) and s.endswith(">>>"):
            name = s[len(bridge_agents.SENTINEL_OPEN):-len(">>>")].strip()
            body = []
            continue
        if name is not None and s.startswith(bridge_agents.SENTINEL_CLOSE) and s.endswith("<<<"):
            if s[len(bridge_agents.SENTINEL_CLOSE):-len("<<<")].strip() == name:
                blocks[name] = _advisor_block_complete(name, "\n".join(body), pin)
            name = None
            body = []
            continue
        if name is not None:
            body.append(s)
    return blocks


def check_advisors(enabled: list[str]) -> dict:
    agent_dir = ROOT / ".cc-suite/agents"
    declared_files = sorted(agent_dir.glob("*.md")) if agent_dir.is_dir() else []
    if not declared_files:
        return check("advisors", ".cc-suite/agents", "expected_absent", "no advisor agents declared")
    # Compare by NAME, not count — a stale registration with the right count
    # must not pass. Names come from the canonical frontmatter parser in
    # bridge_agents.py (a loose whole-file regex would accept prose `name:`
    # lines and report false health).
    declared = set()
    unparseable = []
    for f in declared_files:
        try:
            declared.add(str(bridge_agents.parse_agent_file(f)["name"]))
        except BaseException:  # noqa: BLE001 — a broken advisor file is a finding, not a crash
            unparseable.append(f.name)
    doc = _load_json(ROOT / ".mcp.json")
    registered = set()
    if isinstance(doc, dict) and isinstance(doc.get("mcpServers"), dict):
        registered = {k for k, v in doc["mcpServers"].items()
                      if isinstance(v, dict) and v.get("_cc_suite_agent")}
    problems = []
    if unparseable:
        problems.append(f"unparseable advisor file(s): {', '.join(unparseable)}")
    if declared - registered:
        problems.append(f"declared but not registered: {', '.join(sorted(declared - registered))}")
    if registered - declared:
        problems.append(f"registered but no longer declared: {', '.join(sorted(registered - declared))}")
    if "codex" in enabled:
        config = _read(ROOT / ".codex/config.toml") or ""
        pin = expected_pin()
        projected = _codex_advisor_blocks(config, pin)
        missing_codex = sorted(n for n in declared if n not in projected)
        incomplete = sorted(n for n in declared if projected.get(n) is False)
        if missing_codex:
            problems.append(f"not projected to Codex: {', '.join(missing_codex)}")
        if incomplete:
            problems.append("Codex projection is incomplete or stale (table, npx command, or "
                            f"claude-octopus@{pin or '?'} args missing): {', '.join(incomplete)}")
    if not problems:
        return check("advisors", ".cc-suite/agents", "healthy",
                     f"{len(declared)} advisor(s) declared and registered")
    return check("advisors", ".cc-suite/agents", "issue", "; ".join(problems),
                 auto=[f"python3 {script('bridge_agents.py')}", f"bash {script('bridge_mcp.sh')}"])


def _gitignore_schema_marker() -> str | None:
    """Current schema marker, single-sourced from ensure_gitignore.sh."""
    text = _read(PLUGIN_ROOT / "scripts/ensure_gitignore.sh") or ""
    m = re.search(r'(?m)^SCHEMA_MARKER="([^"]+)"', text)
    return m.group(1) if m else None


PRIVATE_MODE_MARKER = "cc-suite: PRIVATE mode"
PLUGIN_SCAFFOLD_MARKER = "cc-suite: plugin repo — these are consumer-workspace scaffolds"


def _gitignore_sections() -> tuple[list[str], list[dict]] | None:
    """(entries every block must carry, optional sections), single-sourced from
    ensure_gitignore.sh's heredocs.

    The unconditional block is the heredoc emitted right after the schema
    marker; every later heredoc is conditional. Sections are identified by
    their own marker comments rather than by ordinal position, so adding or
    reordering a conditional block cannot silently remap the requirements.

    Returns None when the base block cannot be located — an unreadable schema
    must fail loudly, not come back empty and let any .gitignore pass.
    """
    text = _read(PLUGIN_ROOT / "scripts/ensure_gitignore.sh") or ""
    anchor = text.find('echo "$SCHEMA_MARKER"')
    if anchor == -1:
        return None
    bodies = [m for m in re.finditer(r"(?ms)^[ \t]*cat <<'GI'\n(.*?)^GI$", text)
              if m.start() > anchor]
    if not bodies:
        return None

    def entries(body: str) -> list[str]:
        return [ln.strip() for ln in body.splitlines()
                if ln.strip() and not ln.strip().startswith("#")]

    base = entries(bodies[0].group(1))
    optional = []
    for m in bodies[1:]:
        body = m.group(1)
        first = next((ln.strip() for ln in body.splitlines() if ln.strip()), "")
        optional.append({
            "anchor": first,
            "entries": entries(body),
            "private": PRIVATE_MODE_MARKER in body,
            "plugin_repo": PLUGIN_SCAFFOLD_MARKER in body,
        })
    return base, optional


def check_gitignore() -> dict:
    text = _read(ROOT / ".gitignore") or ""
    opens = text.count("# >>> cc-suite >>>")
    closes = text.count("# <<< cc-suite <<<")
    if opens == 0 and closes == 0:
        return check("gitignore", ".gitignore", "issue", "no cc-suite block",
                     auto=[f"bash {script('init.sh')}"])
    start = text.find("# >>> cc-suite >>>")
    end = text.find("# <<< cc-suite <<<")
    if opens != 1 or closes != 1 or end < start:
        return check("gitignore", ".gitignore", "issue",
                     "cc-suite block sentinels are unpaired, duplicated, or mangled",
                     auto=[f"bash {script('init.sh')}"])
    block = text[start:end]
    marker = _gitignore_schema_marker()
    if marker and marker not in block:
        return check("gitignore", ".gitignore", "issue",
                     "cc-suite block is at an old schema",
                     auto=[f"bash {script('init.sh')}"])
    schema = _gitignore_sections()
    if schema is None:
        return check("gitignore", ".gitignore", "issue",
                     "cannot read the required entries out of the plugin's ensure_gitignore.sh — "
                     "the block's contents were NOT validated",
                     manual="reinstall or update the cc-suite plugin, then re-run diagnose")
    base, optional = schema
    private = PRIVATE_MODE_MARKER in block
    plugin_repo = ((ROOT / ".claude-plugin/plugin.json").is_file()
                   or (ROOT / ".codex-plugin/plugin.json").is_file())
    required = list(base)
    for section in optional:
        # Mirror ensure_gitignore.sh's mode guards for the sections it labels,
        # and require any other conditional section to be complete once its
        # marker shows the script did emit it here.
        applies = (section["private"] and private) \
            or (section["plugin_repo"] and plugin_repo and not private) \
            or (section["anchor"] and section["anchor"] in block)
        if applies:
            required += section["entries"]
    # Compare whole lines: `.agents/` is a substring of `.agents/skills`, so a
    # substring test would report a missing private-mode entry as present.
    have = {ln.strip() for ln in block.splitlines()}
    missing = list(dict.fromkeys(ln for ln in required if ln not in have))
    if missing:
        return check("gitignore", ".gitignore", "issue",
                     f"cc-suite block is missing required entries: {', '.join(missing)}",
                     auto=[f"bash {script('init.sh')}"],
                     manual="if the entries are still missing afterwards, delete the whole "
                            "`# >>> cc-suite >>>` … `# <<< cc-suite <<<` block and re-run init "
                            "(a block already at the current schema is not rewritten)")
    mode = "private" if private else "public"
    return check("gitignore", ".gitignore", "healthy", f"has current cc-suite block ({mode} mode)")


def check_registry_tools(enabled: list[str]) -> list[dict]:
    registry_tools = [t for t in enabled
                      if bridge_tools.PROFILES.get(t, {}).get("bridged_by") == "registry"]
    try:
        proc = subprocess.run(
            [sys.executable, str(SCRIPT_DIR / "bridge_tools.py"), "--health"],
            capture_output=True, text=True, timeout=30, cwd=ROOT,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"exit {proc.returncode}: {(proc.stderr or proc.stdout).strip()[:200]}")
        report = json.loads(proc.stdout)
        if not isinstance(report, dict) or not isinstance(report.get("tools"), list):
            raise ValueError("health probe produced no tool report")
    except Exception as exc:  # noqa: BLE001
        # A probe that did not run has verified nothing: with registry-backed
        # tools enabled that is an unchecked surface, not a skippable one.
        if not registry_tools:
            return [check("registry_tools", "extra tools", "skipped", f"health probe failed: {exc}")]
        return [check("registry_tools", "extra tools", "issue",
                      f"health probe failed ({exc}) — enabled tool(s) "
                      f"{', '.join(registry_tools)} were NOT checked",
                      manual=f"run `{sys.executable} {script('bridge_tools.py')} --health` in this "
                             "project and fix what it reports")]
    out = []
    for tool in report.get("tools", []):
        cid = f"tool_{tool['id']}"
        if tool["status"] == "healthy":
            out.append(check(cid, tool["display_name"], "healthy", "artifacts wired"))
        else:
            out.append(check(cid, tool["display_name"], "issue", "; ".join(tool["problems"]),
                             auto=[f"python3 {script('bridge_tools.py')}"]))
    return out


def plugin_hooks_enabled(config_text: str) -> bool:
    """True when `[features] plugin_hooks = true` is in effect in a Codex config.

    Parsed with tomllib so valid spellings the fixer accepts (leading whitespace,
    trailing comments, key order) are not misdiagnosed; the line scan is only the
    pre-3.11 fallback. Shared with status.sh so the two readouts cannot disagree.
    """
    try:
        import tomllib
        parsed = tomllib.loads(config_text)
    except ModuleNotFoundError:
        # No tomllib (pre-3.11): tolerate the header/assignment spellings TOML
        # allows — internal whitespace and trailing comments — instead of the
        # exact-match scan that misdiagnosed valid configs the fixer accepts.
        in_features = False
        for line in config_text.splitlines():
            s = line.strip()
            if s.startswith("["):
                in_features = bool(re.match(r"^\[\s*features\s*\]\s*(?:#.*)?$", s))
            elif in_features and re.match(r"^plugin_hooks\s*=\s*true\s*(?:#.*)?$", s):
                return True
        return False
    except Exception:  # noqa: BLE001 — invalid TOML means the flag is not in effect
        return False
    features = parsed.get("features")
    return isinstance(features, dict) and features.get("plugin_hooks") is True


def check_codex_runtime(enabled: list[str]) -> list[dict]:
    if "codex" not in enabled:
        return [check("codex_runtime", "Codex runtime", "expected_absent", "Codex is not enabled")]
    out = []
    if shutil.which("codex"):
        out.append(check("codex_cli", "codex CLI", "healthy", "on PATH"))
    else:
        out.append(check("codex_cli", "codex CLI", "manual",
                         "not found on PATH — every Codex delegation lane is unavailable",
                         manual="install Codex CLI: npm install -g @openai/codex"))
    cfg = Path.home() / ".codex/config.toml"
    text = _read(cfg)
    if text is None:
        out.append(check("codex_user_config", "~/.codex/config.toml", "manual",
                         "not found — is Codex CLI installed?",
                         manual="install Codex CLI: npm install -g @openai/codex"))
        return out

    repo = str(ROOT)
    trusted = False
    in_section = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            in_section = bool(re.match(
                r"^\[projects\s*\.\s*[\"']" + re.escape(repo) + r"[\"']\s*\]$", s))
        elif in_section and re.match(r"trust_level\s*=\s*[\"']trusted[\"']", s):
            trusted = True
            break
    if trusted:
        out.append(check("codex_trust", "project trust", "healthy", "trusted"))
    else:
        out.append(check("codex_trust", "project trust", "manual",
                         "not trusted — hooks, rules, and .codex/config.toml are inert",
                         manual="run `codex` once in this directory and accept the trust prompt"))

    if plugin_hooks_enabled(text):
        out.append(check("plugin_hooks", "plugin_hooks", "healthy", "enabled in ~/.codex/config.toml"))
    else:
        out.append(check("plugin_hooks", "plugin_hooks", "issue",
                         "not set — plugin-bundled Codex hooks are inert",
                         auto=[f"python3 {script('fix_plugin_hooks.py')}"]))
    return out


def check_model_pin(run_preflight: bool) -> dict:
    text = _read(ROOT / ".cc-suite.md")
    if text is None:
        return check("model_pin", ".cc-suite.md → Default model", "expected_absent", "no project config")
    # Scope the field to the `## Defaults` section — prose elsewhere that
    # happens to mention "Default model" must not be parsed as config.
    section = re.search(r"(?ims)^#{1,6}[ \t]*Defaults[ \t]*$(.*?)(?=^#{1,6}[ \t]|\Z)", text)
    scope = section.group(1) if section else text
    fields = re.findall(r"(?im)^-\s*\*\*Default model\*\*:\s*(.*)$", scope)
    if not fields:
        return check("model_pin", ".cc-suite.md → Default model", "expected_absent", "no Default model field")
    if len(fields) > 1:
        return check("model_pin", ".cc-suite.md → Default model", "info",
                     f"field appears {len(fields)} times — malformed config; freshness not judged")
    value = fields[0].strip().strip("`").strip()
    if not value:
        return check("model_pin", ".cc-suite.md → Default model", "info",
                     "field is empty — malformed config; freshness not judged")
    if value.lower() == "latest":
        return check("model_pin", ".cc-suite.md → Default model", "healthy",
                     "policy `latest` — resolved via preflight at each call, cannot go stale")
    if not run_preflight:
        return check("model_pin", ".cc-suite.md → Default model", "skipped",
                     f"pinned `{value}` — preflight skipped (--no-preflight)")
    try:
        proc = subprocess.run(
            ["bash", str(SCRIPT_DIR / "codex-preflight.sh")],
            capture_output=True, text=True, timeout=60, cwd=ROOT,
        )
        pf = json.loads(proc.stdout)
    except Exception as exc:  # noqa: BLE001
        return check("model_pin", ".cc-suite.md → Default model", "skipped",
                     f"pinned `{value}` — preflight unavailable ({exc}); staleness cannot be judged")
    if pf.get("status") != "ok":
        return check("model_pin", ".cc-suite.md → Default model", "skipped",
                     f"pinned `{value}` — preflight error; staleness cannot be judged")
    models = pf.get("models") or []
    default = pf.get("default_model") or (models[0] if models else None)
    by_fold = {m.casefold(): m for m in models}
    if value.casefold() in by_fold:
        value = by_fold[value.casefold()]
    if value not in models:
        return check("model_pin", ".cc-suite.md → Default model", "issue",
                     f"pinned `{value}` is no longer in the Codex catalog — model-selecting commands "
                     "warn and fall back to the preflight default on every call",
                     manual="rewrite the `Default model` line in .cc-suite.md to `latest` "
                            "(deterministic fix; a concrete slug only on explicit request)")
    if default and value != default:
        return check("model_pin", ".cc-suite.md → Default model", "info",
                     f"pins `{value}`; catalog latest is `{default}` — deliberate pins are fine, just visible")
    return check("model_pin", ".cc-suite.md → Default model", "healthy", f"pinned `{value}` (catalog latest)")


def check_boot(enabled: list[str]) -> dict:
    if "codex" not in enabled:
        return check("boot_test", "claude-octopus boot test", "expected_absent", "Codex is not enabled")
    text = _read(ROOT / ".codex/config.toml") or ""
    version = registered_octopus_version(text)
    label = f"registered @{version}" if version else "no cc-suite registration — expected-pin smoke test"
    cmd = ["node", str(SCRIPT_DIR / "lib/boot_test_claude_mcp.mjs")]
    if version:
        cmd.append(version)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120, cwd=ROOT)
    except Exception as exc:  # noqa: BLE001
        return check("boot_test", "claude-octopus boot test", "skipped", f"could not run: {exc}")
    if proc.returncode == 0:
        return check("boot_test", "claude-octopus boot test", "healthy", f"handshake ok ({label})")
    return check("boot_test", "claude-octopus boot test", "issue",
                 f"boot/handshake failed ({label}): {(proc.stderr or proc.stdout).strip()[:200]}",
                 auto=[f"bash {script('mcp_claude.sh')}"],
                 manual="if it still fails after re-registration, the pin may be broken on this machine — "
                        "escalate to the cc-suite maintainer")


# ── engine ───────────────────────────────────────────────────────────────────

def run(run_preflight: bool = True, boot_test: bool = False) -> dict:
    # parse_enabled_tools already returns defaults when the file or section is
    # genuinely absent — an exception here means the config exists but cannot
    # be read/parsed, which must be reported, not silently defaulted.
    config_issue = None
    try:
        enabled = bridge_tools.parse_enabled_tools()
    except Exception as exc:  # noqa: BLE001 — a broken config must not kill the engine
        enabled = list(bridge_tools.DEFAULT_TOOLS)
        config_issue = check(
            "enabled_tools_config", ".cc-suite.md → Enabled Tools", "issue",
            f"could not read the Enabled Tools selection ({exc}) — "
            "reporting against the default tool set",
            manual="fix the `## Enabled Tools` section of .cc-suite.md, then re-run diagnose")
    checks: list[dict] = []
    if config_issue:
        checks.append(config_issue)
    checks.append(check_agents_md())
    checks.append(check_claude_md())
    checks.extend(check_legacy_google())
    checks.extend(check_skills_links(enabled))
    checks.extend(check_stale_nested_symlinks())
    checks.append(check_cache_freshness())
    checks.extend(check_codex_artifacts(enabled))
    checks.append(check_mcp_codex_cli(enabled))
    checks.append(check_claude_code_registration(enabled))
    checks.append(check_mcp_parity(enabled))
    checks.append(check_agy_cli(enabled))
    checks.append(check_agy_mcp(enabled))
    checks.append(check_advisors(enabled))
    checks.append(check_gitignore())
    checks.extend(check_registry_tools(enabled))
    checks.extend(check_codex_runtime(enabled))
    checks.append(check_model_pin(run_preflight))
    if boot_test:
        checks.append(check_boot(enabled))

    summary: dict[str, int] = {}
    for c in checks:
        summary[c["status"]] = summary.get(c["status"], 0) + 1
    return {
        "schema": SCHEMA,
        "root": str(ROOT),
        "plugin_root": str(PLUGIN_ROOT),
        "enabled_tools": enabled,
        "checks": checks,
        "summary": summary,
    }


ICONS = {"healthy": "✓", "issue": "!", "manual": "!", "info": "·",
         "expected_absent": "·", "skipped": "·"}


def render(report: dict) -> None:
    print(f"cc-suite diagnose — {report['root']}")
    print(f"enabled tools: {', '.join(report['enabled_tools'])}")
    buckets = [("issue", "Issues"), ("manual", "Manual action needed"), ("info", "Information"),
               ("healthy", "Healthy"), ("expected_absent", "Expected absent"), ("skipped", "Skipped")]
    for status, title in buckets:
        rows = [c for c in report["checks"] if c["status"] == status]
        if not rows:
            continue
        print(f"\n  {title}")
        for c in rows:
            print(f"  {ICONS[status]} {c['label']:<34} {c['detail']}")
            fix = c.get("fix")
            if fix:
                for cmd in fix["auto"]:
                    print(f"      fix: {cmd}")
                if fix.get("manual"):
                    print(f"      manual: {fix['manual']}")
                if fix.get("restart_required"):
                    print("      (restart Claude Code afterwards)")
    s = report["summary"]
    print(f"\n  {s.get('issue', 0)} issue(s), {s.get('manual', 0)} manual, "
          f"{s.get('healthy', 0)} healthy")


def main(argv: list[str]) -> int:
    as_json = "--json" in argv
    report = run(run_preflight="--no-preflight" not in argv, boot_test="--boot-test" in argv)
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        render(report)
    blocking = report["summary"].get("issue", 0) + report["summary"].get("manual", 0)
    return 1 if blocking else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
