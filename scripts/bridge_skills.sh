#!/usr/bin/env bash
# cc-suite: expose skills to Codex via .agents/skills (idempotent).
#
# Two things happen:
#   1. cc-suite's own skills (claude-review, claude-plan, etc.) are symlinked
#      into .claude/skills/cc-suite/ so Codex can find them.
#   2. .agents/skills → ../.claude/skills is created so the full .claude/skills/
#      tree (project skills + cc-suite skills) is visible to Codex.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
PLUGIN_SKILLS="${PLUGIN_ROOT}/skills/cc-suite"

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

# The plugin skills tree must exist before linking to it — a missing source
# would otherwise produce a broken symlink and a misleading success message.
if [ ! -d "$PLUGIN_SKILLS" ]; then
  warn "plugin skills directory missing: ${PLUGIN_SKILLS} — cannot bridge skills"
  exit 1
fi

# ── Step 1: expose cc-suite plugin skills in .claude/skills/cc-suite/ ────────

mkdir -p .claude/skills

if [ -L .claude/skills/cc-suite ]; then
  existing="$(readlink .claude/skills/cc-suite)"
  if [ "$existing" = "$PLUGIN_SKILLS" ]; then
    skip ".claude/skills/cc-suite already symlinked → ${PLUGIN_SKILLS}"
  else
    # Plugin was updated — repoint the symlink atomically. rename(2) replaces
    # the link itself without following it, so there is no window where the
    # bridge is absent, and (unlike macOS `ln -sf`) the new link can never be
    # created INSIDE the directory the old symlink resolves to.
    python3 - "$PLUGIN_SKILLS" <<'PY'
import os, sys
target = sys.argv[1]
tmp = f".claude/skills/.cc-suite-repoint-{os.getpid()}"
os.symlink(target, tmp)
try:
    os.replace(tmp, ".claude/skills/cc-suite")
except BaseException:
    os.unlink(tmp)
    raise
PY
    ok ".claude/skills/cc-suite repointed → ${PLUGIN_SKILLS}"
  fi
elif [ -e .claude/skills/cc-suite ]; then
  warn ".claude/skills/cc-suite exists as a real path — leaving alone to avoid data loss"
else
  ln -s "$PLUGIN_SKILLS" .claude/skills/cc-suite
  skill_count="$(find "$PLUGIN_SKILLS" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  ok ".claude/skills/cc-suite → ${PLUGIN_SKILLS} (${skill_count} skills)"
fi

# ── Step 2: .agents/skills → ../.claude/skills ───────────────────────────────

mkdir -p .agents

if [ -L .agents/skills ]; then
  target="$(readlink .agents/skills)"
  if [ "$target" = "../.claude/skills" ]; then
    skip ".agents/skills already symlinked → ../.claude/skills"
  else
    warn ".agents/skills points to ${target} — leaving alone; remove manually to let cc-suite replace it"
    exit 1
  fi
elif [ -e .agents/skills ]; then
  warn ".agents/skills exists as a real path — leaving alone to avoid data loss"
  warn "  move .agents/skills aside if you want cc-suite to take over"
  exit 1
else
  if ! ln -s ../.claude/skills .agents/skills 2>/dev/null; then
    if [ -L .agents/skills ] && [ "$(readlink .agents/skills)" = "../.claude/skills" ]; then
      skip ".agents/skills already symlinked (raced with concurrent run)"
    else
      warn "ln -s .agents/skills failed unexpectedly"
      exit 1
    fi
  fi
  count="$(find -L .agents/skills/ -maxdepth 2 -mindepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')"
  ok ".agents/skills → ../.claude/skills (${count} skills visible to Codex)"
fi

# ── Step 3: ensure .gitignore covers the symlinks we just created ────────────
# Hand off to the shared helper (also used by init.sh). CC_SUITE_RESPECT_MODE
# preserves a PRIVATE block if the project chose that mode; new blocks are
# created in the default public mode.
CC_SUITE_RESPECT_MODE=1 bash "$SCRIPT_DIR/ensure_gitignore.sh"
