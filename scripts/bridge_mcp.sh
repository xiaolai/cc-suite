#!/usr/bin/env bash
# cc-suite: mirror .mcp.json MCP servers into Codex and Antigravity configs.
#
# Codex reads MCP configuration from .codex/config.toml, not .mcp.json. Agy
# reads workspace MCP configuration from .agents/mcp_config.json. The Codex
# portion is sentinel-guarded; the agy portion has a companion provenance file.
#
# Idempotent: re-running rewrites only the sentinel block; entries declared
# outside it (manually added to config.toml) are never touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The embedded Python blocks below are quoted heredocs, so they read the script
# location from the environment to import scripts/lib modules.
export CC_SUITE_SCRIPT_DIR="$SCRIPT_DIR"

# Honor the project's tool selection (.cc-suite.md `## Enabled Tools`). Falls
# back to claude/codex/antigravity when the file or section is absent, so
# pre-selection projects keep their old behavior.
ENABLED_TOOLS="$(python3 "${SCRIPT_DIR}/bridge_tools.py" --enabled 2>/dev/null || true)"
[ -n "$ENABLED_TOOLS" ] || ENABLED_TOOLS=$'claude\ncodex\nantigravity'
tool_enabled() { printf '%s\n' "$ENABLED_TOOLS" | grep -qx "$1"; }

if tool_enabled codex; then
  CC_SUITE_CODEX_ENABLED=1
else
  CC_SUITE_CODEX_ENABLED=0
fi
export CC_SUITE_CODEX_ENABLED

if python3 - <<'PY'
from __future__ import annotations
import json, os, re, sys, tempfile
from pathlib import Path

sys.path.insert(0, str(Path(os.environ["CC_SUITE_SCRIPT_DIR"]) / "lib"))
from toml_escape import escape_ctrl, quote_string  # noqa: E402

SENTINEL_START = "# >>> cc-suite-mcp >>>"
SENTINEL_END   = "# <<< cc-suite-mcp <<<"
# codex-cli is registered in .mcp.json so Claude can invoke Codex as a tool.
# It must not be mirrored back into Codex's own config.
SKIP_SERVERS = {"codex-cli"}


