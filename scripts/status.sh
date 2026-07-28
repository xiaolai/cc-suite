#!/usr/bin/env bash
# cc-suite: print a status report of bridge artifacts and Codex runtime state.

set -u

mark() {
  # $1: label  $2: state (ok|miss|warn)  $3: detail
  case "$2" in
    ok)   printf '  ✓ %-32s %s\n' "$1" "$3" ;;
    miss) printf '  · %-32s %s\n' "$1" "${3:-(missing)}" ;;
    warn) printf '  ! %-32s %s\n' "$1" "$3" ;;
  esac
}

echo "cc-suite status — $(pwd)"

# ── bridge artifacts ──────────────────────────────────────────────────────────
echo
echo "  Bridge artifacts"

# AGENTS.md — also check size against Codex 32 KiB truncation limit
if [ -f AGENTS.md ]; then
  _size=$(wc -c < AGENTS.md | tr -d ' ')
  _lines=$(wc -l < AGENTS.md | tr -d ' ')
  if [ "$_size" -gt 32768 ]; then
    mark "AGENTS.md" warn "${_lines} lines, ${_size} bytes — exceeds Codex 32 KiB limit (silent truncation)"
  else
    mark "AGENTS.md" ok "${_lines} lines, ${_size} bytes"
  fi
else
  mark "AGENTS.md" miss
fi

# CLAUDE.md
if [ -f CLAUDE.md ]; then
  if grep -qE '^@AGENTS\.md\s*$' CLAUDE.md; then
    mark "CLAUDE.md" ok "@AGENTS.md import"
  else
    mark "CLAUDE.md" warn "substantive content (not @import) — consider /cc-suite:init"
  fi
else
  mark "CLAUDE.md" miss
fi

# GEMINI.md — legacy compatibility only. Consumer Gemini CLI access moved to
# Antigravity on 2026-06-18; enterprise/API users may still need this file.
# cc-suite no longer creates it, but never deletes custom content automatically.
if [ -f GEMINI.md ]; then
  if grep -qE '^@AGENTS\.md\s*$' GEMINI.md && [ "$(tr -d '[:space:]' < GEMINI.md)" = "@AGENTS.md" ]; then
    mark "GEMINI.md" warn "legacy @AGENTS.md import — remove with /cc-suite:unbridge"
  else
    mark "GEMINI.md" warn "legacy/custom Google instructions — review or migrate manually"
  fi
fi

# .agents/skills symlink
if [ -L .agents/skills ]; then
  _target="$(readlink .agents/skills)"
  if [ "$_target" = "../.claude/skills" ]; then
    if [ -d .agents/skills ]; then
      _count="$(find -L .agents/skills/ -maxdepth 2 -mindepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')"
      mark ".agents/skills" ok "→ ../.claude/skills (${_count} skills)"
    else
      mark ".agents/skills" warn "→ ../.claude/skills (TARGET MISSING — broken symlink)"
    fi
  else
    mark ".agents/skills" warn "→ ${_target} (unexpected target)"
  fi
elif [ -d .agents/skills ]; then
  mark ".agents/skills" warn "real directory (not symlink)"
else
  mark ".agents/skills" miss "→ run /cc-suite:bridge-skills"
fi

# .claude/skills/cc-suite symlink (plugin skills exposed to Codex)
if [ -L .claude/skills/cc-suite ]; then
  if [ -d .claude/skills/cc-suite ]; then
    _skill_count="$(find .claude/skills/cc-suite/ -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    mark ".claude/skills/cc-suite" ok "→ plugin skills (${_skill_count} skills visible to Codex)"
  else
    mark ".claude/skills/cc-suite" warn "symlink broken — run /cc-suite:bridge-skills"
  fi
elif [ -d .claude/skills/cc-suite ]; then
  mark ".claude/skills/cc-suite" warn "real directory (not symlink) — Codex may see stale skills"
else
  mark ".claude/skills/cc-suite" miss "plugin skills not exposed — run /cc-suite:bridge-skills"
fi

