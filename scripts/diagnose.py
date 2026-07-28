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

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPT_DIR.parent
ROOT = Path.cwd()
SCHEMA = 1

sys.path.insert(0, str(SCRIPT_DIR))
import bridge_tools  # noqa: E402  (registry + enabled-tools parsing)

CLAUDE_SENTINEL_OPEN = ">>> cc-suite-claude-mcp >>>"
CLAUDE_SENTINEL_CLOSE = "<<< cc-suite-claude-mcp <<<"
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
    if re.search(r"^@AGENTS\.md\s*$", text, re.M):
        return check("claude_md", "CLAUDE.md", "healthy", "@AGENTS.md import")
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
    needed = "codex" in enabled or "antigravity" in enabled
    if not needed:
        out.append(check("agents_skills_link", ".agents/skills", "expected_absent",
                         "neither Codex nor Antigravity is enabled"))
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
                         "missing — Codex/agy cannot see the shared skills",
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
    has_hooks = isinstance(settings, dict) and bool(settings.get("hooks"))
    hooks = ROOT / ".codex/hooks.json"
    side = ROOT / ".codex/hooks.cc-suite.json"
    if hooks.is_file():
        if _load_json(hooks) is None:
            out.append(check("codex_hooks", ".codex hooks", "issue",
                             ".codex/hooks.json is invalid JSON — Codex hooks will not fire",
                             auto=[f"python3 {script('bridge_hooks.py')}"]))
        else:
            out.append(check("codex_hooks", ".codex hooks", "healthy", "bridged"))
    elif side.is_file():
        out.append(check("codex_hooks", ".codex hooks", "manual",
                         ".codex/hooks.cc-suite.json is a pending merge (the active hooks file is "
                         "user-owned) — the bridged hooks are NOT live yet",
                         manual="review and merge .codex/hooks.cc-suite.json into .codex/hooks.json"))
    elif has_hooks:
        out.append(check("codex_hooks", ".codex hooks", "issue",
                         ".claude/settings.json has hooks but they are not bridged to Codex",
                         auto=[f"python3 {script('bridge_hooks.py')}"]))
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


def _parse_codex_tables(config: str) -> dict[str, str | None]:
    """Real [mcp_servers.*] table names → their recorded Claude MCP owner name
    (from bridge_mcp.sh's `# Claude MCP name:` comment), or None. Mirrors the
    parser in status.sh — a substring match would accept commented-out tables
    and let normalized-name collisions mask a missing mirror."""
    tables: dict[str, str | None] = {}
    current = None
    for line in config.splitlines():
        m = re.match(r"^\[mcp_servers\.([a-zA-Z0-9_-]+)\]$", line.strip())
        if m:
            current = m.group(1)
            tables.setdefault(current, None)
            continue
        if current is not None:
            c = re.match(r"^# Claude MCP name: (.*)$", line)
            if c:
                tables[current] = c.group(1)
    return tables


def check_mcp_parity(enabled: list[str]) -> dict:
    if "codex" not in enabled:
        return check("mcp_parity", "MCP parity → Codex", "expected_absent", "Codex is not enabled")
    doc = _load_json(ROOT / ".mcp.json")
    raw = doc.get("mcpServers") if isinstance(doc, dict) else None
    servers = [s for s in raw if s != "codex-cli"] if isinstance(raw, dict) else []
    if not servers:
        return check("mcp_parity", "MCP parity → Codex", "expected_absent",
                     "no additional project MCP servers to mirror")
    tables = _parse_codex_tables(_read(ROOT / ".codex/config.toml") or "")

    def mirrored(name: str) -> bool:
        codex_name = _codex_name(name)
        if codex_name not in tables:
            return False
        owner = tables[codex_name]
        if owner is None:
            return codex_name == name
        return owner == name.replace("\\", "\\\\").replace("\r", "\\r").replace("\n", "\\n")

    missing = [s for s in servers if not mirrored(s)]
    if missing:
        return check("mcp_parity", "MCP parity → Codex", "issue",
                     f"not mirrored to .codex/config.toml: {', '.join(missing)}",
                     auto=[f"bash {script('bridge_mcp.sh')}"])
    return check("mcp_parity", "MCP parity → Codex", "healthy", f"{len(servers)} server(s) mirrored")


def check_agy_cli(enabled: list[str]) -> dict:
    if "antigravity" not in enabled:
        return check("agy_cli", "agy CLI", "expected_absent", "Antigravity is not enabled")
    if shutil.which("agy"):
        return check("agy_cli", "agy CLI", "healthy", "on PATH")
    return check("agy_cli", "agy CLI", "manual",
                 "not found on PATH — Antigravity delegation and preflight are unavailable",
                 manual="install Antigravity CLI: curl -fsSL https://antigravity.google/cli/install.sh | bash")