def main() -> int:
    # When Codex is not among the enabled tools, never create its tree. An
    # existing config is still reconciled (the cc-suite sentinel block is
    # removed) so a deselected Codex stops seeing the mirrored servers.
    codex_enabled = os.environ.get("CC_SUITE_CODEX_ENABLED", "1") == "1"
    if not codex_enabled:
        # Reconciliation of a deselected Codex must not depend on .mcp.json
        # being readable — the desired projection is empty either way.
        if not Path(".codex/config.toml").exists():
            print("· codex not enabled — skipping .codex/config.toml projection")
            return 0
        print("· codex not enabled — reconciling existing .codex/config.toml (cc-suite MCP block only)")
        servers: dict = {}
    else:
        mcp_path = Path(".mcp.json")
        if not mcp_path.exists():
            print("· .mcp.json does not exist — clearing cc-suite-owned projections")
            mcp = {}
        else:
            try:
                mcp = json.loads(mcp_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as e:
                print(f"! .mcp.json is not valid JSON: {e}", file=sys.stderr)
                return 1

        if not isinstance(mcp, dict):
            print(f"! .mcp.json top level must be an object (got {type(mcp).__name__})", file=sys.stderr)
            return 2
        servers = mcp.get("mcpServers")
        if servers is None:
            print("· .mcp.json has no mcpServers — clearing cc-suite-owned projections")
            servers = {}
        if not isinstance(servers, dict):
            print(f"! .mcp.json mcpServers must be an object (got {type(servers).__name__})", file=sys.stderr)
            return 2

        Path(".codex").mkdir(exist_ok=True)
    config_path = Path(".codex/config.toml")
    existing = config_path.read_text(encoding="utf-8") if config_path.exists() else ""

    # Strip old sentinel block so it can be rewritten cleanly on re-runs.
    s_start = existing.find(SENTINEL_START)
    s_end   = existing.find(SENTINEL_END)
    # A lone (partial) sentinel marker indicates manual editing / a botched
    # previous run; refuse to silently append a new block on top of it.
    if (s_start == -1) != (s_end == -1):
        print(
            f"! .codex/config.toml has only one of the cc-suite sentinel markers "
            f"({'start' if s_start != -1 else 'end'} present). "
            "Manually repair before rerunning.",
            file=sys.stderr,
        )
        return 2
    if s_start != -1 and s_end != -1:
        # Exactly one balanced, ordered block: an end marker before the start
        # marker, or duplicated markers, would splice unrelated user content.
        if (s_end < s_start
                or existing.count(SENTINEL_START) > 1
                or existing.count(SENTINEL_END) > 1):
            print(
                "! .codex/config.toml cc-suite sentinel markers are duplicated "
                "or out of order. Manually repair before rerunning.",
                file=sys.stderr,
            )
            return 2
        nl = existing.find("\n", s_end)
        base = existing[:s_start].rstrip("\n") + (
            "\n" + existing[nl + 1:] if nl != -1 else ""
        )
    else:
        base = existing

    # Only add servers not already declared in the non-sentinel portion.
    declared = _declared_servers(base)
    new_blocks: list[str] = []
    skipped: list[str] = []
    skipped_names: set[str] = set()
    warned: list[str] = []
    seen_codex_names: dict[str, str] = {}
    normalized: list[str] = []
    for name, cfg in servers.items():
        if not isinstance(cfg, dict):
            print(f"! {name}: server config must be an object, got {type(cfg).__name__} — skipped", file=sys.stderr)
            warned.append(name)
            continue
        if name in SKIP_SERVERS:
            skipped.append(f"{name} (not mirrored to Codex — it is the tool Codex runs as)")
            skipped_names.add(name)
            continue

        codex_name = _codex_name(name)
        previous_name = seen_codex_names.get(codex_name)
        if previous_name is not None and previous_name != name:
            print(
                f"! {name}: Codex name {codex_name!r} collides with {previous_name!r} after normalization — skipped",
                file=sys.stderr,
            )
            warned.append(name)
            continue
        seen_codex_names[codex_name] = name

        if codex_name != name:
            normalized.append(f"{name} → {codex_name}")

        if codex_name in declared:
            skipped.append(name)
            skipped_names.add(name)
            continue
        block = _toml_block(name, codex_name, cfg)
        if block is None:
            warned.append(name)
            print(f"! {name}: unsupported transport, missing required field, or invalid field type — skipped", file=sys.stderr)
            continue
        new_blocks.append(block)

    if skipped:
        print(f"· skipped: {skipped}")
    if normalized:
        print(f"· normalized for Codex: {normalized}")

    if new_blocks:
        sentinel = (
            f"\n{SENTINEL_START}\n"
            + "\n\n".join(new_blocks)
            + f"\n{SENTINEL_END}\n"
        )
        rendered = base.rstrip("\n") + sentinel
    else:
        # Reconcile deletions too: an old cc-suite sentinel block must not keep
        # exposing servers that disappeared from .mcp.json. Leave unrelated
        # user-authored TOML untouched.
        rendered = base.rstrip("\n") + ("\n" if base.strip() else "")
        if existing != rendered and s_start != -1:
            print("✓ .codex/config.toml: removed stale cc-suite MCP entries")

    if existing != rendered or new_blocks:
        # Same-directory unique temp + atomic rename so concurrent readers —
        # and concurrent bridge runs, which a fixed temp name would funnel
        # through one shared inode — never observe partial TOML.
        fd, tmp = tempfile.mkstemp(prefix=".cc-suite-tmp-", dir=str(config_path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(rendered)
            os.replace(tmp, config_path)
        except Exception:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
            raise

    if not new_blocks:
        if not warned:
            print("· no new servers to add")
        return 1 if warned else 0

    added = [n for n in servers if n not in SKIP_SERVERS
             and n not in skipped_names
             and n not in warned]
    print(f"✓ .codex/config.toml: added {len(added)} server(s): {added}")
    return 1 if warned else 0


def _codex_name(name: str) -> str:
    """Map a Claude MCP name to Codex's stricter server-name grammar."""
    if re.fullmatch(r'[a-zA-Z0-9_-]+', name):
        return name
    normalized = re.sub(r'[^a-zA-Z0-9_-]+', '-', name).strip('-_')
    return normalized or 'mcp-server'


KEY_TOKEN = r'"(?:[^"\\]|\\.)*"|\'[^\']*\'|[A-Za-z0-9_-]+'


def _unquote(tok: str) -> str:
    tok = tok.strip()
    if len(tok) >= 2 and tok[0] == tok[-1] == "'":
        return tok[1:-1]
    if len(tok) >= 2 and tok[0] == tok[-1] == '"':
        return re.sub(r"\\(.)", r"\1", tok[1:-1])
    return tok


def _key_parts(s: str) -> list[str]:
    return [_unquote(t) for t in re.findall(KEY_TOKEN, s)]


def _declared_servers(text: str) -> set[str]:
    """Server names already declared under `mcp_servers` in TOML `text`.

    Structural rather than substring, because every TOML spelling of the same
    key must be recognized — quoted segments, whitespace around dots, trailing
    comments, sub-tables, array-of-table headers, and dotted-key assignments —
    while a commented-out header must not count. Emitting a second table for a
    key that is already declared would make the file invalid TOML.
    """
    found: set[str] = set()
    current: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        header = (re.match(r"^\[\[\s*(.+?)\s*\]\]\s*(?:#.*)?$", line)
                  or re.match(r"^\[\s*(.+?)\s*\]\s*(?:#.*)?$", line))
        if header:
            current = _key_parts(header.group(1))
            if len(current) >= 2 and current[0] == "mcp_servers":
                found.add(current[1])
            continue
        assign = re.match(
            r"^((?:%(tok)s)(?:\s*\.\s*(?:%(tok)s))*)\s*=" % {"tok": KEY_TOKEN}, line
        )
        if assign:
            parts = current + _key_parts(assign.group(1))
            if len(parts) >= 2 and parts[0] == "mcp_servers":
                found.add(parts[1])
    return found


def _toml_block(name: str, codex_name: str, cfg: dict) -> str | None:
    transport = cfg.get("type", "stdio")
    lines: list[str] = [f"[mcp_servers.{codex_name}]"]
    if name != codex_name:
        lines.append(f"# Claude MCP name: {_escape_ctrl(name)}")

    if transport == "stdio":
        cmd = cfg.get("command")
        if not cmd or not isinstance(cmd, str):
            return None
        args = cfg.get("args")
        if args is not None and (
            not isinstance(args, list) or not all(isinstance(a, str) for a in args)
        ):
            # A bare string would be iterated as characters; non-string items
            # would render invalid TOML.
            return None
        lines.append(f"command = {_qs(cmd)}")
        if args:
            lines.append(f"args = [{', '.join(_qs(a) for a in args)}]")
        env = cfg.get("env")
        if env is None:
            env = {}
        # Explicit None check above: `env or {}` would let falsy invalid values
        # (an empty list, 0, "") bypass this type validation.
        if not isinstance(env, dict) or not all(isinstance(k, str) for k in env):
            return None
        if env:
            # Env values are not mirrored — embedding secrets in config.toml risks
            # committing them. Document the required vars as TOML comments instead.
            env_var_names = [_escape_ctrl(k) for k in sorted(env.keys())]
            lines.append(f"# env vars required — add [mcp_servers.{codex_name}.env] manually:")
            for k in env_var_names:
                lines.append(f"# {k} = \"<value>\"")
            print(
                f"⚠ {name}: env vars {env_var_names} not mirrored (values not safe to commit).\n"
                f"  Add to .codex/config.toml manually:\n"
                f"  [mcp_servers.{codex_name}.env]\n"
                + "\n".join(f"  {k} = \"<value>\"" for k in env_var_names)
            )

    elif transport in ("sse", "http", "streamable_http"):
        url = cfg.get("url")
        if not url or not isinstance(url, str):
            return None
        lines.append(f"url = {_qs(url)}")
        tok = cfg.get("bearer_token_env_var")
        if tok is not None and not isinstance(tok, str):
            return None
        if tok:
            lines.append(f"bearer_token_env_var = {_qs(tok)}")

    else:
        return None

    return "\n".join(lines)


# Escaping lives in scripts/lib/toml_escape.py because diagnose.py predicts
# what this script writes and compares the two; a second copy here is how those
# predictions silently drifted from the file.
_escape_ctrl = escape_ctrl
_qs = quote_string


if __name__ == "__main__":
    raise SystemExit(main())
PY
then
  CODEX_RC=0
else
  CODEX_RC=$?
fi

# Keep the same project MCP surface available to Antigravity. This also adds
# the cc-suite-managed claude-code server so agy can delegate back to Claude.
# When Antigravity is not enabled the tree is never created, and an existing
# projection is reconciled to an empty managed set — like the Codex sentinel
# block above, deselecting the tool must actually withdraw its MCP surface.
# Only servers recorded in the provenance file are withdrawn here; entries
# cc-suite did not write, and sibling top-level keys, stay. That holds for the
# withdrawal alone — re-enabling rebuilds the file from bridge_agy_mcp.py's
# projection, which currently keeps no top-level key other than mcpServers.
if tool_enabled antigravity; then
  if python3 "$SCRIPT_DIR/bridge_agy_mcp.py";
  then
    AGY_RC=0
  else
    AGY_RC=$?
  fi
elif [ -f .agents/.cc-suite-mcp.provenance.json ]; then
  if python3 - <<'PY'
from __future__ import annotations
import json, os, sys, tempfile
from pathlib import Path

SCHEMA = 1
TARGET = Path(".agents/mcp_config.json")
PROVENANCE = Path(".agents/.cc-suite-mcp.provenance.json")


def load(path: Path) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"! {path}: invalid JSON: {exc} — leaving the Antigravity config alone", file=sys.stderr)
        raise SystemExit(2)


def atomic_write_json(path: Path, payload: object) -> None:
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, indent=2) + "\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


meta = load(PROVENANCE)
if not isinstance(meta, dict) or meta.get("schema") != SCHEMA:
    print(f"! {PROVENANCE}: unsupported provenance schema — leaving the Antigravity config alone", file=sys.stderr)
    raise SystemExit(2)
managed = meta.get("managed_servers")
if not isinstance(managed, list) or not all(isinstance(n, str) for n in managed):
    print(f"! {PROVENANCE}: managed_servers is invalid — leaving the Antigravity config alone", file=sys.stderr)
    raise SystemExit(2)

if not TARGET.exists():
    PROVENANCE.unlink()
    print("· antigravity not enabled — cleared stale cc-suite MCP provenance")
    raise SystemExit(0)

# Nothing is recorded as ours, so there is nothing to withdraw and the target
# is never written. Check that BEFORE reading it: parsing first meant an
# unparseable file the run would not have touched still aborted with exit 2,
# failing /cc-suite:sync-mcp, /cc-suite:repair and /cc-suite:init on every
# subsequent run. Reads that a write depends on stay fail-loud below.
if not managed:
    print(f"· antigravity not enabled — no cc-suite servers recorded in {TARGET}")
    raise SystemExit(0)

data = load(TARGET)
if not isinstance(data, dict) or not isinstance(data.get("mcpServers", {}), dict):
    print(f"! {TARGET}: unexpected shape — leaving it alone", file=sys.stderr)
    raise SystemExit(2)

servers = data.get("mcpServers", {})
managed_names = set(managed)
withdrawn = [n for n in servers if n in managed_names]
remaining = {k: v for k, v in servers.items() if k not in managed_names}

# Recorded, but already gone from the target: an earlier run withdrew them, so
# both files stay untouched. Rewriting here would churn mtimes and print a
# success marker for work that did not happen.
if not withdrawn:
    print(f"· antigravity not enabled — no cc-suite servers left in {TARGET}")
    raise SystemExit(0)

if remaining:
    data["mcpServers"] = remaining
else:
    data.pop("mcpServers", None)

if not data:
    TARGET.unlink()
    PROVENANCE.unlink()
    print(f"✓ antigravity not enabled — removed cc-suite-generated {TARGET}")
    raise SystemExit(0)

# Target first, provenance second: a crash in between leaves provenance
# claiming names the target no longer has, which the next run treats as inert.
if withdrawn:
    atomic_write_json(TARGET, data)
    atomic_write_json(PROVENANCE, {"schema": SCHEMA, "managed_servers": [], "source": ".mcp.json"})
    print(f"✓ antigravity not enabled — withdrew cc-suite servers from {TARGET} ({len(remaining)} user server(s) kept)")
else:
    atomic_write_json(PROVENANCE, {"schema": SCHEMA, "managed_servers": [], "source": ".mcp.json"})
    print(f"· antigravity not enabled — recorded cc-suite servers are already gone from {TARGET}; cleared stale provenance")
raise SystemExit(0)
PY
  then
    AGY_RC=0
  else
    AGY_RC=$?
  fi
elif [ -f .agents/mcp_config.json ]; then
  echo "· antigravity not enabled — .agents/mcp_config.json has no cc-suite provenance, left alone"
  AGY_RC=0
else
  echo "· antigravity not enabled — skipping .agents/mcp_config.json projection"
  AGY_RC=0
fi

if [ "$CODEX_RC" -ne 0 ]; then
  exit "$CODEX_RC"
fi
exit "$AGY_RC"
