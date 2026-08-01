#!/usr/bin/env bash
# cc-suite: tear down the bridge artifacts. Safe: never deletes .claude/ or its contents.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

# Returns 0 if the named file contains only "@AGENTS.md" (bare import, no other content).
is_pure_import() {
  python3 -c '
import sys
from pathlib import Path
c = Path(sys.argv[1]).read_text().strip()
sys.exit(0 if c == "@AGENTS.md" else 1)
' "$1" 2>/dev/null
}

# Read provenance written by init.sh. cc-suite state moved from .codex/ into
# .cc-suite/ so a project that bridges no Codex gets no .codex/ directory; the
# legacy paths are still honoured for repos initialized before that move.
PROVENANCE=".cc-suite/provenance"
LEGACY_PROVENANCE=".codex/.cc-suite.provenance"
[ -f "$PROVENANCE" ] || PROVENANCE="$LEGACY_PROVENANCE"

ORIGINAL_CLAUDE=".cc-suite/original-claude.md"
LEGACY_ORIGINAL_CLAUDE=".codex/.cc-suite-original-claude.md"
[ -f "$ORIGINAL_CLAUDE" ] || ORIGINAL_CLAUDE="$LEGACY_ORIGINAL_CLAUDE"

CLAUDE_MIGRATED=0
CC_SUITE_CREATED_CLAUDE=0
CC_SUITE_CREATED_GEMINI=0
# Empty means "not recorded" (legacy install or pre-existing AGENTS.md) and
# falls back to the scaffold-content heuristic below; "1" means init wrote
# AGENTS.md itself.
CC_SUITE_CREATED_AGENTS=""
if [ -f "$PROVENANCE" ]; then
  # shellcheck disable=SC1090
  while IFS='=' read -r k v; do
    case "$k" in
      CLAUDE_MIGRATED)            CLAUDE_MIGRATED="$v" ;;
      CC_SUITE_CREATED_CLAUDE)   CC_SUITE_CREATED_CLAUDE="$v" ;;
      CC_SUITE_CREATED_GEMINI)   CC_SUITE_CREATED_GEMINI="$v" ;;
      CC_SUITE_CREATED_AGENTS)   CC_SUITE_CREATED_AGENTS="$v" ;;
    esac
  done < "$PROVENANCE"
fi

# AGENTS.md — restore content to CLAUDE.md first, then delete. A pre-existing
# AGENTS.md that init.sh left untouched must survive unbridge — it is user
# content that exists nowhere else.
KEEP_AGENTS=0
if [ -f AGENTS.md ]; then
  if [ "$CC_SUITE_CREATED_CLAUDE" = "1" ]; then
    # Recorded provenance beats content inspection: init.sh writes
    # CC_SUITE_CREATED_AGENTS=1 whenever it created AGENTS.md itself. The
    # scaffold-content heuristic below remains only for legacy installs whose
    # provenance predates that key.
    if [ "$CC_SUITE_CREATED_AGENTS" = "1" ]; then
      # init.sh created both files from scratch — nothing original to restore.
      skip "CLAUDE.md was created by cc-suite; will be removed (no content to restore)"
    elif [ -n "$CC_SUITE_CREATED_AGENTS" ]; then
      # Explicitly recorded as NOT created by init — user content.
      KEEP_AGENTS=1
      skip "AGENTS.md predates cc-suite (recorded provenance) — left alone"
    elif grep -qF 'Never modify `CLAUDE.md` directly' AGENTS.md; then
      # Legacy install (no CC_SUITE_CREATED_AGENTS record): fall back to the
      # scaffold marker init.sh wrote into a cc-suite-created AGENTS.md.
      skip "CLAUDE.md was created by cc-suite; will be removed (no content to restore)"
    else
      # No record and no cc-suite scaffold: AGENTS.md predated init.sh, which
      # only created the CLAUDE.md import. Deleting it would lose user content.
      KEEP_AGENTS=1
      skip "AGENTS.md predates cc-suite — left alone"
    fi
  elif [ "$CLAUDE_MIGRATED" = "1" ] && [ -f "$ORIGINAL_CLAUDE" ]; then
    # Restore the verbatim original CLAUDE.md, not the AGENTS.md scaffolding.
    cp "$ORIGINAL_CLAUDE" CLAUDE.md
    rm "$ORIGINAL_CLAUDE"
    ok "restored original CLAUDE.md content from cc-suite backup"
  elif [ -f CLAUDE.md ] && is_pure_import CLAUDE.md; then
    # No provenance and CLAUDE.md is a bare @import — fall back to copying
    # AGENTS.md verbatim. May include scaffolding, but better than data loss.
    cp AGENTS.md CLAUDE.md
    warn "no provenance found; restored CLAUDE.md from AGENTS.md verbatim (may include cc-suite scaffolding)"
  elif [ ! -f CLAUDE.md ]; then
    cp AGENTS.md CLAUDE.md
    warn "no provenance found; created CLAUDE.md from AGENTS.md"
  else
    # CLAUDE.md has its own content — back up AGENTS.md beside it.
    _backup="AGENTS.md.cc-suite-backup"
    _i=1
    while [ -f "$_backup" ]; do
      _backup="AGENTS.md.cc-suite-backup.$_i"
      _i=$((_i + 1))
    done
    cp AGENTS.md "$_backup"
    warn "CLAUDE.md has its own content; backed up AGENTS.md → $_backup"
  fi
  if [ "$KEEP_AGENTS" != "1" ]; then
    rm AGENTS.md
    ok "removed AGENTS.md"
  fi