def check_agy_mcp(enabled: list[str]) -> dict:
    if "antigravity" not in enabled:
        return check("agy_mcp", ".agents/mcp_config.json", "expected_absent", "Antigravity is not enabled")
    target = ROOT / ".agents/mcp_config.json"
    if not target.is_file():
        return check("agy_mcp", ".agents/mcp_config.json", "issue",
                     "missing — agy cannot see the workspace MCP surface",
                     auto=[f"bash {script('bridge_mcp.sh')}"])
    prov_path = ROOT / ".agents/.cc-suite-mcp.provenance.json"
    if prov_path.is_file():
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
        lost = sorted(set(managed) - set(servers))
        if lost:
            return check("agy_mcp", ".agents/mcp_config.json", "issue",
                         f"managed server(s) missing from the config: {', '.join(lost)}",
                         auto=[f"bash {script('bridge_mcp.sh')}"])
        return check("agy_mcp", ".agents/mcp_config.json", "healthy",
                     f"{len(servers)} server(s), cc-suite-managed")
    return check("agy_mcp", ".agents/mcp_config.json", "info",
                 "user-managed config — cc-suite will not overwrite it")


def check_advisors(enabled: list[str]) -> dict:
    agent_dir = ROOT / ".cc-suite/agents"
    declared_files = sorted(agent_dir.glob("*.md")) if agent_dir.is_dir() else []
    if not declared_files:
        return check("advisors", ".cc-suite/agents", "expected_absent", "no advisor agents declared")
    # Compare by NAME, not count — a stale registration with the right count
    # must not pass. The name defaults to the filename stem; an explicit
    # `name:` frontmatter key overrides it (mirrors bridge_agents.py).
    declared = set()
    for f in declared_files:
        text = _read(f) or ""
        m = re.search(r"(?m)^name:\s*(\S+)\s*$", text)
        declared.add(m.group(1) if m else f.stem)
    doc = _load_json(ROOT / ".mcp.json")
    registered = set()
    if isinstance(doc, dict) and isinstance(doc.get("mcpServers"), dict):
        registered = {k for k, v in doc["mcpServers"].items()
                      if isinstance(v, dict) and v.get("_cc_suite_agent")}
    problems = []
    if declared - registered:
        problems.append(f"declared but not registered: {', '.join(sorted(declared - registered))}")
    if registered - declared:
        problems.append(f"registered but no longer declared: {', '.join(sorted(registered - declared))}")
    if "codex" in enabled:
        config = _read(ROOT / ".codex/config.toml") or ""
        missing_codex = sorted(n for n in declared
                               if f"# >>> cc-suite-agent: {n} >>>" not in config)
        if missing_codex:
            problems.append(f"not projected to Codex: {', '.join(missing_codex)}")
    if not problems:
        return check("advisors", ".cc-suite/agents", "healthy",
                     f"{len(declared)} advisor(s) declared and registered")
    return check("advisors", ".cc-suite/agents", "issue", "; ".join(problems),
                 auto=[f"python3 {script('bridge_agents.py')}", f"bash {script('bridge_mcp.sh')}"])


def check_gitignore() -> dict:
    text = _read(ROOT / ".gitignore") or ""
    if "# >>> cc-suite >>>" in text:
        return check("gitignore", ".gitignore", "healthy", "has cc-suite block")
    return check("gitignore", ".gitignore", "issue", "no cc-suite block",
                 auto=[f"bash {script('init.sh')}"])


def check_registry_tools() -> list[dict]:
    try:
        proc = subprocess.run(
            [sys.executable, str(SCRIPT_DIR / "bridge_tools.py"), "--health"],
            capture_output=True, text=True, timeout=30, cwd=ROOT,
        )
        report = json.loads(proc.stdout)
    except Exception as exc:  # noqa: BLE001
        return [check("registry_tools", "extra tools", "skipped", f"health probe failed: {exc}")]
    out = []
    for tool in report.get("tools", []):
        cid = f"tool_{tool['id']}"
        if tool["status"] == "healthy":
            out.append(check(cid, tool["display_name"], "healthy", "artifacts wired"))
        else:
            out.append(check(cid, tool["display_name"], "issue", "; ".join(tool["problems"]),
                             auto=[f"python3 {script('bridge_tools.py')}"]))
    return out


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

    in_features = False
    hooks_on = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            in_features = s == "[features]"
        elif in_features and re.match(r"plugin_hooks\s*=\s*true", s):
            hooks_on = True
            break
    if hooks_on:
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
    try:
        enabled = bridge_tools.parse_enabled_tools()
    except Exception:  # noqa: BLE001 — a broken config must not kill the engine
        enabled = list(bridge_tools.DEFAULT_TOOLS)
    checks: list[dict] = []
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
    checks.extend(check_registry_tools())
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
