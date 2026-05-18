#!/usr/bin/env bash
# cc-bridge: initialize the Claude / Codex / Gemini bridge in the current repo.
# Idempotent. Safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DESCRIPTION=""
PRIVATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --description)
      if [ $# -lt 2 ] || [[ "$2" == --* ]]; then
        echo "--description requires a value" >&2; exit 2
      fi
      DESCRIPTION="$2"; shift 2 ;;
    --private)     PRIVATE=1; shift ;;
    --help|-h)     sed -n '2,4p' "$0"; exit 0 ;;
    *)             echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$DESCRIPTION" ]; then
  DESCRIPTION="$(basename "$PWD")"
fi

note() { printf '  %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }

# Tracks whether CLAUDE.md content was migrated into AGENTS.md in this run.
CLAUDE_MIGRATED=0

# --- 1. AGENTS.md ----------------------------------------------------------
if [ -f AGENTS.md ]; then
  skip "AGENTS.md already exists — leaving alone"
else
  EXISTING_BODY=""
  if [ -f CLAUDE.md ]; then
    # Migrate only if CLAUDE.md is entirely substantive content (no @AGENTS.md line at all).
    # A file that is "@AGENTS.md + extra lines" is an unusual hybrid — leave it alone.
    if grep -qE '^@AGENTS\.md\s*$' CLAUDE.md; then
      skip "CLAUDE.md already has @AGENTS.md import — not migrating"
    else
      EXISTING_BODY="$(cat CLAUDE.md)"
      CLAUDE_MIGRATED=1
    fi
  fi
  {
    echo "# Project Instructions"
    echo
    echo "> ${DESCRIPTION}"
    echo
    if [ -n "$EXISTING_BODY" ]; then
      echo "$EXISTING_BODY"
      echo
    else
      cat <<'TPL'
## Guidelines

<!-- Add project-specific instructions here -->

TPL
    fi
    cat <<'TPL'
## Shared Memory

**Always write new instructions, rules, and memory to `AGENTS.md` only.**

Never modify `CLAUDE.md` or `GEMINI.md` directly — they only import `AGENTS.md`.
This keeps Claude Code, Codex CLI, and Gemini CLI on the same context.

## Project Structure

- `.claude/` — Claude Code skills, agents, rules, hooks, commands
- `.agents/skills/` — symlink to `.claude/skills/` (Codex skill scan path)
- `.codex/prompts/` — Codex slash-command prompts
- `.codex/hooks.json` / `.codex/config.toml` — Codex hooks/config (optional)
- `.gemini/skills/`, `.gemini/commands/` — Gemini skills and TOML commands
- `.mcp.json` — MCP server registrations (shared by all three tools)
TPL
  } > AGENTS.md
  ok "AGENTS.md written ($([ "$CLAUDE_MIGRATED" = "1" ] && echo "migrated from CLAUDE.md" || echo "fresh"))"
fi

# --- 2. CLAUDE.md → @AGENTS.md import --------------------------------------
if [ -f CLAUDE.md ]; then
  if grep -qE '^@AGENTS\.md\s*$' CLAUDE.md; then
    skip "CLAUDE.md already imports @AGENTS.md"
  elif [ "$CLAUDE_MIGRATED" = "1" ]; then
    # Safe to replace: content was just written to AGENTS.md in this run.
    echo "@AGENTS.md" > CLAUDE.md
    ok "CLAUDE.md replaced with @AGENTS.md import (original content lives in AGENTS.md)"
  else
    skip "CLAUDE.md has unique content not in AGENTS.md — left alone (merge by hand if needed)"
  fi
else
  echo "@AGENTS.md" > CLAUDE.md
  ok "CLAUDE.md created (@AGENTS.md import)"
fi

# --- 3. GEMINI.md → @AGENTS.md import --------------------------------------
if [ -f GEMINI.md ]; then
  if grep -qE '^@AGENTS\.md\s*$' GEMINI.md; then
    skip "GEMINI.md already imports @AGENTS.md"
  else
    skip "GEMINI.md exists with custom content — left alone"
  fi
else
  echo "@AGENTS.md" > GEMINI.md
  ok "GEMINI.md created (@AGENTS.md import)"
fi

# --- 4. Codex / Gemini scaffolding -----------------------------------------
mkdir -p .codex/prompts .gemini/skills .gemini/commands
for d in .codex/prompts .gemini/skills .gemini/commands; do
  if [ ! -e "$d/.gitkeep" ]; then
    touch "$d/.gitkeep"
    ok "$d/.gitkeep"
  else
    skip "$d/.gitkeep"
  fi
done

# --- 5. .codex/config.toml -------------------------------------------------
if [ ! -f .codex/config.toml ]; then
  cat > .codex/config.toml <<'CFG'
# Codex CLI configuration for this project.
# See: https://developers.openai.com/codex/config-reference

# Uncomment to also read CLAUDE.md as a fallback instruction source:
# project_doc_fallback_filenames = ["CLAUDE.md"]

# MCP servers mirrored from .mcp.json are added below by /cc-bridge:bridge-mcp.
CFG
  ok ".codex/config.toml created"
else
  skip ".codex/config.toml already exists"
fi

# --- 6. Skills bridge -------------------------------------------------------
bash "${SCRIPT_DIR}/bridge_skills.sh"

# --- 7. .gitignore ----------------------------------------------------------
SENTINEL_START="# >>> cc-bridge >>>"
SENTINEL_END="# <<< cc-bridge <<<"
GITIGNORE_FILE=".gitignore"
[ -f "$GITIGNORE_FILE" ] || touch "$GITIGNORE_FILE"
# Detect the privacy mode of an existing block so we can replace it if it changed.
EXISTING_PRIVATE=0
if grep -qF "$SENTINEL_START" "$GITIGNORE_FILE"; then
  grep -qF "cc-bridge: PRIVATE mode" "$GITIGNORE_FILE" && EXISTING_PRIVATE=1 || EXISTING_PRIVATE=0
  if [ "$PRIVATE" = "$EXISTING_PRIVATE" ]; then
    skip ".gitignore already has cc-bridge block (mode unchanged)"
  else
    # Remove the old block so it can be rewritten with the new mode below.
    python3 - <<'PY'
from pathlib import Path
text = Path(".gitignore").read_text()
start = text.find("# >>> cc-bridge >>>")
end   = text.find("# <<< cc-bridge <<<")
if start != -1 and end != -1:
    tail = text.find("\n", end) + 1
    Path(".gitignore").write_text(text[:start].rstrip() + "\n" + text[tail:])
PY
  fi
fi
if ! grep -qF "$SENTINEL_START" "$GITIGNORE_FILE"; then
  {
    echo
    echo "$SENTINEL_START"
    cat <<'GI'
# AI assistant local state
.claude/settings.local.json
.claude/CLAUDE.local.md
.claude/*.local.*
CLAUDE.local.md

# Codex CLI — local files, keep checked-in subdirs
.codex/*
!.codex/skills/
!.codex/prompts/
!.codex/hooks.json
!.codex/hooks.cc-bridge.json
!.codex/config.toml

# Gemini CLI — local files, keep checked-in subdirs
.gemini/*
!.gemini/skills/
!.gemini/commands/
GI
    if [ "$PRIVATE" = "1" ]; then
      cat <<'GI'

# cc-bridge: PRIVATE mode — bridge artifacts not shared
AGENTS.md
CLAUDE.md
GEMINI.md
.claude/
.agents/
.codex/
.gemini/
.mcp.json
GI
    fi
    echo "$SENTINEL_END"
  } >> "$GITIGNORE_FILE"
  ok ".gitignore: cc-bridge block appended ($([ "$PRIVATE" = "1" ] && echo private || echo public) mode)"
fi

echo
ok "cc-bridge init complete. Edit AGENTS.md for shared instructions."
