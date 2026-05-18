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

# GEMINI.md
if [ -f GEMINI.md ]; then
  if grep -qE '^@AGENTS\.md\s*$' GEMINI.md; then
    mark "GEMINI.md" ok "@AGENTS.md import"
  else
    mark "GEMINI.md" warn "substantive content (not @import)"
  fi
else
  mark "GEMINI.md" miss
fi

# .agents/skills symlink
if [ -L .agents/skills ]; then
  _target="$(readlink .agents/skills)"
  if [ "$_target" = "../.claude/skills" ]; then
    if [ -d .agents/skills ]; then
      _count="$(find .agents/skills/ -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
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

# .gemini
[ -d .gemini/skills ]   && mark ".gemini/skills/"   ok "" || mark ".gemini/skills/"   miss
[ -d .gemini/commands ] && mark ".gemini/commands/" ok "" || mark ".gemini/commands/" miss

# .mcp.json — show codex-cli registration separately from other servers
if [ -f .mcp.json ]; then
  if python3 -c '
import json, sys
from pathlib import Path
try:
    d = json.loads(Path(".mcp.json").read_text())
except Exception:
    sys.exit(1)
s = d.get("mcpServers") if isinstance(d, dict) else None
sys.exit(0 if isinstance(s, dict) and "codex-cli" in s else 1)
' 2>/dev/null; then
    mark ".mcp.json → Claude" ok "codex-cli registered (Claude can invoke Codex as tool)"
  else
    mark ".mcp.json → Claude" miss "codex-cli not registered (run /cc-suite:init step 7)"
  fi
else
  mark ".mcp.json" miss
fi

# .codex/config.toml — claude-code (claude-octopus) registration
if [ -f .codex/config.toml ]; then
  if grep -qF ">>> cc-suite-claude-mcp >>>" .codex/config.toml; then
    mark ".codex/config.toml → Codex" ok "claude-code registered (Codex can invoke Claude as tool)"
  else
    mark ".codex/config.toml → Codex" miss "claude-code not registered (run /cc-suite:init step 8)"
  fi
else
  mark ".codex/config.toml → Codex" miss "(run /cc-suite:init)"
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
def _toml_key(name: str) -> str:
    # Mirror bridge_mcp.sh's key-escaping policy.
    if re.match(r'^[a-zA-Z0-9_-]+$', name):
        return name
    return '"' + name.replace('\\', '\\\\').replace('"', '\\"') + '"'
mirrored = [s for s in servers if f"[mcp_servers.{_toml_key(s)}]" in config]
missing  = [s for s in servers if s not in mirrored]
if mirrored:
    print(f"  ✓ mirrored to .codex/config.toml   {mirrored}")
if missing:
    print(f"  ! NOT mirrored to Codex config     {missing}")
    print(f"    → run /cc-suite:bridge-mcp to sync")
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
