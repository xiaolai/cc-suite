#!/usr/bin/env bash
# cc-bridge: create the .agents/skills → .claude/skills symlink (Codex scan path).
# Idempotent.

set -euo pipefail

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

if [ ! -d .claude/skills ]; then
  skip ".claude/skills/ does not exist — nothing to bridge"
  exit 0
fi

mkdir -p .agents

if [ -L .agents/skills ]; then
  target="$(readlink .agents/skills)"
  if [ "$target" = "../.claude/skills" ]; then
    skip ".agents/skills already symlinked to ../.claude/skills"
    exit 0
  else
    warn ".agents/skills is a symlink to $target — leaving alone; remove it manually if you want cc-bridge to replace it"
    exit 1
  fi
fi

if [ -e .agents/skills ]; then
  warn ".agents/skills exists as a real path (not symlink) — leaving alone to avoid data loss"
  warn "  if you want cc-bridge to take over, move .agents/skills aside first"
  exit 1
fi

ln -s ../.claude/skills .agents/skills
count="$(find .agents/skills/ -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
ok ".agents/skills → ../.claude/skills (${count} skills visible to Codex)"
