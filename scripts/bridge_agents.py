#!/usr/bin/env python3
"""
cc-suite: bridge `.cc-suite/agents/*.md` into MCP server registrations.

Each `.cc-suite/agents/<name>.md` file declares one specialized claude-octopus
advisor — a value-over-rules persona with its own system prompt, model, tool
restrictions, working directory, and timeline storage. This script registers
each agent as an MCP server in **both** `.mcp.json` (Claude side) and
`.codex/config.toml` (Codex side), so either tool can consult any advisor.

Layout of an agent file:

    ---
    name: north_star_advisor          # optional, defaults to filename stem
    description: One-line summary visible to the caller.
    model: opus                       # opus | sonnet | haiku
    tool_name: north_star_consult     # optional, defaults to <name>_consult
    allowed_tools: [Read, Grep, Glob] # default if omitted: [Read, Grep, Glob]
    permission_mode: default          # default | acceptEdits | plan | dontAsk | auto | bypassPermissions
    max_turns: 5
    max_budget_usd: 0.50
    effort: high                      # low | medium | high | max
    cwd: .                            # relative to project root
    additional_dirs: []
    prompt_mode: append               # append (default) or replace
    ---

    Body content becomes the system prompt. With `prompt_mode: append` (the
    default), this text is appended to Claude Code's preset; with `replace`,
    it replaces the preset entirely.

Idempotency: this script is the sole owner of all cc-suite-managed advisor
entries. On every run it removes its prior registrations (identified by a
`_cc_suite_agent` marker key in .mcp.json and by `# >>> cc-suite-agent: ...`
sentinel blocks in .codex/config.toml) and rewrites from the current files.

Safety: if a user-managed entry exists with the same name (no marker, no
sentinel), the script refuses to overwrite it and reports the conflict.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List

# ── locations ────────────────────────────────────────────────────────────────
AGENT_DIR = Path(".cc-suite/agents")
MCP_FILE = Path(".mcp.json")
CODEX_FILE = Path(".codex/config.toml")
GITIGNORE = Path(".cc-suite/.gitignore")

# ── sentinels / markers ──────────────────────────────────────────────────────
MARKER_KEY = "_cc_suite_agent"          # in .mcp.json server entries
SENTINEL_OPEN = "# >>> cc-suite-agent: " # in .codex/config.toml (followed by <name> >>>)
SENTINEL_CLOSE = "# <<< cc-suite-agent: "

# ── defaults ─────────────────────────────────────────────────────────────────
DEFAULT_ALLOWED_TOOLS = ["Read", "Grep", "Glob"]
DEFAULT_MAX_TURNS = 5
DEFAULT_PROMPT_MODE = "append"
DEFAULT_MODEL = None  # let claude-octopus pick


def enabled_tools() -> set:
    """Enabled coding agents from .cc-suite.md, via bridge_tools.py --enabled.

    Falls back to the pre-selection default (claude/codex/antigravity) when the
    config, section, or helper is unavailable, matching init.sh's behavior.
    """
    script = Path(__file__).parent / "bridge_tools.py"
    try:
        out = subprocess.run(
            [sys.executable, str(script), "--enabled"],
            capture_output=True, text=True, timeout=10,
        )
        tools = {line.strip() for line in out.stdout.splitlines() if line.strip()}
        if tools:
            return tools
    except Exception:
        pass
    return {"claude", "codex", "antigravity"}


def read_pin() -> str:
    """Read the pinned claude-octopus version from the shared pin file."""
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    candidates = []
    if plugin_root:
        candidates.append(Path(plugin_root) / "scripts/lib/claude-octopus-pin.txt")
    # Also try the path relative to this script's location.
    candidates.append(Path(__file__).parent / "lib/claude-octopus-pin.txt")
    for p in candidates:
        if p.is_file():
            pin = p.read_text().strip()
            if pin:
                return pin
    print(
        "! claude-octopus-pin.txt missing or empty — refusing to register advisors "
        "against an unpinned claude-octopus",
        file=sys.stderr,
    )
    raise SystemExit(2)


# ── frontmatter parser ───────────────────────────────────────────────────────
# Deliberately a tiny subset of YAML — no nesting, no anchors, no multi-line.
# Just enough for flat key: value pairs with string / int / float / bool / list.
_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n(.*)$", re.DOTALL)


def _parse_scalar(val: str) -> Any:
    """Parse a single YAML-ish scalar to Python."""
    val = val.strip()
    if not val:
        return ""
    # Quoted string.
    if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
        return val[1:-1]
    # List.
    if val.startswith("[") and val.endswith("]"):
        inner = val[1:-1].strip()
        if not inner:
            return []
        return [_parse_scalar(item) for item in _split_csv(inner)]
    # Bool.
    if val.lower() in ("true", "false"):
        return val.lower() == "true"
    # Number.
    try:
        if "." in val:
            return float(val)
        return int(val)
    except ValueError:
        pass
    # Bare string.
    return val


def _split_csv(s: str) -> List[str]:
    """Split a comma-separated list, respecting simple quoted strings."""
    out, cur, in_q, q = [], [], False, ""
    for ch in s:
        if in_q:
            cur.append(ch)
            if ch == q:
                in_q = False
        elif ch in ('"', "'"):
            in_q = True
            q = ch
            cur.append(ch)
        elif ch == ",":
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur).strip())
    return [x for x in out if x]


def _validate_agent(agent: Dict[str, Any]) -> None:
    """Validate the documented agent schema beyond the name check.

    `model` is deliberately not enum-checked: claude-octopus accepts full model
    ids as well as the opus/sonnet/haiku aliases the header documents. It must
    still be a non-empty string — an empty or non-string value would be
    silently stringified into a broken CLAUDE_MODEL registration.
    """
    if "model" in agent and not (isinstance(agent["model"], str) and agent["model"].strip()):
        raise ValueError(f"model must be a non-empty string, got {agent['model']!r}")
    if "prompt_mode" in agent and str(agent["prompt_mode"]).lower() not in ("append", "replace"):
        raise ValueError(f"prompt_mode must be 'append' or 'replace', got {agent['prompt_mode']!r}")
    if "permission_mode" in agent and str(agent["permission_mode"]) not in (
        "default", "acceptEdits", "plan", "dontAsk", "auto", "bypassPermissions",
    ):
        raise ValueError(f"invalid permission_mode {agent['permission_mode']!r}")
    if "effort" in agent and str(agent["effort"]) not in ("low", "medium", "high", "max"):
        raise ValueError(f"effort must be low | medium | high | max, got {agent['effort']!r}")
    if "tool_name" in agent and not re.match(r"^[A-Za-z][A-Za-z0-9_-]*$", str(agent["tool_name"])):
        raise ValueError(f"invalid tool_name {agent['tool_name']!r}")
    if "max_turns" in agent and not (
        isinstance(agent["max_turns"], int)
        and not isinstance(agent["max_turns"], bool)
        and agent["max_turns"] > 0
    ):
        raise ValueError(f"max_turns must be a positive integer, got {agent['max_turns']!r}")
    if "max_budget_usd" in agent and not (
        isinstance(agent["max_budget_usd"], (int, float))
        and not isinstance(agent["max_budget_usd"], bool)
        and agent["max_budget_usd"] > 0
    ):
        raise ValueError(f"max_budget_usd must be a positive number, got {agent['max_budget_usd']!r}")
    if agent.get("allowed_tools") == []:
        raise ValueError(
            "allowed_tools is an explicit empty list — claude-octopus would fall back to its "
            "own defaults; use disallowed_tools to block tools instead"
        )


def parse_agent_file(path: Path) -> Dict[str, Any]:
    """Parse one agent file into a dict with keys + '_body' for the system prompt.

    Supports flat `key: value` plus YAML block scalars (`key: |` literal,
    `key: >` folded). Block-scalar continuation lines are detected by
    indentation greater than the key's column.
    """
    text = path.read_text(encoding="utf-8")
    m = _FRONTMATTER_RE.match(text)
    if not m:
        raise ValueError(f"{path}: no YAML frontmatter (expected leading '---')")
    fm_text, body = m.group(1), m.group(2).strip()
    agent: Dict[str, Any] = {}
    lines = fm_text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            i += 1
            continue
        if ":" not in line:
            i += 1
            continue
        key, _, val = line.partition(":")
        key = key.strip()
        val_stripped = val.strip()
        # Block scalar marker: `key: |` (literal) or `key: >` (folded).
        if val_stripped in ("|", ">"):
            mode = val_stripped
            base_indent = len(raw) - len(raw.lstrip())
            collected: List[str] = []
            i += 1
            while i < len(lines):
                cont = lines[i]
                if not cont.strip():
                    collected.append("")
                    i += 1
                    continue
                indent = len(cont) - len(cont.lstrip())
                if indent <= base_indent:
                    break
                collected.append(cont)
                i += 1
            # Strip the block's actual indentation — the minimum across its
            # non-blank lines — not a hardcoded two spaces; YAML allows any
            # amount greater than the key's column.
            non_blank = [ln for ln in collected if ln.strip()]
            if non_blank:
                strip_n = min(len(ln) - len(ln.lstrip()) for ln in non_blank)
                collected = [ln[strip_n:] if ln.strip() else "" for ln in collected]
            if mode == "|":
                # Literal: preserve newlines exactly.
                value = "\n".join(collected).rstrip("\n")
            else:
                # Folded: blank lines stay, single newlines become spaces.
                pieces: List[str] = []
                buf: List[str] = []
                for ln in collected:
                    if ln == "":
                        if buf:
                            pieces.append(" ".join(buf))
                            buf = []
                        pieces.append("")
                    else:
                        buf.append(ln)
                if buf:
                    pieces.append(" ".join(buf))
                # Collapse trailing blanks.
                while pieces and pieces[-1] == "":
                    pieces.pop()
                value = "\n".join(pieces)
            agent[key] = value
            continue
        agent[key] = _parse_scalar(val)
        i += 1
    agent["_body"] = body
    agent.setdefault("name", path.stem)
    # Validate name — must be a valid MCP server key (alphanumeric, dash, underscore).
    if not re.match(r"^[A-Za-z][A-Za-z0-9_-]*$", str(agent["name"])):
        raise ValueError(f"{path}: invalid agent name {agent['name']!r}")
    _validate_agent(agent)
    return agent


# ── env-var builder (the shared agent→config translation) ────────────────────
def agent_to_env(agent: Dict[str, Any]) -> Dict[str, str]:
    """Translate a parsed agent dict into the env-var map claude-octopus reads."""
    name = str(agent["name"])
    env: Dict[str, str] = {}
    env["CLAUDE_SERVER_NAME"] = name
    env["CLAUDE_TOOL_NAME"] = str(agent.get("tool_name") or f"{name}_consult")
    env["CLAUDE_DESCRIPTION"] = str(agent.get("description") or f"Consult the {name} advisor.")

    # Prompt: append (keep Claude Code preset + add values) vs replace (full custom).
    prompt_mode = str(agent.get("prompt_mode") or DEFAULT_PROMPT_MODE).lower()
    body = str(agent.get("_body") or "")
    if not body:
        raise ValueError(f"{name}: empty body — agent file must contain a system prompt")
    if prompt_mode == "replace":
        env["CLAUDE_SYSTEM_PROMPT"] = body
    else:
        env["CLAUDE_APPEND_PROMPT"] = body

    # Optional knobs — each only emitted when set, so claude-octopus keeps its own defaults.
    if "model" in agent:
        env["CLAUDE_MODEL"] = str(agent["model"])
    elif DEFAULT_MODEL:
        env["CLAUDE_MODEL"] = DEFAULT_MODEL

    tools = agent.get("allowed_tools", DEFAULT_ALLOWED_TOOLS)
    if isinstance(tools, list) and tools:
        env["CLAUDE_ALLOWED_TOOLS"] = ",".join(str(t) for t in tools)
    elif isinstance(tools, str) and tools:
        env["CLAUDE_ALLOWED_TOOLS"] = tools

    disallowed = agent.get("disallowed_tools")
    if isinstance(disallowed, list) and disallowed:
        env["CLAUDE_DISALLOWED_TOOLS"] = ",".join(str(t) for t in disallowed)

    if "permission_mode" in agent:
        env["CLAUDE_PERMISSION_MODE"] = str(agent["permission_mode"])
    env["CLAUDE_MAX_TURNS"] = str(agent.get("max_turns", DEFAULT_MAX_TURNS))
    if "max_budget_usd" in agent:
        env["CLAUDE_MAX_BUDGET_USD"] = str(agent["max_budget_usd"])
    if "effort" in agent:
        env["CLAUDE_EFFORT"] = str(agent["effort"])

    cwd = agent.get("cwd")
    if cwd is not None and str(cwd).strip():
        env["CLAUDE_CWD"] = str(Path(str(cwd)).resolve())

    additional = agent.get("additional_dirs")
    if isinstance(additional, list) and additional:
        env["CLAUDE_ADDITIONAL_DIRS"] = ",".join(str(Path(d).resolve()) for d in additional)

    # Per-agent timeline dir: in-project, gitignored. Absolute path so claude-octopus
    # finds it regardless of where Codex starts the MCP server from.
    timeline_dir = (AGENT_DIR / name / "timeline").resolve()
    env["CLAUDE_TIMELINE_DIR"] = str(timeline_dir)

    return env


# ── TOML scalar emitter (small, just enough for env values) ──────────────────
def _toml_str(v: str) -> str:
    """Emit a TOML basic-string literal for v. Multi-line strings use triple quotes."""
    if "\n" in v:
        # Use TOML's multi-line basic string (triple-quoted).
        escaped = v.replace("\\", "\\\\").replace('"""', '"\\""')
        return '"""\n' + escaped + '\n"""'
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _toml_quote_key(name: str) -> str:
    """Quote a TOML key if necessary."""
    if re.match(r"^[A-Za-z0-9_-]+$", name):
        return name
    return '"' + name.replace('\\', '\\\\').replace('"', '\\"') + '"'


