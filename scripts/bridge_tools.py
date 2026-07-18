#!/usr/bin/env python3
"""cc-suite tool-profile bridge engine.

Mirrors the project MCP surface (`.mcp.json` + the pinned claude-octopus server)
into additional coding agents declared as *tool profiles*. This is the scalable
core described in dev-docs/supporting-more-coding-agents.md: adding a tool is a
declarative profile plus a shared emitter, not a bespoke script.

Scope: this engine handles the *newer* tools whose only real bridge work is an
MCP emitter — Grok Build, opencode, Qwen Code, Kimi CLI. Claude Code, Codex CLI,
and Antigravity keep their existing, battle-tested bridge scripts (mcp_claude.sh,
bridge_mcp.sh, bridge_agy_mcp.py). Those three appear in the registry only for
selection/reporting (`bridged_by: "existing"`); the engine never touches them.

Instruction files and skills are NOT mirrored here: every tool this engine
targets reads AGENTS.md natively and reads Claude's / the shared skills paths
directly. The one exception (Qwen wants its own skills symlink) is handled by
the skills linker below.

Security: env-var *values* and remote *headers* are never written into a
mirrored config — they may hold secrets and several targets are committed to
git. Servers that carry them are still mirrored (command/args/url), with the
missing vars reported so the user can add them out of band. This matches the
env-redaction policy in bridge_mcp.sh.

Reads the enabled-tools list from `.cc-suite.md` (`## Enabled Tools`). When the
file or section is absent, defaults to the current three so existing projects
are unaffected.
"""

from __future__ import annotations

import copy
import json
import os
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PIN_FILE = SCRIPT_DIR / "lib" / "claude-octopus-pin.txt"
ROOT = Path.cwd()
SOURCE = ROOT / ".mcp.json"
CONFIG = ROOT / ".cc-suite.md"

# Provenance schema for the JSON targets (opencode/kimi/qwen). Bumped when the
# managed-entry bookkeeping changes shape.
PROV_SCHEMA = 1

# Sentinel guarding the cc-suite block inside TOML targets (grok).
TOML_SENTINEL_OPEN = "# >>> cc-suite-mcp >>>"
TOML_SENTINEL_CLOSE = "# <<< cc-suite-mcp <<<"

DEFAULT_TOOLS = ["claude", "codex", "antigravity"]

# ── Tool-profile registry ────────────────────────────────────────────────────
# `bridged_by`:
#   "existing"  — Claude/Codex/Antigravity: handled by their own scripts, never
#                 touched here. Present only for selection + reporting.
#   "registry"  — this engine emits the tool's MCP config from its profile.
# `mcp.format`: which emitter drives the tool (see EMITTERS).
# `mcp.scope`:  "project" (repo-relative path) | "global" (home-relative path).
# `china_tier`: A works natively in mainland China; B works with friction;
#               C is effectively VPN-only. Used by the selection picker.
PROFILES: dict[str, dict] = {
    "claude": {
        "display_name": "Claude Code",
        "bridged_by": "existing",
        "china_tier": "B",
    },
    "codex": {
        "display_name": "Codex CLI",
        "bridged_by": "existing",
        "china_tier": "B",
    },
    "antigravity": {
        "display_name": "Antigravity (agy)",
        "bridged_by": "existing",
        "china_tier": "C",
        "aliases": ["agy"],
    },
    "grok": {
        "display_name": "Grok Build (xAI)",
        "bridged_by": "registry",
        "china_tier": "C",
        "mcp": {"format": "toml-mcp_servers", "path": ".grok/config.toml", "scope": "project"},
    },
    "opencode": {
        "display_name": "opencode (SST)",
        "bridged_by": "registry",
        "china_tier": "A",
        "mcp": {"format": "json-nested", "path": "opencode.json", "scope": "project"},
    },
    "qwen": {
        "display_name": "Qwen Code (Alibaba)",
        "bridged_by": "registry",
        "china_tier": "A",
        "mcp": {"format": "json-settings", "path": ".qwen/settings.json", "scope": "project"},
        "skills_symlink": {"link": ".qwen/skills", "target": ".claude/skills"},
    },
    "kimi": {
        "display_name": "Kimi CLI (Moonshot)",
        "bridged_by": "registry",
        "china_tier": "A",
        "mcp": {"format": "json-mcpServers", "path": "~/.kimi/mcp.json", "scope": "global"},
    },
}

