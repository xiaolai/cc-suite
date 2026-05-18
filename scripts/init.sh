#!/usr/bin/env bash
# cc-suite: initialize the Claude / Codex / Gemini bridge in the current repo.
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
    # A pure @AGENTS.md import is a one-line file. Anything else (including
    # `@AGENTS.md\n# extra content`) is either substantive content or an
    # unusual hybrid and should NOT be silently overwritten.
    _claude_trim="$(tr -d '[:space:]' < CLAUDE.md)"
    if [ "$_claude_trim" = "@AGENTS.md" ]; then
      skip "CLAUDE.md is already a pure @AGENTS.md import — not migrating"
    elif grep -qE '^@AGENTS\.md\s*$' CLAUDE.md; then
      # Hybrid: @AGENTS.md line + other content. Refuse to touch it.
      skip "CLAUDE.md has @AGENTS.md + other content (hybrid) — left alone; merge by hand"
    else
      EXISTING_BODY="$(cat CLAUDE.md)"
      CLAUDE_MIGRATED=1
      # Save the original CLAUDE.md verbatim so unbridge.sh can restore it
      # without the cc-suite scaffolding that AGENTS.md adds around the body.
      mkdir -p .codex
      cp CLAUDE.md .codex/.cc-suite-original-claude.md
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
  _claude_trim="$(tr -d '[:space:]' < CLAUDE.md)"
  if [ "$_claude_trim" = "@AGENTS.md" ]; then
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
  CC_SUITE_CREATED_CLAUDE=1
  ok "CLAUDE.md created (@AGENTS.md import)"
fi

# --- 3. GEMINI.md → @AGENTS.md import --------------------------------------
if [ -f GEMINI.md ]; then
  _gemini_trim="$(tr -d '[:space:]' < GEMINI.md)"
  if [ "$_gemini_trim" = "@AGENTS.md" ]; then
    skip "GEMINI.md already imports @AGENTS.md"
  else
    skip "GEMINI.md exists with custom content — left alone"
  fi
else
  echo "@AGENTS.md" > GEMINI.md
  CC_SUITE_CREATED_GEMINI=1
  ok "GEMINI.md created (@AGENTS.md import)"
fi

# Record provenance so unbridge.sh can know whether to delete files it didn't create.
mkdir -p .codex
PROVENANCE=".codex/.cc-suite.provenance"
{
  echo "# cc-suite provenance — used by unbridge.sh"
  [ -n "${CLAUDE_MIGRATED:-}" ]         && [ "$CLAUDE_MIGRATED" = "1" ]         && echo "CLAUDE_MIGRATED=1"
  [ -n "${CC_SUITE_CREATED_CLAUDE:-}" ] && echo "CC_SUITE_CREATED_CLAUDE=1"
  [ -n "${CC_SUITE_CREATED_GEMINI:-}" ] && echo "CC_SUITE_CREATED_GEMINI=1"
} >> "$PROVENANCE"

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
# cc-suite: generated-by-init  (this comment is consumed by unbridge)
# Codex CLI configuration for this project.
# See: https://developers.openai.com/codex/config-reference

# Uncomment to also read CLAUDE.md as a fallback instruction source:
# project_doc_fallback_filenames = ["CLAUDE.md"]

# MCP servers mirrored from .mcp.json are added below by /cc-suite:bridge-mcp.
CFG
  ok ".codex/config.toml created"
  echo "CC_SUITE_CREATED_CODEX_CONFIG=1" >> "$PROVENANCE"
else
  skip ".codex/config.toml already exists"
fi

# --- 6. Skills bridge -------------------------------------------------------
bash "${SCRIPT_DIR}/bridge_skills.sh"

# --- 7. .gitignore ----------------------------------------------------------
SENTINEL_START="# >>> cc-suite >>>"
SENTINEL_END="# <<< cc-suite <<<"
GITIGNORE_FILE=".gitignore"
[ -f "$GITIGNORE_FILE" ] || touch "$GITIGNORE_FILE"
# Detect the privacy mode of an existing block so we can replace it if it changed.
EXISTING_PRIVATE=0
if grep -qF "$SENTINEL_START" "$GITIGNORE_FILE"; then
  grep -qF "cc-suite: PRIVATE mode" "$GITIGNORE_FILE" && EXISTING_PRIVATE=1 || EXISTING_PRIVATE=0
  if [ "$PRIVATE" = "$EXISTING_PRIVATE" ]; then
    skip ".gitignore already has cc-suite block (mode unchanged)"
  else
    # Remove the old block so it can be rewritten with the new mode below.
    python3 - <<'PY'
from pathlib import Path
text = Path(".gitignore").read_text()
start = text.find("# >>> cc-suite >>>")
end   = text.find("# <<< cc-suite <<<")
if start != -1 and end != -1:
    nl = text.find("\n", end)
    tail = nl + 1 if nl != -1 else len(text)
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
!.codex/hooks.cc-suite.json
!.codex/config.toml

# Gemini CLI — local files, keep checked-in subdirs
.gemini/*
!.gemini/skills/
!.gemini/commands/
GI
    if [ "$PRIVATE" = "1" ]; then
      cat <<'GI'

# cc-suite: PRIVATE mode — bridge artifacts not shared
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
  ok ".gitignore: cc-suite block appended ($([ "$PRIVATE" = "1" ] && echo private || echo public) mode)"
fi

echo
ok "cc-suite init complete. Edit AGENTS.md for shared instructions."
