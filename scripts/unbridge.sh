#!/usr/bin/env bash
# cc-bridge: tear down the bridge artifacts. Safe: never deletes .claude/ or its contents.

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

# AGENTS.md — restore content to CLAUDE.md first, then delete.
if [ -f AGENTS.md ]; then
  if [ -f CLAUDE.md ] && is_pure_import CLAUDE.md; then
    # CLAUDE.md is a bare @import — restore AGENTS.md content into it.
    cp AGENTS.md CLAUDE.md
    ok "restored CLAUDE.md content from AGENTS.md"
  elif [ ! -f CLAUDE.md ]; then
    # No CLAUDE.md at all — move content there so nothing is lost.
    cp AGENTS.md CLAUDE.md
    ok "created CLAUDE.md from AGENTS.md (no prior CLAUDE.md)"
  else
    # CLAUDE.md has its own content — back up AGENTS.md beside it.
    _backup="AGENTS.md.cc-bridge-backup"
    _i=1
    while [ -f "$_backup" ]; do
      _backup="AGENTS.md.cc-bridge-backup.$_i"
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

# GEMINI.md — only remove a cc-bridge-generated bare @AGENTS.md import (no other content).
if [ -f GEMINI.md ]; then
  if is_pure_import GEMINI.md; then
    rm GEMINI.md
    ok "removed GEMINI.md (@AGENTS.md import)"
  else
    skip "GEMINI.md has custom content — left alone"
  fi
else
  skip "GEMINI.md not present"
fi

# CLAUDE.md — if it's now a dangling @import after AGENTS.md was removed, clean it up.
if [ -f CLAUDE.md ] && is_pure_import CLAUDE.md; then
  rm CLAUDE.md
  ok "removed CLAUDE.md (was dangling @AGENTS.md import)"
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

# .codex/hooks.json — only if it appears cc-bridge-generated (contains only bridge events).
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
    rm .codex/hooks.json && ok "removed .codex/hooks.json (cc-bridge generated)"
  else
    skip ".codex/hooks.json has non-bridge events or is non-standard — left alone"
  fi
fi
[ -f .codex/hooks.cc-bridge.json ] && { rm .codex/hooks.cc-bridge.json && ok "removed .codex/hooks.cc-bridge.json"; } || true

# .codex/config.toml — only remove the cc-bridge-mcp sentinel block; leave other config intact.
if [ -f .codex/config.toml ]; then
  python3 - <<'PY'
from pathlib import Path
SENTINEL_START = "# >>> cc-bridge-mcp >>>"
SENTINEL_END   = "# <<< cc-bridge-mcp <<<"
p = Path(".codex/config.toml")
text = p.read_text(encoding="utf-8")
start = text.find(SENTINEL_START)
end   = text.find(SENTINEL_END)
if start != -1 and end != -1:
    tail = text.find("\n", end)
    cleaned = text[:start].rstrip("\n") + ("\n" + text[tail + 1:] if tail != -1 else "")
    cleaned = cleaned.strip()
    if cleaned:
        p.write_text(cleaned + "\n", encoding="utf-8")
        print("✓ .codex/config.toml: removed cc-bridge-mcp sentinel block")
    else:
        p.unlink()
        print("✓ removed .codex/config.toml (was cc-bridge generated)")
else:
    print("· .codex/config.toml has no cc-bridge-mcp block — left alone")
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
if [ -f .gitignore ] && grep -qF "# >>> cc-bridge >>>" .gitignore; then
  python3 - <<'PY'
from pathlib import Path
text = Path(".gitignore").read_text()
start = text.find("# >>> cc-bridge >>>")
end   = text.find("# <<< cc-bridge <<<")
if start != -1 and end != -1:
    end_line = text.find("\n", end) + 1
    new = text[:start].rstrip() + "\n" + text[end_line:]
    Path(".gitignore").write_text(new.lstrip("\n"))
    print("✓ removed cc-bridge block from .gitignore")
PY
fi

echo
ok "cc-bridge unbridge complete. .mcp.json and .claude/ are left alone."