else
  skip "AGENTS.md not present"
fi

# GEMINI.md — remove only a still-pure @import. A cc-suite-created file the
# user has since edited is their content now; deleting it would lose edits.
if [ -f GEMINI.md ]; then
  if is_pure_import GEMINI.md; then
    rm GEMINI.md
    ok "removed GEMINI.md (@AGENTS.md import)"
  elif [ "$CC_SUITE_CREATED_GEMINI" = "1" ]; then
    skip "GEMINI.md was cc-suite-created but has been edited — left alone"
  else
    skip "GEMINI.md has custom content — left alone"
  fi
else
  skip "GEMINI.md not present"
fi

# CLAUDE.md — if init.sh created it from scratch, remove it now (back to original state).
# Else if it's a dangling @import after AGENTS.md was removed, clean it up.
if [ -f CLAUDE.md ]; then
  if [ "$CC_SUITE_CREATED_CLAUDE" = "1" ] && is_pure_import CLAUDE.md; then
    rm CLAUDE.md
    ok "removed CLAUDE.md (cc-suite-created, no prior CLAUDE.md existed)"
  elif is_pure_import CLAUDE.md; then
    rm CLAUDE.md
    ok "removed CLAUDE.md (was dangling @AGENTS.md import)"
  fi
fi

# Provenance — remove after we've consumed it, from both the current and legacy
# locations so a repo that predates the move is left fully clean.
for _p in "$PROVENANCE" "$LEGACY_PROVENANCE" "$ORIGINAL_CLAUDE" "$LEGACY_ORIGINAL_CLAUDE"; do
  if [ -f "$_p" ]; then
    rm "$_p"
  fi
done
# Drop .cc-suite/ only when nothing else lives there — declared advisor agents
# under .cc-suite/agents/ are the user's, and outlive the bridge.
if [ -d .cc-suite ]; then
  rmdir .cc-suite 2>/dev/null || true
fi

# .agents/mcp_config.json — remove only the cc-suite-managed entries. A user
# config, user entries in a generated file, and sibling top-level keys are
# all preserved; the file is deleted only when nothing at all remains.
UNBRIDGE_FAILED=0
if [ -f .agents/.cc-suite-mcp.provenance.json ]; then
  if python3 - <<'PY'; then
import json, sys
from pathlib import Path

target = Path('.agents/mcp_config.json')
provenance = Path('.agents/.cc-suite-mcp.provenance.json')
try:
    meta = json.loads(provenance.read_text())
    managed = set(meta.get('managed_servers', []))
    if target.exists():
        data = json.loads(target.read_text())
        if not isinstance(data, dict) or not isinstance(data.get('mcpServers', {}), dict):
            # SystemExit(1) is a BaseException — it bypasses the broad handler
            # below, so the shell wrapper records the failure and unbridge does
            # not announce completion over an uncleaned config.
            print('! .agents/mcp_config.json has an unexpected shape — left alone (provenance kept)', file=sys.stderr)
            raise SystemExit(1)
        servers = data.get('mcpServers', {})
        remaining = {k: v for k, v in servers.items() if k not in managed}
        if remaining:
            data['mcpServers'] = remaining
        else:
            data.pop('mcpServers', None)
        if data:
            target.write_text(json.dumps(data, indent=2) + '\n')
            print('✓ .agents/mcp_config.json: removed cc-suite-managed servers')
        else:
            target.unlink()
            print('✓ removed .agents/mcp_config.json (cc-suite generated)')
    provenance.unlink()
    print('✓ removed .agents/.cc-suite-mcp.provenance.json')
except Exception as exc:
    print(f'! could not safely remove Antigravity MCP bridge: {exc}', file=sys.stderr)
    raise SystemExit(1)
PY
    :
  else
    warn "Antigravity MCP cleanup failed — .agents/ bridge artifacts left in place"
    UNBRIDGE_FAILED=1
  fi
elif [ -f .agents/mcp_config.json ]; then
  skip ".agents/mcp_config.json has no cc-suite provenance — left alone"
fi

# Registry-bridged tools (grok / opencode / qwen / kimi) — remove cc-suite MCP
# blocks/entries from each tool's config, preserving user-managed servers and
# sibling keys. The engine owns the per-tool paths and provenance.
python3 "${SCRIPT_DIR}/bridge_tools.py" --unbridge || warn "tool-profile unbridge reported an issue"

# .agents/skills symlink only — never the .claude/skills/ target.
if [ -L .agents/skills ]; then
  rm .agents/skills
  ok "removed .agents/skills symlink"
  rmdir .agents 2>/dev/null && ok "removed empty .agents/" || true
