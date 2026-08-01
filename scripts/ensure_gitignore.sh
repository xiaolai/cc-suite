#!/usr/bin/env bash
# cc-suite: write or refresh the cc-suite-managed sentinel block in .gitignore.
#
# Idempotent. Safe to re-run. Callers:
#
#   - scripts/init.sh: sets PRIVATE=0|1 explicitly to honor the --private flag
#     and switches mode if the existing block uses the other one.
#   - scripts/bridge_skills.sh: sets CC_SUITE_RESPECT_MODE=1 so an existing
#     PRIVATE block stays private; bridge_skills only ensures the block exists
#     and is at the current schema.
#
# Env vars:
#   PRIVATE                  0 or 1. The mode to write. Defaults to 0.
#   CC_SUITE_RESPECT_MODE    When non-empty, preserve the existing block's
#                            mode regardless of PRIVATE. New blocks fall back
#                            to PRIVATE (i.e. public by default).
#
# Schema: the SCHEMA_MARKER comment is bumped whenever the block body changes
# structurally. Absence of the current marker in an existing block triggers a
# rewrite so installs from older cc-suite versions migrate automatically.

set -euo pipefail

SENTINEL_START="# >>> cc-suite >>>"
SENTINEL_END="# <<< cc-suite <<<"
SCHEMA_MARKER="# cc-suite-schema: 7"

GITIGNORE_FILE=".gitignore"
PRIVATE="${PRIVATE:-0}"

# A publishable plugin repo ships its root files to every installer, and Claude
# Code auto-registers a plugin-root .mcp.json — starting `codex mcp-server` for
# everyone who installs the plugin. The codex-cli registration is a dev-only
# delegation aid, so in a plugin repo it must stay out of the published tree
# even in public mode (in private mode the whole bridge is already ignored).
IS_PLUGIN_REPO=0
if [ -f ".claude-plugin/plugin.json" ] || [ -f ".codex-plugin/plugin.json" ]; then
  IS_PLUGIN_REPO=1
fi

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }

# Self-heal an already-leaked plugin repo: if .mcp.json is ignored but was
# committed by an earlier cc-suite version, drop it from the index so the
# ignore takes effect. The working-tree file is kept for local dev. No-op
# outside a git repo or when nothing is tracked. Runs on every invocation,
# including the fast already-current exit.
self_heal_tracked_mcp() {
  if [ "$IS_PLUGIN_REPO" = "1" ] && [ "$PRIVATE" != "1" ]; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && git ls-files --error-unmatch .mcp.json >/dev/null 2>&1; then
      git rm --cached --quiet .mcp.json
      ok ".mcp.json untracked (was shipping in the published plugin — kept locally)"
    fi
  fi
}

[ -f "$GITIGNORE_FILE" ] || touch "$GITIGNORE_FILE"

EXISTING_PRIVATE=0
EXISTING_SCHEMA_CURRENT=0
if grep -qF "$SENTINEL_START" "$GITIGNORE_FILE" || grep -qF "$SENTINEL_END" "$GITIGNORE_FILE"; then
  # Validate exactly one ordered sentinel pair before touching the block: a
  # lone, duplicated, or reversed marker means hand-editing or an interrupted
  # run, and rewriting through it would splice unrelated user content.
  if ! python3 - <<'PY'; then
import sys
from pathlib import Path
text = Path(".gitignore").read_text()
start = "# >>> cc-suite >>>"
end   = "# <<< cc-suite <<<"
valid = (text.count(start) == 1 and text.count(end) == 1
         and text.find(start) < text.find(end))
sys.exit(0 if valid else 1)
PY
    printf '! .gitignore cc-suite sentinel block is malformed (missing, duplicated, or out-of-order marker) — repair it by hand, then re-run\n' >&2
    exit 1
  fi

  grep -qF "cc-suite: PRIVATE mode" "$GITIGNORE_FILE" && EXISTING_PRIVATE=1 || EXISTING_PRIVATE=0
  grep -qF "$SCHEMA_MARKER" "$GITIGNORE_FILE" && EXISTING_SCHEMA_CURRENT=1 || EXISTING_SCHEMA_CURRENT=0

  if [ -n "${CC_SUITE_RESPECT_MODE:-}" ]; then
    PRIVATE="$EXISTING_PRIVATE"
  fi

  if [ "$PRIVATE" = "$EXISTING_PRIVATE" ] && [ "$EXISTING_SCHEMA_CURRENT" = "1" ]; then
    skip ".gitignore already has current cc-suite block"
    self_heal_tracked_mcp
    exit 0
  fi

  # Strip the old block so it can be rewritten with the current schema.
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

{
  echo
  echo "$SENTINEL_START"
  echo "$SCHEMA_MARKER"
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

# cc-suite-managed symlinks (created by bridge_skills.sh) — derived, not authored
.claude/skills/cc-suite
.agents/skills

# Antigravity workspace MCP config is generated from .mcp.json and may contain
# credentials or machine-specific paths.
.agents/mcp_config.json
.agents/.cc-suite-mcp.provenance.json

# cc-suite tool-profile bridge (grok/opencode/qwen) — derived provenance
# sidecars tracking which MCP servers cc-suite owns. Not authored.
.cc-suite-*.provenance.json

# cc-suite local state — what init created, and the pre-bridge CLAUDE.md backup.
# Machine-local bookkeeping, not shared. Listed file-by-file on purpose:
# .cc-suite/agents/ holds declared advisors and IS meant to be committed.
.cc-suite/provenance
.cc-suite/original-claude.md
# Audit findings files written by /cc-suite:audit and the audit-fix loop —
# per-run working state (findings + fix statuses), not authored content.
.cc-suite/audits/
GI
  if [ "$IS_PLUGIN_REPO" = "1" ] && [ "$PRIVATE" != "1" ]; then
    cat <<'GI'

# cc-suite: plugin repo — keep the dev-only Codex MCP registration out of the
# published plugin. Claude Code auto-registers a plugin-root .mcp.json, which
# would start `codex mcp-server` for every installer. Local dev use is fine;
# the file just stays untracked.
.mcp.json

# cc-suite: plugin repo — these are consumer-workspace scaffolds created when
# the plugin repository is used as its own local test target. They are not
# plugin source files and must not appear in releases.
.codex/config.toml
.codex/prompts/
.gemini/
GEMINI.md
GI
  fi
  if [ "$PRIVATE" = "1" ]; then
    cat <<'GI'

# cc-suite: PRIVATE mode — bridge artifacts not shared
AGENTS.md
CLAUDE.md
.claude/
.agents/
.codex/
.mcp.json
GI
  fi
  echo "$SENTINEL_END"
} >> "$GITIGNORE_FILE"

mode_label=$([ "$PRIVATE" = "1" ] && echo private || echo public)
ok ".gitignore: cc-suite block written ($mode_label mode, schema ${SCHEMA_MARKER##*: })"

self_heal_tracked_mcp