# .codex
[ -d .codex/prompts ]    && mark ".codex/prompts/"    ok "" || mark ".codex/prompts/"    miss
[ -f .codex/hooks.json ] && mark ".codex/hooks.json"  ok "$(wc -c < .codex/hooks.json | tr -d ' ') bytes" \
                         || mark ".codex/hooks.json"  miss "(run /cc-suite:bridge-hooks)"
[ -f .codex/config.toml ] && mark ".codex/config.toml" ok "" \
                           || mark ".codex/config.toml" miss "(run /cc-suite:init)"

# .gemini — legacy project config. Agy uses .agents/ for workspace assets.
[ -d .gemini ] && mark ".gemini/" warn "legacy Google project dir — migrate skills/config to .agents/"

# Antigravity workspace MCP configuration.
if [ -f .agents/mcp_config.json ]; then
  if [ -f .agents/.cc-suite-mcp.provenance.json ]; then
    _agy_mcp_count=$(python3 -c '
import json
try:
    print(len(json.load(open(".agents/mcp_config.json")).get("mcpServers", {})))
except Exception:
    print(0)
' 2>/dev/null || echo 0)
    mark ".agents/mcp_config.json → agy" ok "${_agy_mcp_count} workspace server(s), cc-suite-managed"
  else
    mark ".agents/mcp_config.json → agy" warn "user-managed config — cc-suite will not overwrite it"
  fi
else
  mark ".agents/mcp_config.json → agy" miss "run /cc-suite:bridge-mcp"
fi

# Fast local check only; /cc-suite:agy-preflight performs the live model/auth
# probe with a deadline.
if command -v agy >/dev/null 2>&1; then
  _agy_version=$(agy --version 2>/dev/null | head -1 | tr -d '\r')
  mark "agy CLI" ok "${_agy_version:-version unknown}"
else
  mark "agy CLI" warn "not found — install: curl -fsSL https://antigravity.google/cli/install.sh | bash"
fi

# .mcp.json — distinguish canonical, stale (legacy npm), missing, or invalid
if [ -f .mcp.json ]; then
  _codex_cli_rc=0
  python3 - <<'PY' 2>/dev/null || _codex_cli_rc=$?
import json, sys
from pathlib import Path

CANONICAL = {"type": "stdio", "command": "codex", "args": ["mcp-server"]}
try:
    d = json.loads(Path(".mcp.json").read_text())
except Exception:
    sys.exit(3)
s = d.get("mcpServers") if isinstance(d, dict) else None
if not isinstance(s, dict) or "codex-cli" not in s:
    sys.exit(2)
sys.exit(0 if s["codex-cli"] == CANONICAL else 1)
PY
  case "$_codex_cli_rc" in
    0) mark ".mcp.json → Claude" ok   "codex-cli registered (codex mcp-server)" ;;
    1) mark ".mcp.json → Claude" warn "codex-cli stale (legacy npm registration) — run /cc-suite:repair" ;;
    2) mark ".mcp.json → Claude" miss "codex-cli not registered (run /cc-suite:init step 8)" ;;
    *) mark ".mcp.json → Claude" warn ".mcp.json unreadable" ;;
  esac
else
  mark ".mcp.json" miss
fi