else
  skip ".agents/skills not a symlink"
fi

# .codex/prompts — only if empty of real content.
if [ -d .codex/prompts ] && [ -z "$(ls -A .codex/prompts 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
  rm -rf .codex/prompts && ok "removed empty .codex/prompts/"
else
  skip ".codex/prompts/ non-empty or missing"
fi

# .codex/hooks.json — only if it appears cc-suite-generated (contains only bridge events).
if [ -f .codex/hooks.json ]; then
  if python3 - <<'PY' 2>/dev/null; then
import json, sys
from pathlib import Path
BRIDGE_EVENTS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}
try:
    data = json.loads(Path(".codex/hooks.json").read_text())
    events = set(data.get("hooks", {}).keys())
    has_marker = "_cc_bridge_version" in data
    sys.exit(0 if (has_marker and events <= BRIDGE_EVENTS) else 1)
except Exception:
    sys.exit(1)
PY
    rm .codex/hooks.json && ok "removed .codex/hooks.json (cc-suite generated)"
  else
    skip ".codex/hooks.json has non-bridge events or is non-standard — left alone"
  fi
fi
[ -f .codex/hooks.cc-suite.json ] && { rm .codex/hooks.cc-suite.json && ok "removed .codex/hooks.cc-suite.json"; } || true

# .codex/config.toml — strip the cc-suite sentinel blocks; delete the whole
# file only when init.sh created it AND the non-sentinel remainder still
# matches the init template exactly (i.e. it has not been hand-edited since).
if [ -f .codex/config.toml ]; then
  python3 - <<'PY'
from pathlib import Path
# Both cc-suite-owned sentinel blocks: MCP mirror (bridge_mcp.sh) and the
# claude-octopus registration (mcp_claude.sh).
BLOCKS = [
    ("# >>> cc-suite-mcp >>>", "# <<< cc-suite-mcp <<<"),
    ("# >>> cc-suite-claude-mcp >>>", "# <<< cc-suite-claude-mcp <<<"),
]
INIT_MARKER = "# cc-suite: generated-by-init"
# Must match the CFG heredoc in init.sh verbatim.
INIT_TEMPLATE = """\
# cc-suite: generated-by-init  (this comment is consumed by unbridge)
# Codex CLI configuration for this project.
# See: https://developers.openai.com/codex/config-reference

# Uncomment to also read CLAUDE.md as a fallback instruction source:
# project_doc_fallback_filenames = ["CLAUDE.md"]

# MCP servers mirrored from .mcp.json are added below by /cc-suite:bridge-mcp.
"""
p = Path(".codex/config.toml")
text = p.read_text(encoding="utf-8")
cleaned = text
removed_any = False
for s_marker, e_marker in BLOCKS:
    start = cleaned.find(s_marker)
    end   = cleaned.find(e_marker)
    if start != -1 and end != -1 and end > start:
        nl = cleaned.find("\n", end)
        cleaned = cleaned[:start].rstrip("\n") + ("\n" + cleaned[nl + 1:] if nl != -1 else "")
        removed_any = True
if cleaned.strip() == INIT_TEMPLATE.strip():
    # Unedited init output (the exact-template match implies the init marker):
    # safe to delete outright.
    p.unlink()
    print("✓ removed .codex/config.toml (cc-suite-generated, unedited)")
elif removed_any:
    if cleaned.strip():
        p.write_text(cleaned + "\n", encoding="utf-8")
        print("✓ .codex/config.toml: removed cc-suite sentinel block(s)")
    else:
        p.unlink()
        print("✓ removed .codex/config.toml (only contained cc-suite blocks)")
elif INIT_MARKER in cleaned:
    print("· .codex/config.toml was created by init but has been edited — left alone")
else:
    print("· .codex/config.toml has no cc-suite markers — left alone")
PY
fi

# .gemini empties
for d in .gemini/skills .gemini/commands; do
  if [ -d "$d" ] && [ -z "$(ls -A "$d" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
    rm -rf "$d" && ok "removed empty $d"
  fi
done
[ -d .gemini ] && rmdir .gemini 2>/dev/null && ok "removed empty .gemini/" || true

# .gitignore sentinel block
if [ -f .gitignore ] && grep -qF "# >>> cc-suite >>>" .gitignore; then
  python3 - <<'PY'
from pathlib import Path
text = Path(".gitignore").read_text()
start = text.find("# >>> cc-suite >>>")
end   = text.find("# <<< cc-suite <<<")
if start != -1 and end != -1:
    nl = text.find("\n", end)
    end_line = nl + 1 if nl != -1 else len(text)
    new = text[:start].rstrip() + "\n" + text[end_line:]
    Path(".gitignore").write_text(new.lstrip("\n"))
    print("✓ removed cc-suite block from .gitignore")
PY
fi

echo
if [ "$UNBRIDGE_FAILED" = "1" ]; then
  warn "cc-suite unbridge finished with errors — see messages above."
  exit 1
fi
ok "cc-suite unbridge complete. .mcp.json and .claude/ are left alone."
