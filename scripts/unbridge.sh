#!/usr/bin/env bash
# cc-bridge: tear down the bridge artifacts. Safe: never deletes .claude/ or its contents.

set -euo pipefail

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }

# AGENTS.md — restore CLAUDE.md from it first if CLAUDE.md is a pure @import,
# so content is never lost when the only copy lived in AGENTS.md.
if [ -f AGENTS.md ]; then
  if [ -f CLAUDE.md ] && grep -qE '^@AGENTS\.md\s*$' CLAUDE.md; then
    cp AGENTS.md CLAUDE.md
    ok "restored CLAUDE.md content from AGENTS.md"
  elif [ ! -f CLAUDE.md ]; then
    cp AGENTS.md CLAUDE.md
    ok "created CLAUDE.md from AGENTS.md (no prior CLAUDE.md)"
  fi
  rm AGENTS.md
  ok "removed AGENTS.md"
else
  skip "AGENTS.md not present"
fi

# GEMINI.md — remove if present
[ -f GEMINI.md ] && { rm GEMINI.md && ok "removed GEMINI.md"; } || skip "GEMINI.md not present"

# CLAUDE.md — now that AGENTS.md is gone, if CLAUDE.md is still a bare @import
# (e.g. the restore above overwrote it with AGENTS.md content that itself was "@AGENTS.md"),
# clear it to avoid a dangling reference. Otherwise leave it alone.
if [ -f CLAUDE.md ] && grep -qE '^@AGENTS\.md\s*$' CLAUDE.md; then
  rm CLAUDE.md
  ok "removed CLAUDE.md (was dangling @AGENTS.md import)"
fi

# .agents/skills symlink only
if [ -L .agents/skills ]; then
  rm .agents/skills
  ok "removed .agents/skills symlink"
  rmdir .agents 2>/dev/null && ok "removed empty .agents/" || true
else
  skip ".agents/skills not a symlink"
fi

# .codex/prompts and .codex/hooks.json
if [ -d .codex/prompts ] && [ -z "$(ls -A .codex/prompts 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
  rm -rf .codex/prompts && ok "removed empty .codex/prompts/"
else
  skip ".codex/prompts/ non-empty or missing"
fi
[ -f .codex/hooks.json ]            && { rm .codex/hooks.json            && ok "removed .codex/hooks.json"; }            || true
[ -f .codex/hooks.cc-bridge.json ]  && { rm .codex/hooks.cc-bridge.json  && ok "removed .codex/hooks.cc-bridge.json"; }  || true
[ -f .codex/config.toml ]           && { rm .codex/config.toml           && ok "removed .codex/config.toml"; }           || true
[ -d .codex ] && rmdir .codex 2>/dev/null && ok "removed empty .codex/" || true

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