# Reverse alias map (e.g. "agy" → "antigravity").
_ALIAS_TO_ID = {
    alias: tool_id
    for tool_id, prof in PROFILES.items()
    for alias in prof.get("aliases", [])
}


# ── Reporting ────────────────────────────────────────────────────────────────
def ok(msg: str) -> None:
    print(f"✓ {msg}")


def note(msg: str) -> None:
    print(f"· {msg}")


def warn(msg: str) -> None:
    print(f"⚠ {msg}", file=sys.stderr)


def err(msg: str) -> None:
    print(f"! {msg}", file=sys.stderr)


# ── Shared helpers ───────────────────────────────────────────────────────────
def load_json(path: Path) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as exc:
        err(f"{path}: invalid JSON: {exc}")
        raise SystemExit(2)


def resolve_id(raw: str) -> str | None:
    """Map a user-typed tool token to a canonical profile id (honoring aliases)."""
    token = raw.strip().lower()
    if token in PROFILES:
        return token
    return _ALIAS_TO_ID.get(token)


def parse_enabled_tools(config_path: Path = CONFIG) -> list[str]:
    """Read canonical tool ids from the `## Enabled Tools` section of .cc-suite.md.

    Accepted line forms inside the section:
      - `- [x] tool` / `- [ ] tool`  → task-list: checked is enabled, unchecked disabled
      - `- tool`                      → plain bullet, enabled
    Commented lines (`# - tool`) and unknown tokens are ignored. Claude is always
    implicitly enabled — it is the source of truth the others mirror from.

    Falls back to DEFAULT_TOOLS when the file, the section, or a filled-in list is
    absent (a present-but-empty section is treated as a placeholder, not "only
    claude"), so existing projects and templates keep the current behavior.
    """
    text = config_path.read_text(encoding="utf-8") if config_path.exists() else None
    if not text:
        return list(DEFAULT_TOOLS)

    # Body of the "## Enabled Tools" section up to the next real ATX heading.
    # The terminator's negative lookahead `(?![-*][ \t])` keeps a commented
    # list item (`# - qwen`) from being mistaken for a heading and cutting the
    # section short.
    m = re.search(
        r"^[ \t]*#{1,6}[ \t]*Enabled[ \t]+Tools[ \t]*$"
        r"(.*?)(?=^[ \t]*#{1,6}[ \t]+(?![-*][ \t])|\Z)",
        text,
        re.IGNORECASE | re.MULTILINE | re.DOTALL,
    )
    if not m:
        return list(DEFAULT_TOOLS)

    enabled: list[str] = []
    for line in m.group(1).splitlines():
        item = line.strip()
        checkbox = re.match(r"^[-*][ \t]+\[([ xX])\][ \t]+([A-Za-z0-9_-]+)", item)
        if checkbox:
            if checkbox.group(1).lower() == "x":
                tid = resolve_id(checkbox.group(2))
                if tid and tid not in enabled:
                    enabled.append(tid)
            continue
        bullet = re.match(r"^[-*][ \t]+([A-Za-z0-9_-]+)", item)
        if bullet:
            tid = resolve_id(bullet.group(1))
            if tid and tid not in enabled:
                enabled.append(tid)

    if not enabled:
        # Present-but-empty section (a template stub) → keep current defaults.
        return list(DEFAULT_TOOLS)
    if "claude" not in enabled:
        enabled.insert(0, "claude")
    return enabled


def read_source_servers() -> dict[str, object]:
    source = load_json(SOURCE)
    if source is None:
        return {}
    if not isinstance(source, dict):
        err(".mcp.json top level must be an object")
        raise SystemExit(2)
    servers = source.get("mcpServers", {})
    if not isinstance(servers, dict):
        err(".mcp.json mcpServers must be an object")
        raise SystemExit(2)
    return servers