# ── .mcp.json update ─────────────────────────────────────────────────────────
def update_mcp_json(agents: List[Dict[str, Any]], pin: str) -> List[str]:
    """Rewrite cc-suite-managed advisor entries in .mcp.json. Returns conflicts."""
    if MCP_FILE.exists():
        try:
            data = json.loads(MCP_FILE.read_text())
        except json.JSONDecodeError:
            print(f"! {MCP_FILE} is not valid JSON — leaving alone; fix it and re-run", file=sys.stderr)
            raise SystemExit(2)
        if not isinstance(data, dict):
            print(f"! {MCP_FILE} top level must be an object — leaving alone; fix it and re-run", file=sys.stderr)
            raise SystemExit(2)
    else:
        data = {}

    servers = data.get("mcpServers")
    if servers is None:
        data["mcpServers"] = servers = {}
    elif not isinstance(servers, dict):
        print(f"! {MCP_FILE} mcpServers must be an object — leaving alone; fix it and re-run", file=sys.stderr)
        raise SystemExit(2)

    # Drop existing cc-suite-managed advisor entries.
    for k in [k for k, v in servers.items() if isinstance(v, dict) and v.get(MARKER_KEY)]:
        del servers[k]

    conflicts: List[str] = []
    for agent in agents:
        name = str(agent["name"])
        if name in servers:
            conflicts.append(name)
            continue
        servers[name] = {
            MARKER_KEY: name,
            "type": "stdio",
            "command": "npx",
            "args": ["-y", f"claude-octopus@{pin}"],
            "env": agent_to_env(agent),
        }

    MCP_FILE.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return conflicts


