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
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

from md_sections import strip_fenced_blocks  # noqa: E402
from pin import PinError, read_pin  # noqa: E402

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

# Reserved name of the reverse-delegation server cc-suite adds to every mirrored
# config. A source server may not take it (see desired_servers).
DELEGATION_SERVER = "claude-code"

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
        "binary": "claude",
        "bridged_by": "existing",
        "china_tier": "B",
    },
    "codex": {
        "display_name": "Codex CLI",
        "binary": "codex",
        "bridged_by": "existing",
        "china_tier": "B",
    },
    "antigravity": {
        "display_name": "Antigravity (agy)",
        "binary": "agy",
        "bridged_by": "existing",
        "china_tier": "C",
        "aliases": ["agy"],
    },
    "grok": {
        "display_name": "Grok Build (xAI)",
        "binary": "grok",
        "bridged_by": "registry",
        "china_tier": "C",
        "mcp": {"format": "toml-mcp_servers", "path": ".grok/config.toml", "scope": "project"},
    },
    "opencode": {
        "display_name": "opencode (SST)",
        "binary": "opencode",
        "bridged_by": "registry",
        "china_tier": "A",
        "mcp": {"format": "json-nested", "path": "opencode.json", "scope": "project"},
    },
    "qwen": {
        "display_name": "Qwen Code (Alibaba)",
        "binary": "qwen",
        "bridged_by": "registry",
        "china_tier": "A",
        "mcp": {"format": "json-settings", "path": ".qwen/settings.json", "scope": "project"},
        "skills_symlink": {"link": ".qwen/skills", "target": ".claude/skills"},
        # Qwen is the only registry tool that does not read AGENTS.md on its
        # own. Verified against qwen-code 0.21.0: getContextFileNames() returns
        # ["QWEN.md"] whenever the setting is unset, so without this a bridged
        # project's AGENTS.md is silently ignored. `context.fileName` is the
        # current key (settings.merged.context?.fileName); QWEN.md is kept in
        # the list so a project that already has one kicks on working.
        "context_files": {"key": ["context", "fileName"], "want": ["AGENTS.md", "QWEN.md"]},
    },
    "kimi": {
        "display_name": "Kimi CLI (Moonshot)",
        "binary": "kimi",
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


def _atomic_write_text(path: Path, text: str) -> None:
    """Same-directory tempfile + os.replace, so a crash or a concurrent reader
    never sees partial content."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        try:
            os.chmod(tmp, path.stat().st_mode & 0o7777)
        except OSError:
            pass  # new file: keep the private mkstemp mode
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


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

    Falls back to DEFAULT_TOOLS when the file or the section is absent, or when
    the section lists no recognized tool at all (a present-but-empty section is a
    template placeholder), so existing projects and templates keep the current
    behavior. A section that does list recognized tools with every box unticked
    is a real selection — Claude only — not a placeholder.
    """
    return _parse_enabled(config_path)[0]


def _parse_enabled(config_path: Path = CONFIG) -> tuple[list[str], bool]:
    """`(tools, explicit)` — `explicit` is False when the list is the
    DEFAULT_TOOLS fallback rather than a selection read from the config."""
    text = config_path.read_text(encoding="utf-8") if config_path.exists() else None
    if not text:
        return list(DEFAULT_TOOLS), False

    # .cc-suite.md documents its own format, so a fenced example of this very
    # section is normal. Reading the first match regardless of fencing parsed
    # the checkboxes out of the example and silently dropped the real selection.
    # Blanking fenced content preserves offsets, so the search below is
    # unchanged apart from what it can see.
    text = strip_fenced_blocks(text)

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
        return list(DEFAULT_TOOLS), False

    enabled: list[str] = []
    listed = False
    for line in m.group(1).splitlines():
        item = line.strip()
        checkbox = re.match(r"^[-*][ \t]+\[([ xX])\][ \t]+([A-Za-z0-9_-]+)", item)
        if checkbox:
            tid = resolve_id(checkbox.group(2))
            if tid:
                listed = True
                if checkbox.group(1).lower() == "x" and tid not in enabled:
                    enabled.append(tid)
            continue
        bullet = re.match(r"^[-*][ \t]+([A-Za-z0-9_-]+)", item)
        if bullet:
            tid = resolve_id(bullet.group(1))
            if tid:
                listed = True
                if tid not in enabled:
                    enabled.append(tid)

    if not enabled:
        if listed:
            # Every recognized tool is explicitly unticked: a deliberate
            # Claude-only project, not a template stub.
            return ["claude"], True
        # Present-but-empty section (a template stub) → keep current defaults.
        return list(DEFAULT_TOOLS), False
    if "claude" not in enabled:
        enabled.insert(0, "claude")
    return enabled, True


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
        return read_pin(PIN_FILE)
    except PinError as exc:
        err(str(exc))
        raise SystemExit(2)


def _valid_server_shape(name: str, config: dict) -> bool:
    """Type-check the fields the emitters consume, so a malformed .mcp.json
    entry is skipped with a warning instead of crashing an emitter or being
    silently mangled (e.g. a string `args` iterated per character)."""
    if not isinstance(config.get("type", "stdio"), str):
        warn(f"{name}: server type must be a string — skipped")
        return False
    if config.get("command") is not None and not isinstance(config["command"], str):
        warn(f"{name}: command must be a string — skipped")
        return False
    if config.get("args") is not None and (
        not isinstance(config["args"], list)
        or not all(isinstance(a, str) for a in config["args"])
    ):
        warn(f"{name}: args must be a list of strings — skipped")
        return False
    for key in ("env", "headers"):
        if config.get(key) is not None and (
            not isinstance(config[key], dict)
            or not all(isinstance(k, str) and isinstance(v, str) for k, v in config[key].items())
        ):
            warn(f"{name}: {key} must be an object of string values — skipped")
            return False
    for key in ("serverUrl", "url", "httpUrl"):
        if config.get(key) is not None and not isinstance(config[key], str):
            warn(f"{name}: {key} must be a string — skipped")
            return False
    return True


def _is_delegation_package(config: dict) -> bool:
    """True when a source entry under the reserved name really is claude-octopus
    over npx — the same server, possibly at a different version. Anything else
    wearing that name is a different program and a genuine collision."""
    args = config.get("args") or []
    return (
        config.get("type", "stdio") == "stdio"
        and config.get("command") == "npx"
        and any(isinstance(a, str) and (a == "claude-octopus" or a.startswith("claude-octopus@"))
                for a in args)
    )


def desired_servers() -> dict[str, dict]:
    """The canonical server set every registry-bridged tool receives:
    the project's .mcp.json servers plus the pinned claude-octopus server
    (so the tool can delegate to — and read the session history of — Claude).
    """
    result: dict[str, dict] = {}
    for name, config in read_source_servers().items():
        if not isinstance(config, dict):
            warn(f"{name}: server config must be an object — skipped")
        elif _valid_server_shape(name, config):
            result[name] = copy.deepcopy(config)
    pin = claude_octopus_pin()
    args = ["-y", f"claude-octopus@{pin}"]
    # `claude-code` is reserved: every bridged tool delegates through it, so a
    # differently-defined source entry must not silently take its place.
    existing = result.get(DELEGATION_SERVER)
    if existing is None:
        result[DELEGATION_SERVER] = {"type": "stdio", "command": "npx", "args": args, "env": {}}
    elif not _is_delegation_package(existing):
        err(
            f".mcp.json defines {DELEGATION_SERVER!r} as something other than the pinned "
            f"delegation server (expected command 'npx' with 'claude-octopus@{pin}') — "
            "cc-suite reserves that name; rename your server"
        )
        raise SystemExit(2)
    elif existing.get("args") != args:
        warn(f"{DELEGATION_SERVER}: .mcp.json runs a different claude-octopus spec — "
             f"mirroring the cc-suite pin {pin}")
        existing["args"] = args
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
    return _toml_str(name)


# Basic-string escapes TOML requires; every other control character has to be
# written as \uXXXX, because raw control characters are illegal in a TOML string.
_TOML_ESCAPES = {
    "\\": "\\\\",
    '"': '\\"',
    "\b": "\\b",
    "\t": "\\t",
    "\n": "\\n",
    "\f": "\\f",
    "\r": "\\r",
}
_TOML_UNESCAPES = {"b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r", '"': '"', "\\": "\\"}


def _toml_unquote(key: str) -> str:
    """Undo TOML key quoting: literal (single-quoted) keys verbatim, basic
    (double-quoted) keys with their backslash escapes resolved."""
    if len(key) >= 2 and key[0] == key[-1] == "'":
        return key[1:-1]
    if len(key) >= 2 and key[0] == key[-1] == '"':
        return _toml_basic_unescape(key[1:-1])
    return key


def _toml_basic_unescape(body: str) -> str:
    def one(match: re.Match) -> str:
        tag = match.group(1)
        if tag[0] in "uU":
            try:
                return chr(int(tag[1:], 16))
            except ValueError:
                return match.group(0)
        return _TOML_UNESCAPES.get(tag, tag)

    return re.sub(r"\\(u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)", one, body, flags=re.DOTALL)


def _toml_str(value: str) -> str:
    """Serialize as a TOML basic string, escaping every character TOML forbids
    raw — a newline in a .mcp.json value would otherwise terminate the line and
    splice arbitrary content into the generated config."""
    out: list[str] = []
    for ch in value:
        escaped = _TOML_ESCAPES.get(ch)
        if escaped is not None:
            out.append(escaped)
        elif ch < "\x20" or ch == "\x7f":
            out.append(f"\\u{ord(ch):04X}")
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def _toml_comment(text: str) -> str:
    """A TOML comment runs to end of line, so a newline (or any other control
    character) inside interpolated text would escape the comment."""
    return "".join(" " if ch < "\x20" or ch == "\x7f" else ch for ch in text)


# TOML allows whitespace around the dot and inside the brackets, single- or
# double-quoted keys, and a trailing comment — recognize all of these so an
# equivalent header spelling cannot slip past a conflict or presence check.
_TOML_SERVER_TABLE_RE = re.compile(
    r'^\s*\[\s*mcp_servers\s*\.\s*'
    r'("(?:[^"\\]|\\.)*"|\'[^\']*\'|[A-Za-z0-9_-]+)'
    r'\s*\]\s*(?:#.*)?$',
    re.MULTILINE,
)


def _toml_server_tables(text: str) -> set[str]:
    """Server names declared by `[mcp_servers.<name>]` headers in `text`."""
    return {_toml_unquote(m.group(1)) for m in _TOML_SERVER_TABLE_RE.finditer(text)}


def resolve_path(spec: dict) -> Path:
    raw = spec["path"]
    if spec.get("scope") == "global":
        return Path(raw).expanduser()
    return ROOT / raw


# ── Emitters ─────────────────────────────────────────────────────────────────
# The JSON emitters return (translated, redacted); the TOML emitter returns
# (changed, redacted, emitted server names).

def emit_toml_mcp_servers(path: Path, servers: dict[str, dict]) -> tuple[bool, dict, list]:
    """Grok Build (and the Codex TOML shape): a sentinel-guarded block of
    `[mcp_servers.<name>]` tables. Rewrites only the sentinel block, preserving
    anything the user added outside it."""
    redacted: dict[str, list[str]] = {}
    blocks: list[str] = []
    emitted: list[str] = []
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
            lines.append(_toml_comment(
                f"# env/headers not mirrored (may hold secrets) — add manually: {', '.join(missing)}"))
        blocks.append("\n".join(lines))
        emitted.append(name)

    block = f"{TOML_SENTINEL_OPEN}\n" + "\n\n".join(blocks) + f"\n{TOML_SENTINEL_CLOSE}\n"
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    base, _ = _strip_toml_sentinel(existing, path)
    # A user-managed [mcp_servers.<name>] outside the sentinel would collide
    # with ours: TOML forbids duplicate tables, so the file would be invalid.
    conflicts = sorted(set(emitted) & _toml_server_tables(base))
    if conflicts:
        err(f"{path}: user-managed server name conflict(s): {', '.join(conflicts)} — refusing to overwrite")
        raise SystemExit(2)
    new_text = (base.rstrip("\n") + "\n\n" + block) if base.strip() else block
    if existing == new_text:
        return False, redacted, emitted
    _atomic_write_text(path, new_text)
    return True, redacted, emitted


def _strip_toml_sentinel(text: str, path: Path | None = None) -> tuple[str, bool]:
    """Remove the single sentinel-guarded block. Zero sentinels → unchanged.
    Anything else (unpaired, reversed, or duplicated markers) is a corrupted
    layout: fail loudly instead of splicing around it and appending a second
    block alongside the malformed one."""
    starts = [m.start() for m in re.finditer(re.escape(TOML_SENTINEL_OPEN), text)]
    ends = [m.start() for m in re.finditer(re.escape(TOML_SENTINEL_CLOSE), text)]
    if not starts and not ends:
        return text, False
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        where = f"{path}: " if path else ""
        err(f"{where}malformed cc-suite-mcp sentinel block (unpaired, reversed, or duplicated) — fix it manually")
        raise SystemExit(2)
    start, end = starts[0], ends[0]
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
    # Three-step transactional write, each step atomic, so a crash between any
    # two writes self-heals on the next run in both directions:
    #   1. expand provenance to old ∪ new — every server we have ever written
    #      stays recorded as cc-suite-owned, so a fresh target entry is never
    #      misclassified as a user-owned conflict;
    #   2. write the target;
    #   3. contract provenance to exactly the new set — a name is un-claimed
    #      only after the target write that removed it has really landed, so a
    #      removed managed server is never misclassified as user-owned either.
    # A provenance name absent from the target is inert (nothing to preserve
    # or remove), so a stale expanded set from a crashed run is harmless.
    union = sorted(managed | set(translated))
    final = sorted(translated)
    if union != final:
        _write_provenance(prov_path, union)
    if changed:
        _atomic_write_text(path, new_text)
    _write_provenance(prov_path, final)
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
    payload = {"schema": PROV_SCHEMA, "managed_servers": names, "source": ".mcp.json"}
    # A machine-global target (~/.kimi/mcp.json) is shared by every project on
    # the machine, so the file alone cannot say who bridged it. Record the
    # owning workspace: without it, a project that never touched the target
    # cannot distinguish "I left this behind" from "someone else's project owns
    # this", and reporting the latter as a problem gives the operator a red
    # check whose only remedy destroys another project's bridge.
    if not _is_inside(path, ROOT):
        payload["workspace"] = str(Path(ROOT).resolve())
    _atomic_write_text(path, json.dumps(payload, indent=2) + "\n")


def _is_inside(path: Path, root: Path) -> bool:
    try:
        Path(path).resolve().relative_to(Path(root).resolve())
        return True
    except (ValueError, OSError):
        return False


def _provenance_workspace(path: Path) -> str | None:
    """The workspace recorded as owning this target, or None when the
    provenance is absent or predates workspace attribution."""
    data = load_json(path)
    if not isinstance(data, dict):
        return None
    ws = data.get("workspace")
    return ws if isinstance(ws, str) and ws else None


def _global_target_owner(prof: dict) -> str | None:
    """The workspace that bridged this tool's global target, if it recorded one."""
    path = resolve_path(prof["mcp"])
    return _provenance_workspace(path.parent / f".cc-suite-{path.name}.provenance.json")


def _owned_by_this_workspace(prof: dict) -> bool | None:
    """True/False when ownership of a machine-global target is recorded, None
    when the provenance predates workspace attribution and cannot say."""
    owner = _global_target_owner(prof)
    if owner is None:
        return None
    try:
        return Path(owner).resolve() == Path(ROOT).resolve()
    except OSError:
        return owner == str(ROOT)


def _nested_get(doc: dict, key_path: list[str]):
    cur = doc
    for part in key_path:
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def _nested_set(doc: dict, key_path: list[str], value) -> None:
    """Create only the *missing* intermediate objects. An intermediate that
    exists with some other shape is a user setting — overwriting it would
    destroy it silently, so this refuses and lets the caller report."""
    cur = doc
    for part in key_path[:-1]:
        if part not in cur:
            cur[part] = {}
        elif not isinstance(cur[part], dict):
            raise ValueError(f"{'.'.join(key_path)}: {part} is not an object")
        cur = cur[part]
    cur[key_path[-1]] = value


def _context_prov_path(path: Path) -> Path:
    return path.parent / f".cc-suite-{path.name}.context.provenance.json"


def _read_context_added(path: Path) -> list[str] | None:
    """Context entries recorded as bridge-added, or None when no valid record exists."""
    try:
        data = json.loads(_context_prov_path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict) or data.get("schema") != PROV_SCHEMA:
        return None
    added = data.get("added_entries")
    if isinstance(added, list) and all(isinstance(x, str) for x in added):
        return added
    return None


def _record_context_added(path: Path, added: list[str]) -> None:
    if not added:
        return
    prior = _read_context_added(path) or []
    _atomic_write_text(
        _context_prov_path(path),
        json.dumps({"schema": PROV_SCHEMA, "added_entries": sorted(set(prior) | set(added))}, indent=2) + "\n",
    )


def ensure_context_files(path: Path, spec: dict) -> str:
    """Point a tool at AGENTS.md when it will not find it by itself.

    Additive by design: an existing user value is kept and only extended with
    the missing entries, because the setting is a general context-file list and
    the user may legitimately have their own files in it. The entries this
    bridge adds are recorded in a provenance sibling so unbridge removes
    exactly those and never a pre-existing user entry."""
    key_path = spec["key"]
    want = spec["want"]
    dotted = ".".join(key_path)

    raw = load_json(path)
    if raw is not None and not isinstance(raw, dict):
        err(f"{path}: top level must be an object — leaving it alone")
        raise SystemExit(2)
    doc: dict = raw if isinstance(raw, dict) else {}

    current = _nested_get(doc, key_path)
    if current is None:
        added = list(want)
        merged = list(want)
    elif isinstance(current, str):
        added = [w for w in want if w != current]
        merged = [*added, current]
    elif isinstance(current, list) and all(isinstance(x, str) for x in current):
        added = [w for w in want if w not in current]
        if not added:
            return f"context: {dotted} already includes {want[0]}"
        merged = [*added, *current]
    else:
        return f"context: {dotted} has an unexpected shape — left alone"

    try:
        _nested_set(doc, key_path, merged)
    except ValueError:
        return f"context: {dotted} has an unexpected shape — left alone"
    new_text = json.dumps(doc, indent=2) + "\n"
    if path.exists() and path.read_text(encoding="utf-8") == new_text:
        return f"context: {dotted} already current"
    _atomic_write_text(path, new_text)
    _record_context_added(path, added)
    return f"context: {dotted} = {json.dumps(merged)}"


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
        try:
            ours = link.resolve() == target.resolve()
        except OSError:
            ours = False
        if not ours:
            # Points somewhere else entirely — a user-managed link, not a stale
            # spelling of ours. Never repoint it.
            return f"skills: {link_spec['link']} points elsewhere — left alone"
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
        changed, redacted, emitted = emit_toml_mcp_servers(path, servers)
        count = len(emitted)
    elif fmt == "json-nested":
        translated, redacted = _json_translate_nested(servers)
        changed = _write_json_merge(path, "mcp", translated)
        count = len(translated)
    elif fmt == "json-mcpServers":
        translated, redacted = _json_translate_mcpservers(servers, remote_key="url")
        changed = _write_json_merge(path, "mcpServers", translated)
        count = len(translated)
    elif fmt == "json-settings":
        translated, redacted = _json_translate_mcpservers(servers, remote_key="httpUrl")
        changed = _write_json_merge(path, "mcpServers", translated)
        count = len(translated)
    else:
        err(f"{name}: unknown mcp format {fmt!r} — skipped")
        return

    label = str(path if mcp.get("scope") == "global" else path.relative_to(ROOT))
    ok(f"{name}: {'mirrored' if changed else 'already current'} {count} server(s) → {label}")
    for server, missing in redacted.items():
        warn(f"  {name}/{server}: set manually (not mirrored): {', '.join(missing)}")

    if "skills_symlink" in prof:
        note(f"{name}: {link_skills(prof['skills_symlink'])}")

    if "context_files" in prof:
        note(f"{name}: {ensure_context_files(path, prof['context_files'])}")


def _remove_symlink(link_spec: dict) -> None:
    link = ROOT / link_spec["link"]
    if not link.is_symlink():
        return
    target = ROOT / link_spec["target"]
    rel = Path(os.path.relpath(target, link.parent))
    try:
        ours = Path(os.readlink(link)) == rel or link.resolve() == target.resolve()
    except OSError:
        ours = False
    if not ours:
        note(f"{link_spec['link']} does not point at {link_spec['target']} — left alone")
        return
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
    base, had = _strip_toml_sentinel(path.read_text(encoding="utf-8"), path)
    if not had:
        note(f"{path.name}: no cc-suite block — left alone")
        return
    if base.strip():
        _atomic_write_text(path, base.rstrip("\n") + "\n")
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
    if doc is None:
        # The target is gone (deleted, moved, or an unmounted global path):
        # nothing was reconciled, so keep the provenance as recovery data
        # instead of discarding the ownership record.
        err(f"{path}: missing — nothing reconciled; keeping {prov_path.name}")
        return
    # An unexpected shape means the managed entries could not be removed:
    # keep the provenance so ownership survives a manual repair.
    if not isinstance(doc, dict) or not isinstance(doc.get(root_key, {}), dict):
        err(f"{path}: unexpected shape — fix it manually; keeping {prov_path.name}")
        return
    section = doc.get(root_key, {})
    remaining = {k: v for k, v in section.items() if k not in (managed or set())}
    if remaining:
        doc[root_key] = remaining
        _atomic_write_text(path, json.dumps(doc, indent=2) + "\n")
        ok(f"{path}: removed cc-suite-managed servers")
    else:
        doc.pop(root_key, None)
        if doc:  # sibling keys survive → keep the file
            _atomic_write_text(path, json.dumps(doc, indent=2) + "\n")
            ok(f"{path}: removed cc-suite {root_key} block")
        elif path.exists():
            path.unlink()
            ok(f"removed {path} (cc-suite-only)")
    prov_path.unlink()
    ok(f"removed {prov_path.name}")


def _unbridge_context_files(path: Path, spec: dict) -> None:
    """Undo ensure_context_files: strip exactly the entries the ownership record
    says this bridge added.

    Ownership is required. The values cc-suite writes (`AGENTS.md`, `QWEN.md`)
    are ones a project may well have configured itself before it ever met
    cc-suite, and a wrong deletion here is unrecoverable — so without a record
    the list is reported and left as the user's."""
    raw = load_json(path)
    if not isinstance(raw, dict):
        return
    key_path = spec["key"]
    want = spec["want"]
    current = _nested_get(raw, key_path)
    if not isinstance(current, list):
        return

    added = _read_context_added(path)
    if added is None:
        if any(entry in current for entry in want):
            note(f"{path.name}: {'.'.join(key_path)} has no cc-suite ownership record — "
                 f"left alone (drop {', '.join(want)} by hand if cc-suite added them)")
        return
    rest = [entry for entry in current if entry not in added]
    if rest == current:  # nothing of ours left in the list
        _context_prov_path(path).unlink(missing_ok=True)
        return

    parent = _nested_get(raw, key_path[:-1]) if len(key_path) > 1 else raw
    if rest:
        parent[key_path[-1]] = rest
    else:
        parent.pop(key_path[-1], None)
        # Drop the wrapper object too if we emptied it.
        if len(key_path) > 1 and not parent:
            grand = _nested_get(raw, key_path[:-2]) if len(key_path) > 2 else raw
            grand.pop(key_path[-2], None)

    _atomic_write_text(path, json.dumps(raw, indent=2) + "\n")
    _context_prov_path(path).unlink(missing_ok=True)
    ok(f"removed {'.'.join(key_path)} from {path.name}")


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
    if "context_files" in prof:
        _unbridge_context_files(path, prof["context_files"])
    if mcp["format"] == "toml-mcp_servers":
        _unbridge_toml(path)
    else:
        root_key = "mcp" if mcp["format"] == "json-nested" else "mcpServers"
        _unbridge_json(path, root_key)


def _bridged_artifacts_present(prof: dict) -> bool:
    """True when cc-suite still owns something for this tool — a sentinel block,
    a server-provenance sidecar, or a context-provenance sidecar."""
    mcp = prof.get("mcp")
    if not mcp:
        return False
    path = resolve_path(mcp)
    if mcp["format"] == "toml-mcp_servers":
        try:
            return TOML_SENTINEL_OPEN in path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return False
    if (path.parent / f".cc-suite-{path.name}.provenance.json").exists():
        return True
    return "context_files" in prof and _context_prov_path(path).exists()


def reconcile_disabled(enabled: list[str]) -> None:
    """Tear down registry tools cc-suite bridged that are no longer enabled, so
    unticking a tool actually revokes its MCP access instead of leaving a live
    config behind.

    A global-scope target (`~/.kimi/mcp.json`) is shared by every project on the
    machine and may well be the one *another* project bridged, so one project's
    selection must not remove it. That one is reported here — and again by
    `--health`, so it cannot pass unnoticed — with the tool-scoped `--unbridge`
    that revokes it deliberately."""
    for tool_id, prof in PROFILES.items():
        if prof.get("bridged_by") != "registry" or tool_id in enabled:
            continue
        if not _bridged_artifacts_present(prof):
            continue
        if prof["mcp"].get("scope") == "global":
            if _owned_by_this_workspace(prof) is False:
                continue  # another project owns it; not this project's to report
            note(f"{prof['display_name']}: disabled, but {prof['mcp']['path']} is still bridged — "
                 "that target is machine-wide and another project may own it, so it is never "
                 f"removed automatically; run `bridge_tools.py --unbridge {tool_id}` to revoke it")
            continue
        note(f"{prof['display_name']}: disabled — removing cc-suite artifacts")
        try:
            unbridge_tool(tool_id)
        except SystemExit:
            # One disabled tool's unreadable artifact must not stop the ENABLED
            # tools from being bridged. The refusal is already on stderr and the
            # leftover keeps being reported by --health until it is dealt with.
            # unbridge_tool() removes the skills symlink and the context entries
            # before the JSON teardown that raised, so "left in place" was false
            # for everything it had already got through. Name only what is
            # actually still there.
            err(f"{prof['display_name']}: teardown incomplete — the MCP config named above was "
                f"left in place; repair it, then run `bridge_tools.py --unbridge {tool_id}`")


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


def _context_shape_blocked(doc: dict, key_path: list[str]) -> bool:
    """True when the context setting sits under — or is — a value that
    ensure_context_files refuses to rewrite, so re-running the bridge cannot
    resolve the finding and only a hand edit can."""
    cur: object = doc
    for part in key_path[:-1]:
        if not isinstance(cur, dict):
            return True
        if part not in cur:
            return False  # the bridge creates the missing intermediate itself
        cur = cur[part]
    if not isinstance(cur, dict):
        return True
    leaf = cur.get(key_path[-1])
    if leaf is None or isinstance(leaf, str):
        return False
    return not (isinstance(leaf, list) and all(isinstance(x, str) for x in leaf))


def health_check() -> int:
    """Structured artifact-health validation for the enabled registry tools.

    Prints one JSON object: {"schema": 1, "enabled": [...], "tools": [
      {"id", "display_name", "status": "healthy"|"issue", "problems": [...],
       "fix": "/cc-suite:bridge-tools"}]}.
    Unlike --status (which only lists targets), this verifies the artifacts:
    config exists and parses, the cc-suite-managed entries are present, and
    tool-specific extras (Qwen skills symlink, context files) are wired.
    Read-only; exit 0 always (consumers read the JSON, not the exit code).
    A registry tool that is *disabled* but still carries cc-suite artifacts is
    reported too: its MCP access is live until those artifacts are gone, and a
    silent `"tools": []` would let diagnose call the project healthy.

    Claude/Codex/Antigravity are validated by their own scripts and the
    diagnose engine, not here.
    """
    enabled, explicit_selection = _parse_enabled()
    source_problem: str | None = None
    try:
        expected = set(desired_servers())
    except SystemExit:
        # .mcp.json is unreadable, the pin is invalid, or a source server claims
        # the reserved delegation name. The desired set is unknown, so every
        # comparison below is suspended and the failure itself is the finding.
        expected = set()
        source_problem = (
            "cannot resolve the project MCP surface — .mcp.json is invalid, the "
            "claude-octopus pin is not an exact semver, or a source server takes the "
            f"reserved name {DELEGATION_SERVER!r}"
        )
    tools: list[dict] = []
    for tool_id in enabled:
        prof = PROFILES.get(tool_id)
        if not prof or prof.get("bridged_by") != "registry":
            continue
        problems: list[str] = [source_problem] if source_problem else []
        spec = prof["mcp"]
        path = resolve_path(spec)
        label = spec["path"]
        if not path.exists():
            problems.append(f"{label} missing — tool cannot see the project MCP surface")
        elif spec["format"] == "toml-mcp_servers":
            text = path.read_text(encoding="utf-8", errors="replace")
            if TOML_SENTINEL_OPEN not in text or TOML_SENTINEL_CLOSE not in text:
                problems.append(f"{label} exists but has no cc-suite sentinel block")
            else:
                try:
                    import tomllib
                    tomllib.loads(text)
                except ModuleNotFoundError:
                    pass
                except Exception as exc:  # noqa: BLE001
                    problems.append(f"{label} is invalid TOML: {exc}")
                start, end = text.find(TOML_SENTINEL_OPEN), text.find(TOML_SENTINEL_CLOSE)
                block = text[start:end] if end > start else ""
                if not source_problem:
                    present = _toml_server_tables(block)
                    absent = sorted(expected - present)
                    if absent:
                        problems.append(f"{label} sentinel block lost expected server(s): {', '.join(absent)}")
                    stale = sorted(present - expected)
                    if stale:
                        problems.append(f"{label} sentinel block still mirrors server(s) no longer in "
                                        f"the project MCP surface: {', '.join(stale)}")
        else:
            root_key = "mcp" if spec["format"] == "json-nested" else "mcpServers"
            try:
                doc = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                doc = None
                problems.append(f"{label} is not valid JSON: {exc}")
            if isinstance(doc, dict):
                section = doc.get(root_key)
                if not isinstance(section, dict):
                    problems.append(f"{label} has no {root_key} object")
                else:
                    prov_path = path.parent / f".cc-suite-{path.name}.provenance.json"
                    prov_invalid = False
                    try:
                        managed = _read_provenance(prov_path)
                    except SystemExit:
                        managed = None
                        prov_invalid = True
                        problems.append(f"{prov_path.name} is present but invalid")
                    if managed is None:
                        if not prov_invalid:
                            problems.append(f"{label} has no cc-suite provenance — not bridged by cc-suite")
                    else:
                        absent = sorted(managed - set(section))
                        if absent:
                            problems.append(f"{label} lost managed server(s): {', '.join(absent)}")
                        if not source_problem:
                            # Stale provenance in either direction: a server was
                            # added to .mcp.json and not yet mirrored, or removed
                            # from it and still mirrored here.
                            behind = sorted(expected - managed)
                            if behind:
                                problems.append(f"{label} is behind the project MCP surface "
                                                f"(not yet mirrored: {', '.join(behind)})")
                            stale = sorted(managed - expected)
                            if stale:
                                problems.append(f"{label} still mirrors server(s) no longer in the project "
                                                f"MCP surface: {', '.join(stale)}")
            elif doc is not None:
                problems.append(f"{label} top level is not an object")

        if "skills_symlink" in prof:
            link = ROOT / prof["skills_symlink"]["link"]
            target = ROOT / prof["skills_symlink"]["target"]
            if not link.is_symlink():
                problems.append(f"{prof['skills_symlink']['link']} symlink missing")
            elif not link.exists():
                problems.append(f"{prof['skills_symlink']['link']} symlink broken")
            elif link.resolve() != target.resolve():
                problems.append(
                    f"{prof['skills_symlink']['link']} points at {os.readlink(link)}, "
                    f"expected {prof['skills_symlink']['target']}")
        if "context_files" in prof and path.exists():
            try:
                doc = load_json(path) if path.suffix == ".json" else None
            except SystemExit:
                doc = None  # invalid JSON already reported above
            current = _nested_get(doc, prof["context_files"]["key"]) if isinstance(doc, dict) else None
            wanted = prof["context_files"]["want"][0]
            listed = current if isinstance(current, list) else [current] if isinstance(current, str) else []
            if wanted not in listed:
                problem = f"context files setting does not include {wanted} — AGENTS.md is ignored"
                if isinstance(doc, dict) and _context_shape_blocked(doc, prof["context_files"]["key"]):
                    dotted = ".".join(prof["context_files"]["key"])
                    problem += (f"; {dotted} in {label} has an unexpected shape, so the bridge "
                                f"refuses to rewrite it — edit {label} by hand so {dotted} lists "
                                f"{wanted}, then re-run the bridge")
                problems.append(problem)

        tools.append({
            "id": tool_id,
            "display_name": prof["display_name"],
            "status": "issue" if problems else "healthy",
            "problems": problems,
            "fix": "/cc-suite:bridge-tools",
        })

    # Only a real selection can mark a tool as disabled; under the DEFAULT_TOOLS
    # fallback nothing has been deselected, so nothing is stale.
    if explicit_selection:
        for tool_id, prof in PROFILES.items():
            if prof.get("bridged_by") != "registry" or tool_id in enabled:
                continue
            if not _bridged_artifacts_present(prof):
                continue
            target = prof["mcp"]["path"]
            if prof["mcp"].get("scope") == "global":
                owned = _owned_by_this_workspace(prof)
                if owned is False:
                    # Another project on this machine bridged it. Reporting that
                    # as this project's problem produces a permanently red check
                    # whose auto fix is a no-op and whose only manual remedy
                    # (`--unbridge`) destroys the owning project's bridge.
                    continue
                if owned is None:
                    # Provenance predates workspace attribution, so ownership is
                    # genuinely unknown. Say so instead of asserting it is ours.
                    tools.append({
                        "id": tool_id,
                        "display_name": prof["display_name"],
                        "status": "info",
                        "problems": [
                            f"disabled, but {target} is still bridged. That target is machine-wide "
                            "and its provenance does not record which project wrote it, so cc-suite "
                            "cannot tell whether this project owns it. If it is this project's, run "
                            f"`python3 bridge_tools.py --unbridge {tool_id}` to revoke it; if another "
                            "project owns it, leave it alone."
                        ],
                        "fix": "/cc-suite:bridge-tools",
                    })
                    continue
                problem = (f"disabled, but {target} is still bridged with this project's MCP "
                           "surface — that target is machine-wide, so cc-suite never removes it "
                           f"automatically; run `python3 bridge_tools.py --unbridge {tool_id}` to "
                           "revoke it")
            else:
                problem = (f"disabled, but cc-suite artifacts are still present at {target} — "
                           "re-run `python3 bridge_tools.py`; if that reports a file it refuses to "
                           f"touch, repair it and run `python3 bridge_tools.py --unbridge {tool_id}`")
            tools.append({
                "id": tool_id,
                "display_name": prof["display_name"],
                "status": "issue",
                "problems": [problem],
                "fix": "/cc-suite:bridge-tools",
            })

    print(json.dumps({"schema": 1, "enabled": enabled, "tools": tools}, indent=2))
    return 0


def detect_tools() -> list[dict]:
    """Report which tool CLIs are actually on PATH, for the init picker.

    Claude is always reported installed: cc-suite runs as a Claude Code plugin,
    so the host is present by definition even when no `claude` binary is on the
    PATH of this subprocess (npm-less installs, sandboxed shells)."""
    import shutil

    out = []
    for tool_id, prof in PROFILES.items():
        binary = prof.get("binary")
        installed = tool_id == "claude" or bool(binary and shutil.which(binary))
        out.append(
            {
                "id": tool_id,
                "display_name": prof["display_name"],
                "binary": binary,
                "installed": installed,
                "china_tier": prof.get("china_tier"),
                "china_note": CHINA_TIER_NOTE.get(prof.get("china_tier", ""), ""),
                "bridged_by": prof.get("bridged_by"),
            }
        )
    return out


def write_enabled_tools(selected: list[str], config_path: Path = CONFIG) -> str:
    """Rewrite the `## Enabled Tools` task list to exactly `selected`.

    Existing items only change in the checkbox column — the section's prose is
    left as written so the guidance stays in one place
    (migrate_config.MANAGED_SECTIONS). A chosen tool the section does not list
    at all is appended as a ticked item, so the selection this reports is the
    one the next parse will read back."""
    chosen = {t for t in selected if t in PROFILES} | {"claude"}

    if not config_path.exists():
        err(f"{config_path.name} not found — run /cc-suite:init first")
        raise SystemExit(2)
    text = config_path.read_text(encoding="utf-8")

    m = re.search(
        r"^[ \t]*#{1,6}[ \t]*Enabled[ \t]+Tools[ \t]*$"
        r"(.*?)(?=^[ \t]*#{1,6}[ \t]+(?![-*][ \t])|\Z)",
        text,
        re.IGNORECASE | re.MULTILINE | re.DOTALL,
    )
    if not m:
        err("no '## Enabled Tools' section — run migrate_config.py first")
        raise SystemExit(2)

    listed: set[str] = set()

    # Both list forms parse_enabled_tools() accepts have to be reticked, and the
    # tool token has to be recognized by the same character class it uses — a
    # form this misses is a tool the caller cannot deselect.
    def retick(line: str) -> str:
        hit = re.match(r"^([ \t]*[-*][ \t]+)\[([ xX])\]([ \t]+)([A-Za-z0-9_-]+)(.*)$", line)
        if hit:
            tool_id = resolve_id(hit.group(4))
            if tool_id is None:
                return line
            listed.add(tool_id)
            box = "x" if tool_id in chosen else " "
            return f"{hit.group(1)}[{box}]{hit.group(3)}{hit.group(4)}{hit.group(5)}"
        plain = re.match(r"^([ \t]*[-*][ \t]+)([A-Za-z0-9_-]+)(.*)$", line)
        if not plain:
            return line
        tool_id = resolve_id(plain.group(2))
        if tool_id is None:
            return line
        listed.add(tool_id)
        box = "x" if tool_id in chosen else " "
        return f"{plain.group(1)}[{box}] {plain.group(2)}{plain.group(3)}"

    lines = [retick(ln) for ln in m.group(1).split("\n")]
    absent = [t for t in PROFILES if t in chosen and t not in listed]
    if absent:
        additions = [f"- [x] {t}" for t in absent]
        checkboxes = [i for i, ln in enumerate(lines)
                      if re.match(r"^[ \t]*[-*][ \t]+\[[ xX]\]", ln)]
        if checkboxes:
            at = checkboxes[-1] + 1
        else:
            # No list yet: start one after the last prose line, never at index 0
            # (that slot holds the newline ending the heading).
            at = max((i for i, ln in enumerate(lines) if ln.strip()), default=0) + 1
            additions = ["", *additions]
        lines[at:at] = additions
    body = "\n".join(lines)
    updated = text[: m.start(1)] + body + text[m.end(1) :]
    if updated != text:
        _atomic_write_text(config_path, updated)
    return ", ".join(sorted(chosen))


def main(argv: list[str]) -> int:
    args = list(argv)
    if args and args[0] == "--status":
        return print_status()

    if args and args[0] == "--detect":
        print(json.dumps(detect_tools(), indent=2))
        return 0

    if args and args[0] == "--health":
        return health_check()

    if args and args[0] == "--enabled":
        # Plain-text query for shell callers (init.sh gates its per-tool steps
        # on this). Falls back to DEFAULT_TOOLS exactly like the bridge does, so
        # a project without the section keeps its current behaviour.
        for tool_id in parse_enabled_tools():
            print(tool_id)
        return 0

    if args and args[0] == "--set-enabled":
        if len(args) < 2:
            err("--set-enabled requires a comma-separated list")
            return 2
        picked = [resolve_id(t) or t for t in args[1].split(",") if t.strip()]
        ok(f"enabled tools: {write_enabled_tools(picked)}")
        return 0

    if args and args[0] == "--unbridge":
        # `--unbridge` alone tears down every registry tool (what unbridge.sh
        # runs); `--unbridge kimi` scopes it to one, so a machine-wide target can
        # be revoked without touching this project's other bridges.
        only: list[str] | None = None
        if len(args) > 1 and args[1].strip():
            only = []
            for token in args[1].split(","):
                tid = resolve_id(token)
                if tid is None or PROFILES[tid].get("bridged_by") != "registry":
                    err(f"--unbridge: {token.strip()!r} is not a registry-bridged tool")
                    return 2
                if tid not in only:
                    only.append(tid)
        for tool_id, prof in PROFILES.items():
            if prof.get("bridged_by") != "registry":
                continue
            if only is not None and tool_id not in only:
                continue
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

    if selected is not None:
        enabled, explicit_selection = selected, False
        # `--tools` writes real artifacts but changes no config, so the next
        # plain run reconciles anything it bridged that the config deselects.
        # Say so here rather than let /cc-suite:update quietly undo it later.
        config_enabled, config_explicit = _parse_enabled(CONFIG)
        if config_explicit:
            # Only warn where a later plain run really would reap: a
            # machine-global target is deliberately never removed automatically,
            # so promising its removal would be false.
            transient = [t for t in selected if t not in config_enabled
                         and PROFILES.get(t, {}).get("bridged_by") == "registry"
                         and PROFILES.get(t, {}).get("mcp", {}).get("scope") != "global"]
            if transient:
                warn(f"--tools is a one-off: {', '.join(transient)} not enabled in "
                     f"{CONFIG.name} — the next plain `bridge_tools.py` run (/cc-suite:update, "
                     "/cc-suite:repair, /cc-suite:init) removes what this run writes; use "
                     "`--set-enabled` to make the selection stick")
    else:
        enabled, explicit_selection = _parse_enabled(CONFIG)
    registry_tools = [t for t in enabled if PROFILES.get(t, {}).get("bridged_by") == "registry"]

    existing_bridged = [t for t in enabled if PROFILES.get(t, {}).get("bridged_by") == "existing"]
    if existing_bridged:
        note("handled by existing bridges (unchanged here): " + ", ".join(existing_bridged))

    # Only a real selection revokes: a `--tools` one-off and the DEFAULT_TOOLS
    # fallback are not statements that the other tools should be torn down.
    if explicit_selection:
        reconcile_disabled(enabled)

    if not registry_tools:
        note("no registry-bridged tools enabled — nothing to do")
        return 0

    servers = desired_servers()
    for tool_id in registry_tools:
        bridge_tool(tool_id, servers)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