def claude_octopus_pin() -> str:
    try:
        pin = "".join(PIN_FILE.read_text(encoding="utf-8").split())
    except FileNotFoundError:
        err(f"missing claude-octopus pin file: {PIN_FILE}")
        raise SystemExit(2)
    if not pin:
        err("claude-octopus pin file is empty")
        raise SystemExit(2)
    return pin


def desired_servers() -> dict[str, dict]:
    """The canonical server set every registry-bridged tool receives:
    the project's .mcp.json servers plus the pinned claude-octopus server
    (so the tool can delegate to — and read the session history of — Claude).
    """
    result: dict[str, dict] = {}
    for name, config in read_source_servers().items():
        if isinstance(config, dict):
            result[name] = copy.deepcopy(config)
        else:
            warn(f"{name}: server config must be an object — skipped")
    result.setdefault(
        "claude-code",
        {"type": "stdio", "command": "npx", "args": ["-y", f"claude-octopus@{claude_octopus_pin()}"], "env": {}},
    )
    return result


def _transport(config: dict) -> str:
    return config.get("type", "stdio")


def _remote_url(config: dict) -> str | None:
    return config.get("serverUrl") or config.get("url") or config.get("httpUrl")


def _redactable(config: dict) -> list[str]:
    """Env-var names + a 'headers' marker that must NOT be written to a mirrored
    config (potential secrets). Returned so the caller can report them."""
    missing: list[str] = []
    env = config.get("env")
    if isinstance(env, dict) and env:
        missing.extend(sorted(env))
    if isinstance(config.get("headers"), dict) and config["headers"]:
        missing.append("<headers>")
    return missing