# ── .codex/config.toml update ────────────────────────────────────────────────
def update_codex_toml(agents: List[Dict[str, Any]], pin: str) -> List[str]:
    """Rewrite cc-suite-managed advisor blocks in .codex/config.toml. Returns conflicts."""
    CODEX_FILE.parent.mkdir(parents=True, exist_ok=True)
    text = CODEX_FILE.read_text(encoding="utf-8") if CODEX_FILE.exists() else ""

    # Refuse to rewrite when sentinel blocks are unbalanced or mismatched: an
    # unmatched opener would otherwise swallow everything to EOF on the
    # rewrite, a stray closer signals a corrupted config we must not silently
    # repair, and a closer naming a different agent than its opener means the
    # block boundaries cannot be trusted.
    depth = 0
    open_name = None
    mismatched = False
    for line in text.splitlines():
        s = line.rstrip()
        if s.startswith(SENTINEL_OPEN) and s.endswith(">>>"):
            depth += 1
            if depth > 1:
                break
            open_name = s[len(SENTINEL_OPEN):-len(">>>")].strip()
        elif s.startswith(SENTINEL_CLOSE) and s.endswith("<<<"):
            depth -= 1
            if depth < 0:
                break
            if s[len(SENTINEL_CLOSE):-len("<<<")].strip() != open_name:
                mismatched = True
                break
    if depth != 0 or mismatched:
        print(
            f"! {CODEX_FILE}: unbalanced or mismatched cc-suite-agent sentinel block — "
            "leaving alone; repair the sentinels manually and re-run",
            file=sys.stderr,
        )
        raise SystemExit(2)

    # Strip every existing sentinel-bounded cc-suite-agent block AND one trailing
    # blank line immediately after each closed block — keeps the file from
    # accumulating blank lines across re-runs.
    kept: List[str] = []
    skip = False
    just_ended = False
    for line in text.splitlines():
        s = line.rstrip()
        if s.startswith(SENTINEL_OPEN) and s.endswith(">>>"):
            skip = True
            continue
        if s.startswith(SENTINEL_CLOSE) and s.endswith("<<<"):
            skip = False
            just_ended = True
            continue
        if skip:
            continue
        if just_ended and not s.strip():
            just_ended = False
            continue
        just_ended = False
        kept.append(line)
    cleaned = "\n".join(kept).rstrip()

    # Detect conflicts with user-managed [mcp_servers.<name>] blocks that DIDN'T
    # have our sentinel.
    conflicts: List[str] = []
    existing_names = set(
        m.group(1)
        for m in re.finditer(
            r'^\s*\[mcp_servers\.((?:"[^"]+"|[A-Za-z0-9_-]+))\]\s*$',
            cleaned,
            re.MULTILINE,
        )
    )
    # Unwrap quoted names for comparison.
    existing_names = {n.strip('"') for n in existing_names}

    # Append fresh blocks.
    blocks: List[str] = []
    for agent in agents:
        name = str(agent["name"])
        if name in existing_names:
            conflicts.append(name)
            continue
        env = agent_to_env(agent)
        env_block_lines = [f"{_toml_quote_key(k)} = {_toml_str(v)}" for k, v in env.items()]
        env_block = "\n".join(env_block_lines)
        # Timeout fields must appear before the [.env] sub-table header — once
        # that sub-table is opened we cannot add more keys to the parent table
        # without a new [parent] header. tool_timeout_sec=900 covers
        # multi-minute claude_code agent calls (Codex default is ~120s);
        # startup_timeout_sec=60 covers cold-cache npx -y downloads.
        block = (
            f"{SENTINEL_OPEN}{name} >>>\n"
            f"[mcp_servers.{_toml_quote_key(name)}]\n"
            f'command = "npx"\n'
            f'args    = ["-y", "claude-octopus@{pin}"]\n'
            f"startup_timeout_sec = 60\n"
            f"tool_timeout_sec    = 900\n"
            f"[mcp_servers.{_toml_quote_key(name)}.env]\n"
            f"{env_block}\n"
            f"{SENTINEL_CLOSE}{name} <<<\n"
        )
        blocks.append(block)

    if blocks:
        joined_blocks = "\n".join(blocks).rstrip()
        final = (cleaned + "\n\n" + joined_blocks + "\n") if cleaned else (joined_blocks + "\n")
    else:
        final = (cleaned + "\n") if cleaned else ""

    CODEX_FILE.write_text(final, encoding="utf-8")
    return conflicts


