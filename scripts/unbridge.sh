#!/usr/bin/env bash
# cc-suite: tear down the bridge artifacts. Safe: never deletes .claude/ or its contents.

set -euo pipefail

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

# Read provenance written by init.sh.
PROVENANCE=".codex/.cc-suite.provenance"
CLAUDE_MIGRATED=0
CC_SUITE_CREATED_CLAUDE=0
CC_SUITE_CREATED_GEMINI=0
CC_SUITE_CREATED_CODEX_CONFIG=0
if [ -f "$PROVENANCE" ]; then
  # shellcheck disable=SC1090
  while IFS='=' read -r k v; do
    case "$k" in
      CLAUDE_MIGRATED)            CLAUDE_MIGRATED="$v" ;;
      CC_SUITE_CREATED_CLAUDE)   CC_SUITE_CREATED_CLAUDE="$v" ;;
      CC_SUITE_CREATED_GEMINI)   CC_SUITE_CREATED_GEMINI="$v" ;;
      CC_SUITE_CREATED_CODEX_CONFIG) CC_SUITE_CREATED_CODEX_CONFIG="$v" ;;
    esac
  done < "$PROVENANCE"
fi

# AGENTS.md — restore content to CLAUDE.md first, then delete.
if [ -f AGENTS.md ]; then
  if [ "$CC_SUITE_CREATED_CLAUDE" = "1" ]; then
    # init.sh created CLAUDE.md from scratch — there is nothing original to restore.
    skip "CLAUDE.md was created by cc-suite; will be removed (no content to restore)"
  elif [ "$CLAUDE_MIGRATED" = "1" ] && [ -f .codex/.cc-suite-original-claude.md ]; then
    # Restore the verbatim original CLAUDE.md, not the AGENTS.md scaffolding.
    cp .codex/.cc-suite-original-claude.md CLAUDE.md
    rm .codex/.cc-suite-original-claude.md
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
  rm AGENTS.md
  ok "removed AGENTS.md"
else
  skip "AGENTS.md not present"
fi

# GEMINI.md — remove if it was cc-suite-created or is a bare @import.
if [ -f GEMINI.md ]; then
  if [ "$CC_SUITE_CREATED_GEMINI" = "1" ] || is_pure_import GEMINI.md; then
    rm GEMINI.md
    ok "removed GEMINI.md (cc-suite created or @AGENTS.md import)"
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

# Provenance file — remove after we've consumed it.
[ -f "$PROVENANCE" ] && rm "$PROVENANCE" || true

# .agents/mcp_config.json — remove only the cc-suite-managed entries. A user
# config or user entries in a generated file are preserved.
if [ -f .agents/.cc-suite-mcp.provenance.json ]; then
  python3 - <<'PY'
import json
from pathlib import Path

target = Path('.agents/mcp_config.json')
provenance = Path('.agents/.cc-suite-mcp.provenance.json')
try:
    meta = json.loads(provenance.read_text())
    managed = set(meta.get('managed_servers', []))
    data = json.loads(target.read_text()) if target.exists() else {}
    servers = data.get('mcpServers', {}) if isinstance(data, dict) else {}
    if isinstance(servers, dict):
        remaining = {k: v for k, v in servers.items() if k not in managed}
        if remaining:
            target.write_text(json.dumps({'mcpServers': remaining}, indent=2) + '\n')
            print('✓ .agents/mcp_config.json: removed cc-suite-managed servers')
        elif target.exists():
            target.unlink()
            print('✓ removed .agents/mcp_config.json (cc-suite generated)')
    provenance.unlink()
    print('✓ removed .agents/.cc-suite-mcp.provenance.json')
except Exception as exc:
    print(f'! could not safely remove Antigravity MCP bridge: {exc}')
PY
elif [ -f .agents/mcp_config.json ]; then
  skip ".agents/mcp_config.json has no cc-suite provenance — left alone"
fi

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

# .codex/config.toml — strip the sentinel block; if init.sh created the
# config file in the first place AND it has not been hand-edited since,
# remove the whole file.
if [ -f .codex/config.toml ]; then
  CCBR_CFG_PROV="$CC_SUITE_CREATED_CODEX_CONFIG" python3 - <<'PY'
import os
from pathlib import Path
SENTINEL_START = "# >>> cc-suite-mcp >>>"
SENTINEL_END   = "# <<< cc-suite-mcp <<<"
INIT_MARKER    = "# cc-suite: generated-by-init"
p = Path(".codex/config.toml")
text = p.read_text(encoding="utf-8")
start = text.find(SENTINEL_START)
end   = text.find(SENTINEL_END)
if start != -1 and end != -1:
    nl = text.find("\n", end)
    cleaned = text[:start].rstrip("\n") + ("\n" + text[nl + 1:] if nl != -1 else "")
else:
    cleaned = text
cleaned_strip = cleaned.strip()
# If the file was created by init.sh and the only content left is the marker
# comment + the init template, delete the file. Provenance-aware via env.
created_by_init = os.environ.get("CCBR_CFG_PROV") == "1" or INIT_MARKER in cleaned
if created_by_init and INIT_MARKER in cleaned:
    p.unlink()
    print("✓ removed .codex/config.toml (cc-suite-generated)")
elif start != -1 and end != -1:
    if cleaned_strip:
        p.write_text(cleaned + "\n", encoding="utf-8")
        print("✓ .codex/config.toml: removed cc-suite-mcp sentinel block")
    else:
        p.unlink()
        print("✓ removed .codex/config.toml (only contained sentinel block)")
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
ok "cc-suite unbridge complete. .mcp.json and .claude/ are left alone."