def _toml_key(name: str) -> str:
    if re.match(r"^[A-Za-z0-9_-]+$", name):
        return name
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _toml_str(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def resolve_path(spec: dict) -> Path:
    raw = spec["path"]
    if spec.get("scope") == "global":
        return Path(raw).expanduser()
    return ROOT / raw


# ── Emitters ─────────────────────────────────────────────────────────────────
# Each returns (changed: bool, redacted: dict[server_name, list[str]]).

def emit_toml_mcp_servers(path: Path, servers: dict[str, dict]) -> tuple[bool, dict]:
    """Grok Build (and the Codex TOML shape): a sentinel-guarded block of
    `[mcp_servers.<name>]` tables. Rewrites only the sentinel block, preserving
    anything the user added outside it."""
    redacted: dict[str, list[str]] = {}
    blocks: list[str] = []
    for name, config in servers.items():
        key = _toml_key(name)
        lines = [f"[mcp_servers.{key}]"]
        transport = _transport(config)
        if transport == "stdio":
            command = config.get("command")
            if not command:
                warn(f"{name}: stdio server has no command — skipped")
                continue
            lines.append(f"command = {_toml_str(command)}")
            args = config.get("args") or []
            if args:
                lines.append("args = [" + ", ".join(_toml_str(str(a)) for a in args) + "]")
        elif transport in ("sse", "http", "streamable_http"):
            url = _remote_url(config)
            if not url:
                warn(f"{name}: remote server has no URL — skipped")
                continue
            lines.append(f"url = {_toml_str(url)}")
        else:
            warn(f"{name}: unsupported transport {transport!r} — skipped")
            continue
        # Give the delegation server the extended timeouts a claude_code call needs.
        if name == "claude-code":
            lines.append("startup_timeout_sec = 60")
            lines.append("tool_timeout_sec    = 900")
        missing = _redactable(config)
        if missing:
            redacted[name] = missing
            lines.append(f"# env/headers not mirrored (may hold secrets) — add manually: {', '.join(missing)}")
        blocks.append("\n".join(lines))

    block = f"{TOML_SENTINEL_OPEN}\n" + "\n\n".join(blocks) + f"\n{TOML_SENTINEL_CLOSE}\n"
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    base, had_block = _strip_toml_sentinel(existing)
    new_text = (base.rstrip("\n") + "\n\n" + block) if base.strip() else block
    if existing == new_text:
        return False, redacted
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(new_text, encoding="utf-8")
    return True, redacted


def _strip_toml_sentinel(text: str) -> tuple[str, bool]:
    start = text.find(TOML_SENTINEL_OPEN)
    end = text.find(TOML_SENTINEL_CLOSE)
    if start == -1 or end == -1 or end < start:
        return text, False
    nl = text.find("\n", end)
    tail = text[nl + 1:] if nl != -1 else ""
    return text[:start].rstrip("\n") + ("\n" + tail if tail else ""), True


def _json_translate_mcpservers(servers: dict[str, dict], remote_key: str) -> tuple[dict, dict]:
    """Translate to the `mcpServers` JSON shape (Kimi, Qwen). `remote_key` is the
    key a remote transport uses for its URL (`url` for Kimi, `httpUrl` for Qwen)."""
    out: dict[str, dict] = {}
    redacted: dict[str, list[str]] = {}
    for name, config in servers.items():
        transport = _transport(config)
        if transport == "stdio":
            command = config.get("command")
            if not command:
                warn(f"{name}: stdio server has no command — skipped")
                continue
            entry: dict = {"command": command}
            if config.get("args"):
                entry["args"] = list(config["args"])
        elif transport in ("sse", "http", "streamable_http"):
            url = _remote_url(config)
            if not url:
                warn(f"{name}: remote server has no URL — skipped")
                continue
            entry = {remote_key: url}
        else:
            warn(f"{name}: unsupported transport {transport!r} — skipped")
            continue
        missing = _redactable(config)
        if missing:
            redacted[name] = missing
        out[name] = entry
    return out, redacted


def _json_translate_nested(servers: dict[str, dict]) -> tuple[dict, dict]:
    """opencode's `mcp` shape: type local/remote, command as a single array,
    `environment` for env (omitted here — secrets)."""
    out: dict[str, dict] = {}
    redacted: dict[str, list[str]] = {}
    for name, config in servers.items():
        transport = _transport(config)
        if transport == "stdio":
            command = config.get("command")
            if not command:
                warn(f"{name}: stdio server has no command — skipped")
                continue
            entry = {"type": "local", "command": [command, *[str(a) for a in config.get("args", [])]], "enabled": True}
        elif transport in ("sse", "http", "streamable_http"):
            url = _remote_url(config)
            if not url:
                warn(f"{name}: remote server has no URL — skipped")
                continue
            entry = {"type": "remote", "url": url, "enabled": True}
        else:
            warn(f"{name}: unsupported transport {transport!r} — skipped")
            continue
        missing = _redactable(config)
        if missing:
            redacted[name] = missing
        out[name] = entry
    return out, redacted


def _write_json_merge(path: Path, root_key: str, translated: dict[str, dict]) -> bool:
    """Merge `translated` into `path[root_key]`, preserving user-managed entries
    and any sibling keys. Tracks cc-suite-owned entries in a provenance sibling
    so re-runs refresh only what cc-suite wrote."""
    prov_path = path.parent / f".cc-suite-{path.name}.provenance.json"
    managed = _read_provenance(prov_path)

    raw = load_json(path)
    if raw is not None and not isinstance(raw, dict):
        err(f"{path}: top level must be an object — leaving it alone")
        raise SystemExit(2)
    doc: dict = raw if isinstance(raw, dict) else {}

    section = doc.get(root_key, {})
    if not isinstance(section, dict):
        err(f"{path}: {root_key} must be an object — leaving it alone")
        raise SystemExit(2)

    if managed is None and section:
        # An existing section with no provenance is user-authored — only refuse
        # if we would collide with one of their entries.
        conflicts = sorted(set(translated) & set(section))
        if conflicts:
            err(f"{path}: user-managed server name conflict(s): {', '.join(conflicts)} — refusing to overwrite")
            raise SystemExit(2)
        managed = set()

    managed = managed or set()
    remaining = {n: c for n, c in section.items() if n not in managed}
    conflicts = sorted(set(translated) & set(remaining))
    if conflicts:
        err(f"{path}: user-managed server name conflict(s): {', '.join(conflicts)} — refusing to overwrite")
        raise SystemExit(2)

    merged = {**remaining, **translated}
    new_doc = dict(doc)
    new_doc[root_key] = merged
    new_text = json.dumps(new_doc, indent=2) + "\n"

    changed = not path.exists() or path.read_text(encoding="utf-8") != new_text
    if changed:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(new_text, encoding="utf-8")
    _write_provenance(prov_path, sorted(translated))
    return changed


def _read_provenance(path: Path) -> set[str] | None:
    data = load_json(path)
    if data is None:
        return None
    if not isinstance(data, dict) or data.get("schema") != PROV_SCHEMA:
        err(f"{path}: unsupported provenance schema — refusing to overwrite")
        raise SystemExit(2)
    names = data.get("managed_servers")
    if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
        err(f"{path}: managed_servers is invalid — refusing to overwrite")
        raise SystemExit(2)
    return set(names)


def _write_provenance(path: Path, names: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({"schema": PROV_SCHEMA, "managed_servers": names, "source": ".mcp.json"}, indent=2) + "\n",
        encoding="utf-8",
    )


def link_skills(link_spec: dict) -> str:
    """Create/verify a relative skills symlink (Qwen: .qwen/skills → .claude/skills).
    Returns a short status string. No-op if the target does not exist."""
    link = ROOT / link_spec["link"]
    target = ROOT / link_spec["target"]
    if not target.exists():
        return f"skills: target {link_spec['target']} not present — skipped"
    rel = Path(os.path.relpath(target, link.parent))
    if link.is_symlink():
        if Path(os.readlink(link)) == rel:
            return f"skills: {link_spec['link']} already linked"
        link.unlink()
    elif link.exists():
        return f"skills: {link_spec['link']} exists and is not a symlink — left alone"
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(rel)
    return f"skills: {link_spec['link']} → {link_spec['target']}"


# ── Dispatch ─────────────────────────────────────────────────────────────────
def bridge_tool(tool_id: str, servers: dict[str, dict]) -> None:
    prof = PROFILES[tool_id]
    name = prof["display_name"]
    mcp = prof.get("mcp")
    if not mcp:
        note(f"{name}: no MCP target — nothing to mirror")
        return
    path = resolve_path(mcp)
    fmt = mcp["format"]

    if fmt == "toml-mcp_servers":
        changed, redacted = emit_toml_mcp_servers(path, servers)
    elif fmt == "json-nested":
        translated, redacted = _json_translate_nested(servers)
        changed = _write_json_merge(path, "mcp", translated)
    elif fmt == "json-mcpServers":
        translated, redacted = _json_translate_mcpservers(servers, remote_key="url")
        changed = _write_json_merge(path, "mcpServers", translated)
    elif fmt == "json-settings":
        translated, redacted = _json_translate_mcpservers(servers, remote_key="httpUrl")
        changed = _write_json_merge(path, "mcpServers", translated)
    else:
        err(f"{name}: unknown mcp format {fmt!r} — skipped")
        return

    label = str(path if mcp.get("scope") == "global" else path.relative_to(ROOT))
    ok(f"{name}: {'mirrored' if changed else 'already current'} {len(servers)} server(s) → {label}")
    for server, missing in redacted.items():
        warn(f"  {name}/{server}: set manually (not mirrored): {', '.join(missing)}")

    if "skills_symlink" in prof:
        note(f"{name}: {link_skills(prof['skills_symlink'])}")


def _remove_symlink(link_spec: dict) -> None:
    link = ROOT / link_spec["link"]
    if link.is_symlink():
        link.unlink()
        ok(f"removed {link_spec['link']} symlink")
        try:
            link.parent.rmdir()  # only succeeds if now empty
            ok(f"removed empty {link.parent.relative_to(ROOT)}/")
        except OSError:
            pass


def _unbridge_toml(path: Path) -> None:
    if not path.exists():
        return
    base, had = _strip_toml_sentinel(path.read_text(encoding="utf-8"))
    if not had:
        note(f"{path.name}: no cc-suite block — left alone")
        return
    if base.strip():
        path.write_text(base.rstrip("\n") + "\n", encoding="utf-8")
        ok(f"{path}: removed cc-suite-mcp block")
    else:
        path.unlink()
        ok(f"removed {path} (only contained cc-suite block)")


def _unbridge_json(path: Path, root_key: str) -> None:
    prov_path = path.parent / f".cc-suite-{path.name}.provenance.json"
    if not prov_path.exists():
        if path.exists():
            note(f"{path.name}: no cc-suite provenance — left alone")
        return
    managed = _read_provenance(prov_path)
    doc = load_json(path)
    if isinstance(doc, dict):
        section = doc.get(root_key, {})
        if isinstance(section, dict):
            remaining = {k: v for k, v in section.items() if k not in (managed or set())}
            if remaining:
                doc[root_key] = remaining
                path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
                ok(f"{path}: removed cc-suite-managed servers")
            else:
                doc.pop(root_key, None)
                if doc:  # sibling keys survive → keep the file
                    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
                    ok(f"{path}: removed cc-suite {root_key} block")
                elif path.exists():
                    path.unlink()
                    ok(f"removed {path} (cc-suite-only)")
    prov_path.unlink()
    ok(f"removed {prov_path.name}")


def unbridge_tool(tool_id: str) -> None:
    """Remove cc-suite-managed artifacts for one registry tool. Tears down
    regardless of current enabled-state, so disabling a tool then unbridging
    still cleans it up."""
    prof = PROFILES[tool_id]
    if prof.get("bridged_by") != "registry":
        return
    if "skills_symlink" in prof:
        _remove_symlink(prof["skills_symlink"])
    mcp = prof.get("mcp")
    if not mcp:
        return
    path = resolve_path(mcp)
    if mcp["format"] == "toml-mcp_servers":
        _unbridge_toml(path)
    else:
        root_key = "mcp" if mcp["format"] == "json-nested" else "mcpServers"
        _unbridge_json(path, root_key)


CHINA_TIER_NOTE = {
    "A": "works natively in mainland China",
    "B": "works in China with friction (point at a domestic endpoint)",
    "C": "effectively VPN-only in mainland China",
}


def print_status() -> int:
    """Show the enabled set and every available tool with its China tier and
    MCP target. Read-only — writes nothing. Consumed by the selection picker
    and /cc-suite:diagnose."""
    enabled = parse_enabled_tools()
    print("Enabled tools (from .cc-suite.md, or default): " + ", ".join(enabled))
    print()
    print(f"{'tool':<13} {'enabled':<8} {'bridged-by':<11} {'china':<6} target")
    print("-" * 72)
    for tool_id, prof in PROFILES.items():
        mcp = prof.get("mcp")
        target = mcp["path"] if mcp else "(reads shared config natively)"
        print(
            f"{tool_id:<13} {('yes' if tool_id in enabled else 'no'):<8} "
            f"{prof['bridged_by']:<11} {prof.get('china_tier','?'):<6} {target}"
        )
    print()
    for tier in ("A", "B", "C"):
        print(f"  China tier {tier}: {CHINA_TIER_NOTE[tier]}")
    return 0


def main(argv: list[str]) -> int:
    args = list(argv)
    if args and args[0] == "--status":
        return print_status()

    if args and args[0] == "--unbridge":
        for tool_id, prof in PROFILES.items():
            if prof.get("bridged_by") == "registry":
                unbridge_tool(tool_id)
        return 0

    # Optional explicit selection: `--tools grok,opencode`. Otherwise read
    # the enabled set from .cc-suite.md.
    selected: list[str] | None = None
    if args and args[0] == "--tools":
        if len(args) < 2:
            err("--tools requires a comma-separated list")
            return 2
        selected = []
        for token in args[1].split(","):
            tid = resolve_id(token)
            if tid is None:
                warn(f"unknown tool {token!r} — ignored")
            elif tid not in selected:
                selected.append(tid)

    enabled = selected if selected is not None else parse_enabled_tools()
    registry_tools = [t for t in enabled if PROFILES.get(t, {}).get("bridged_by") == "registry"]

    existing_bridged = [t for t in enabled if PROFILES.get(t, {}).get("bridged_by") == "existing"]
    if existing_bridged:
        note("handled by existing bridges (unchanged here): " + ", ".join(existing_bridged))

    if not registry_tools:
        note("no registry-bridged tools enabled — nothing to do")
        return 0

    servers = desired_servers()
    for tool_id in registry_tools:
        bridge_tool(tool_id, servers)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