# ── timeline dirs + .gitignore ───────────────────────────────────────────────
def ensure_timeline_layout(agents: List[Dict[str, Any]]) -> None:
    """Create per-agent timeline dirs and add a .gitignore so they stay private by default."""
    for agent in agents:
        d = AGENT_DIR / str(agent["name"]) / "timeline"
        d.mkdir(parents=True, exist_ok=True)

    if not AGENT_DIR.exists():
        return

    rule = "*/timeline/"
    note = "# cc-suite: agent timelines are private by default; remove this line to share with the team\n"
    if not GITIGNORE.exists():
        GITIGNORE.parent.mkdir(parents=True, exist_ok=True)
        GITIGNORE.write_text(note + rule + "\n", encoding="utf-8")
    else:
        existing = GITIGNORE.read_text(encoding="utf-8")
        if rule not in existing:
            with GITIGNORE.open("a", encoding="utf-8") as f:
                if not existing.endswith("\n"):
                    f.write("\n")
                f.write(note)
                f.write(rule + "\n")


# ── main ─────────────────────────────────────────────────────────────────────
def main() -> int:
    if not AGENT_DIR.exists() or not any(AGENT_DIR.glob("*.md")):
        # No agents declared. Only touch the registries if they already exist
        # (we may need to clean up entries from a prior run); never create them
        # just to write an empty mcpServers map.
        conflicts_mcp: List[str] = []
        conflicts_toml: List[str] = []
        if MCP_FILE.exists():
            conflicts_mcp = update_mcp_json([], read_pin())
        if CODEX_FILE.exists():
            conflicts_toml = update_codex_toml([], read_pin())
        if AGENT_DIR.exists():
            print(f"· no agents in {AGENT_DIR}/ — cleared any prior advisor registrations")
        else:
            print(f"· no {AGENT_DIR}/ directory — nothing to bridge")
        return 1 if (conflicts_mcp or conflicts_toml) else 0

    pin = read_pin()
    agents: List[Dict[str, Any]] = []
    for path in sorted(AGENT_DIR.glob("*.md")):
        try:
            agents.append(parse_agent_file(path))
        except Exception as e:
            print(f"! failed to parse {path}: {e}", file=sys.stderr)
            return 1

    names = [a["name"] for a in agents]
    if len(set(names)) != len(names):
        dupes = sorted({n for n in names if names.count(n) > 1})
        print(f"! duplicate agent names: {dupes}", file=sys.stderr)
        return 1

    conflicts_mcp = update_mcp_json(agents, pin)

    # Project advisors into Codex only when Codex is an enabled tool. When it
    # is disabled, clean up managed blocks in an existing config, but never
    # create .codex/ for a deselected tool.
    codex_enabled = "codex" in enabled_tools()
    if codex_enabled:
        conflicts_toml = update_codex_toml(agents, pin)
        codex_target = " + .codex/config.toml"
    elif CODEX_FILE.exists():
        conflicts_toml = update_codex_toml([], pin)
        codex_target = " (codex not enabled — cleared its advisor blocks)"
    else:
        conflicts_toml = []
        codex_target = " (codex not enabled — skipped)"
    ensure_timeline_layout(agents)

    conflict_set = set(conflicts_mcp) | set(conflicts_toml)
    registered = [a for a in agents if a["name"] not in conflict_set]
    print(f"✓ bridged {len(registered)}/{len(agents)} advisor(s) into .mcp.json{codex_target}")
    for a in registered:
        name = str(a["name"])
        tool = str(a.get("tool_name") or f"{name}_consult")
        print(f"    advisor: {name}  → tool: mcp__{name}__{tool}")

    if conflicts_mcp:
        print(f"! NOT registered in .mcp.json (user-managed entry exists): {sorted(set(conflicts_mcp))}", file=sys.stderr)
        print("    rename the agent or remove the conflicting entry, then re-run.", file=sys.stderr)
    if conflicts_toml:
        print(f"! NOT registered in .codex/config.toml (user-managed entry exists): {sorted(set(conflicts_toml))}", file=sys.stderr)
        print("    rename the agent or remove the conflicting entry, then re-run.", file=sys.stderr)

    return 1 if (conflicts_mcp or conflicts_toml) else 0


if __name__ == "__main__":
    sys.exit(main())