# .codex/config.toml — claude-code (claude-octopus) registration
_pin_file="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/lib/claude-octopus-pin.txt"
_expected_pin="$(tr -d '[:space:]' < "$_pin_file" 2>/dev/null || echo unknown)"
if [ -f .codex/config.toml ]; then
  if grep -qF ">>> cc-suite-claude-mcp >>>" .codex/config.toml; then
    # Scope the pin comparison to the cc-suite-claude-mcp sentinel block:
    # advisor-agent blocks also reference claude-octopus@<pin> and a whole-file
    # grep would let a current-pin advisor mask a stale claude-code block.
    _claude_block="$(sed -n '/>>> cc-suite-claude-mcp >>>/,/<<< cc-suite-claude-mcp <<</p' .codex/config.toml)"
    if printf '%s' "$_claude_block" | grep -qF "claude-octopus@${_expected_pin}"; then
      mark ".codex/config.toml → Codex" ok   "claude-code pinned @${_expected_pin}"
    else
      _live_pin=$(printf '%s' "$_claude_block" | grep -oE 'claude-octopus@[0-9][^"]*' | head -1)
      mark ".codex/config.toml → Codex" warn "claude-code pinned @${_live_pin:-?} but plugin expects @${_expected_pin} — run /cc-suite:update"
    fi
  elif grep -qE '^[[:space:]]*\[mcp_servers\.(claude-code|"claude-code")\][[:space:]]*$' .codex/config.toml; then
    mark ".codex/config.toml → Codex" warn "claude-code registered by another source (not cc-suite-managed)"
  else
    mark ".codex/config.toml → Codex" miss "claude-code not registered (run /cc-suite:init step 9)"
  fi
else
  mark ".codex/config.toml → Codex" miss "(run /cc-suite:init)"
fi

