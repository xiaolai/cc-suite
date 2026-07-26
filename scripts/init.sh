#!/usr/bin/env bash
# cc-suite: initialize the Claude / Codex / Antigravity (`agy`) bridge in the current repo.
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

# Which coding agents this project bridges. Single-sourced from the
# `## Enabled Tools` section of .cc-suite.md via the bridge engine, which falls
# back to claude/codex/antigravity when the file or section is absent — so a
# project initialized before tool selection existed behaves exactly as before.
ENABLED_TOOLS="$(python3 "${SCRIPT_DIR}/bridge_tools.py" --enabled 2>/dev/null || true)"
[ -n "$ENABLED_TOOLS" ] || ENABLED_TOOLS=$'claude\ncodex\nantigravity'

tool_enabled() { printf '%s\n' "$ENABLED_TOOLS" | grep -qx "$1"; }

# cc-suite's own bookkeeping. It used to live under .codex/, which meant a
# project that bridges no Codex still grew a .codex/ directory — misleading, and
# the reason tool selection looked like it had not taken effect. This is
# cc-suite state, so it belongs in cc-suite's namespace. unbridge.sh still reads
# the legacy paths so repos initialized before the move keep working.
STATE_DIR=".cc-suite"
PROVENANCE="${STATE_DIR}/provenance"
ORIGINAL_CLAUDE="${STATE_DIR}/original-claude.md"

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
      mkdir -p "$STATE_DIR"
      cp CLAUDE.md "$ORIGINAL_CLAUDE"
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

Never modify `CLAUDE.md` directly — it only imports `AGENTS.md`.
This keeps Claude Code, Codex CLI, and Antigravity CLI (`agy`) on the same
context; Codex and `agy` both read `AGENTS.md` natively.

## Project Structure

- `.claude/` — Claude Code skills, agents, rules, hooks, commands
- `.agents/skills/` — symlink to `.claude/skills/` (Codex skill scan path)
- `.codex/prompts/` — Codex slash-command prompts
- `.codex/hooks.json` / `.codex/config.toml` — Codex hooks/config (optional)
- `.mcp.json` — MCP server registrations (Claude Code + Codex)
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

# --- 3. (removed) GEMINI.md ------------------------------------------------
# Consumer Gemini CLI access moved to Antigravity CLI (`agy`) on 2026-06-18;
# enterprise/API users may still retain legacy files. A GEMINI.md pointer is
# not needed by agy and is no longer created for new projects.
# unbridge.sh still removes a legacy GEMINI.md left by older cc-suite versions.

# Record provenance so unbridge.sh can know whether to delete files it didn't
# create. Written lazily: a project with nothing to record gets no file and no
# directory at all.
# Single entry point for provenance writes. Creates the state dir and the
# header on first use, so later callers (the Codex config block below) cannot
# append into a directory that the lazy path decided not to create.
record_provenance() {
  mkdir -p "$STATE_DIR"
  if [ ! -f "$PROVENANCE" ]; then
    echo "# cc-suite provenance — used by unbridge.sh" > "$PROVENANCE"
  fi
  printf '%s\n' "$1" >> "$PROVENANCE"
}

if [ "${CLAUDE_MIGRATED:-0}" = "1" ]; then
  record_provenance "CLAUDE_MIGRATED=1"
fi
if [ -n "${CC_SUITE_CREATED_CLAUDE:-}" ]; then
  record_provenance "CC_SUITE_CREATED_CLAUDE=1"
fi

# --- 4. Codex scaffolding ---------------------------------------------------
if ! tool_enabled codex; then
  skip ".codex/prompts skipped — codex not enabled for this project"
else
  mkdir -p .codex/prompts
  for d in .codex/prompts; do
    if [ ! -e "$d/.gitkeep" ]; then
      touch "$d/.gitkeep"
      ok "$d/.gitkeep"
    else
      skip "$d/.gitkeep"
    fi
  done
fi

# --- 5. .codex/config.toml -------------------------------------------------
if ! tool_enabled codex; then
  skip ".codex/config.toml skipped — codex not enabled for this project"
elif [ ! -f .codex/config.toml ]; then
  cat > .codex/config.toml <<'CFG'
# cc-suite: generated-by-init  (this comment is consumed by unbridge)
# Codex CLI configuration for this project.
# See: https://developers.openai.com/codex/config-reference

# Uncomment to also read CLAUDE.md as a fallback instruction source:
# project_doc_fallback_filenames = ["CLAUDE.md"]

# MCP servers mirrored from .mcp.json are added below by /cc-suite:bridge-mcp.
CFG
  ok ".codex/config.toml created"
  record_provenance "CC_SUITE_CREATED_CODEX_CONFIG=1"
else
  skip ".codex/config.toml already exists"
fi

# --- 6. Skills bridge -------------------------------------------------------
bash "${SCRIPT_DIR}/bridge_skills.sh"

# --- 7. .gitignore ----------------------------------------------------------
# Delegates to scripts/ensure_gitignore.sh — same helper bridge_skills.sh
# calls, so the block stays in sync whether the user re-runs /cc-suite:init
# or just /cc-suite:bridge-skills. PRIVATE carries the --private flag.
PRIVATE="$PRIVATE" bash "$SCRIPT_DIR/ensure_gitignore.sh"

echo
ok "cc-suite init complete. Edit AGENTS.md for shared instructions."