# .cc-suite/agents — declared advisor agents
if [ -d .cc-suite/agents ] && ls .cc-suite/agents/*.md >/dev/null 2>&1; then
  _declared_count=$(find .cc-suite/agents -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
  _registered_count=0
  if [ -f .mcp.json ]; then
    _registered_count=$(python3 -c "
import json
try:
    d = json.loads(open('.mcp.json').read())
    s = d.get('mcpServers', {})
    n = sum(1 for v in s.values() if isinstance(v, dict) and v.get('_cc_suite_agent'))
    print(n)
except Exception:
    print(0)
" 2>/dev/null || echo 0)
  fi
  if [ "$_declared_count" = "$_registered_count" ]; then
    mark ".cc-suite/agents/" ok "${_declared_count} advisor(s) declared and registered"
  else
    mark ".cc-suite/agents/" warn "${_declared_count} declared, ${_registered_count} registered — run /cc-suite:repair"
  fi
else
  mark ".cc-suite/agents/" miss "(no advisor agents declared — add one with /cc-suite:add-agent)"
fi

# .gitignore sentinel
if [ -f .gitignore ] && grep -qF "# >>> cc-suite >>>" .gitignore; then
  mark ".gitignore" ok "has cc-suite block"
else
  mark ".gitignore" miss "no cc-suite block"
fi

# ── MCP parity (project servers visible to Codex) ────────────────────────────
echo
echo "  MCP parity (.mcp.json → .codex/config.toml)"

if [ ! -f .mcp.json ]; then
  printf '  · no .mcp.json\n'
elif [ ! -f .codex/config.toml ]; then
  mark "MCP mirror" warn ".codex/config.toml missing — Codex cannot see any project MCP servers"
else
  python3 - <<'PY'
import json, re, sys
from pathlib import Path
try:
    mcp = json.loads(Path(".mcp.json").read_text())
except (json.JSONDecodeError, OSError) as e:
    print(f"  ! .mcp.json unreadable: {e}")
    raise SystemExit(1)
if not isinstance(mcp, dict):
    print(f"  ! .mcp.json top level is not an object")
    raise SystemExit(1)
_servers_obj = mcp.get("mcpServers")
if not isinstance(_servers_obj, dict):
    if _servers_obj is None:
        print("  · no mcpServers in .mcp.json")
        raise SystemExit(0)
    print(f"  ! .mcp.json mcpServers must be an object")
    raise SystemExit(1)
servers = [k for k in _servers_obj if k != "codex-cli"]
if not servers:
    print("  · no additional servers in .mcp.json to check")
    raise SystemExit(0)
config = Path(".codex/config.toml").read_text()
def _codex_name(name: str) -> str:
    # Mirror bridge_mcp.sh's Codex-safe name normalization.
    if re.fullmatch(r'[a-zA-Z0-9_-]+', name):
        return name
    normalized = re.sub(r'[^a-zA-Z0-9_-]+', '-', name).strip('-_')
    return normalized or 'mcp-server'

# Track the original Claude name recorded by bridge_mcp.sh. This prevents a
# normalization collision (e.g. `a.b` and `a-b`) from making both source names
# appear healthy just because they share one Codex table.
tables = {}
current = None
for line in config.splitlines():
    match = re.match(r'^\[mcp_servers\.([a-zA-Z0-9_-]+)\]$', line.strip())
    if match:
        current = match.group(1)
        tables.setdefault(current, None)
        continue
    if current is not None:
        comment = re.match(r'^# Claude MCP name: (.*)$', line)
        if comment:
            tables[current] = comment.group(1)

def _comment_name(name: str) -> str:
    return name.replace('\\', '\\\\').replace('\r', '\\r').replace('\n', '\\n')

def _is_mirrored(name: str) -> bool:
    codex_name = _codex_name(name)
    if codex_name not in tables:
        return False
    owner = tables[codex_name]
    if owner is None:
        return codex_name == name
    return owner == _comment_name(name)

mirrored = [f"{s} → {_codex_name(s)}" if _codex_name(s) != s else s
            for s in servers if _is_mirrored(s)]
missing  = [s for s in servers if not _is_mirrored(s)]
if mirrored:
    print(f"  ✓ mirrored to .codex/config.toml   {mirrored}")
if missing:
    print(f"  ! NOT mirrored to Codex config     {missing}")
    print(f"    → run /cc-suite:sync-mcp to sync")
PY
fi

# ── Codex runtime state ───────────────────────────────────────────────────────
echo
echo "  Codex runtime"

CODEX_CFG="${HOME}/.codex/config.toml"
REPO_ABS="$(pwd)"

if [ ! -f "$CODEX_CFG" ]; then
  mark "~/.codex/config.toml" miss "Codex user config not found — is Codex CLI installed?"
else
  # Project trust — hooks, rules, and project config.toml are inert until trusted.
  _trust=$(python3 -c '
import sys, re, pathlib
config = pathlib.Path(sys.argv[1]).read_text()
repo   = sys.argv[2]
# Match the section header that contains the exact repo path as a quoted TOML key.
in_section = False
for line in config.splitlines():
    s = line.strip()
    if s.startswith("["):
        in_section = bool(re.match(
            r"^\[projects\s*\.\s*[\"'"'"']" + re.escape(repo) + r"[\"'"'"']\s*\]$",
            s
        ))
    elif in_section and re.match(r"trust_level\s*=\s*[\"'"'"']trusted[\"'"'"']", s):
        print("trusted")
        raise SystemExit(0)
print("untrusted")
' "$CODEX_CFG" "$REPO_ABS" 2>/dev/null)
  if [ "${_trust:-untrusted}" = "trusted" ]; then
    mark "project trust" ok "trusted — hooks, rules, and .codex/config.toml are active"
  else
    mark "project trust" warn "NOT trusted — hooks, rules, and .codex/config.toml are inert"
    printf '    → run Codex once and accept the trust prompt, or add:\n'
    printf '      [projects."%s"]\n      trust_level = "trusted"\n' "$REPO_ABS"
    printf '      to ~/.codex/config.toml\n'
  fi

  # plugin_hooks feature flag — required for plugin-bundled hooks to fire.
  # Must be under [features] section, not just anywhere in the file.
  _plugin_hooks=$(python3 -c '
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
in_features = False
for line in text.splitlines():
    s = line.strip()
    if s.startswith("["):
        in_features = s == "[features]"
    elif in_features and s.startswith("plugin_hooks"):
        import re
        if re.match(r"plugin_hooks\s*=\s*true", s):
            print("enabled")
            sys.exit(0)
print("disabled")
' "$CODEX_CFG" 2>/dev/null)
  if [ "${_plugin_hooks:-disabled}" = "enabled" ]; then
    mark "plugin_hooks" ok "enabled in ~/.codex/config.toml"
  else
    mark "plugin_hooks" warn "not set — plugin-bundled hooks are inert"
    printf '    → add to ~/.codex/config.toml:\n'
    printf '      [features]\n      plugin_hooks = true\n'
  fi
fi
