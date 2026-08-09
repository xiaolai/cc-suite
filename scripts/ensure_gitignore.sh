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
# First line of the conditional plugin-repo .mcp.json stanza, emitted from this
# variable so detecting the stanza and writing it cannot drift apart.
MCP_IGNORE_MARKER="# cc-suite: plugin repo — keep the dev-only Codex MCP registration out of the"

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
warn() { printf '! %s\n' "$*" >&2; }

# cc-suite owns .mcp.json only while every entry in it is one cc-suite wrote:
# the dev-only codex-cli registration and advisor servers carrying the
# `_cc_suite_agent` marker. A plugin that publishes MCP servers of its own owns
# that file, and ignoring or untracking it would silently drop working
# functionality from the release. An absent file counts as owned — cc-suite is
# the one about to create it. Unreadable or unparseable counts as not owned.
#
# Exit status answers ownership; stdout lists the cc-suite-written entries
# found, which is what still ships when ownership says the file must not be
# ignored. One pass so the two answers cannot disagree.
#
#   0  every entry is cc-suite's
#   1  a foreign entry is present
#   2  the file could not be inspected (unreadable, or not the shape we write)
#
# Every path prints before exiting. Returning early from a shape rejection left
# the caller with an empty entry list, which silently suppressed the leak
# warning below for exactly the files most likely to be leaking.
mcp_json_is_cc_suite_owned() {
  [ -e ".mcp.json" ] || return 0
  python3 - <<'PY'
import json, sys
from pathlib import Path

# `codex-cli` is a reserved name, not a shape to match: scripts/mcp_codex.sh
# rewrites whatever is under that key to the canonical server on every run, so
# cc-suite already owns it however it currently looks. Requiring exact equality
# classified a legacy registration — the precise state mcp_codex.sh exists to
# migrate — as someone else's, which withheld the ignore stanza and left the
# plugin's .mcp.json tracked until the migration happened to run first.
CC_SUITE_RESERVED = {"codex-cli"}


def finish(entries, code):
    print(" ".join(sorted(entries)))
    sys.exit(code)


try:
    data = json.loads(Path(".mcp.json").read_text(encoding="utf-8"))
except (OSError, ValueError):
    finish([], 2)
if not isinstance(data, dict) or set(data) - {"mcpServers"}:
    finish([], 2)
servers = data.get("mcpServers", {})
if not isinstance(servers, dict):
    finish([], 2)
cc_suite_written = []
foreign = False
for name, entry in servers.items():
    if name in CC_SUITE_RESERVED:
        cc_suite_written.append(name)
    elif isinstance(entry, dict) and entry.get("_cc_suite_agent"):
        cc_suite_written.append(name)
    else:
        foreign = True
finish(cc_suite_written, 1 if foreign else 0)
PY
}

MCP_JSON_CC_ENTRIES=""
MCP_JSON_OWNED=0
MCP_JSON_INSPECTED=1
MCP_JSON_STATUS=0
MCP_JSON_CC_ENTRIES="$(mcp_json_is_cc_suite_owned)" || MCP_JSON_STATUS=$?
case "$MCP_JSON_STATUS" in
  0) MCP_JSON_OWNED=1 ;;
  2) MCP_JSON_INSPECTED=0 ;;
esac

# Whether the block should carry the plugin-repo .mcp.json stanza. PRIVATE is
# resolved late (CC_SUITE_RESPECT_MODE), so this is a function, not a constant.
want_mcp_ignore() {
  [ "$IS_PLUGIN_REPO" = "1" ] && [ "$PRIVATE" != "1" ] && [ "$MCP_JSON_OWNED" = "1" ]
}

# Self-heal an already-leaked plugin repo: if a cc-suite-owned .mcp.json is
# ignored but was committed by an earlier cc-suite version, drop it from the
# index so the ignore takes effect. The working-tree file is kept for local
# dev. No-op outside a git repo, when nothing is tracked, or when the file is
# the plugin's own. Runs on every invocation, including the fast
# already-current exit.
self_heal_tracked_mcp() {
  if [ "$IS_PLUGIN_REPO" != "1" ] || [ "$PRIVATE" = "1" ]; then
    return 0
  fi
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git ls-files --error-unmatch .mcp.json >/dev/null 2>&1 || return 0
  if [ "$MCP_JSON_OWNED" = "1" ]; then
    git rm --cached --quiet .mcp.json
    ok ".mcp.json untracked (was shipping in the published plugin — kept locally)"
  else
    if [ "$MCP_JSON_INSPECTED" = "0" ]; then
      skip ".mcp.json left tracked: cc-suite could not inspect it, so it cannot prove the file is only a dev-only bridge artifact"
    else
      skip ".mcp.json left tracked: it registers MCP servers cc-suite does not own, so it is plugin content rather than a dev-only bridge artifact"
    fi
  fi
}

# Once .mcp.json stops being cc-suite-owned it counts as plugin content, so the
# ignore stanza is withheld (or dropped) and the file ships to every installer —
# carrying whatever dev-only registrations cc-suite left inside it. cc-suite
# cannot resolve that: ignoring the file would drop the plugin's own servers
# from the release. Report the conflict every run rather than let ownership flip
# rewrite .gitignore in silence.
warn_unowned_mcp_leak() {
  [ "$IS_PLUGIN_REPO" = "1" ] || return 0
  [ "$PRIVATE" != "1" ] || return 0
  [ "$MCP_JSON_OWNED" != "1" ] || return 0
  warn ".mcp.json is not ignored, so it ships to everyone who installs this plugin"
  if [ "$MCP_JSON_INSPECTED" = "0" ]; then
    warn "  cc-suite could not inspect it (unreadable, or not the shape cc-suite writes), so it cannot say which entries are its own"
  elif [ -n "$MCP_JSON_CC_ENTRIES" ]; then
    warn "  it registers MCP servers cc-suite does not own, so it counts as plugin content"
    warn "  cc-suite wrote these entries, and they ship with it: ${MCP_JSON_CC_ENTRIES}"
  else
    warn "  it registers MCP servers cc-suite does not own, so it counts as plugin content"
  fi
  warn "  remove them from .mcp.json before publishing, or ignore the file by hand if it is not meant to be released"
}

# PRIVATE mode only stops future sharing — paths git already tracks keep being
# committed and pushed no matter what .gitignore says. Rewriting someone's
# index is theirs to authorize, so report it with the exact command instead.
warn_tracked_private_paths() {
  [ "$PRIVATE" = "1" ] || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local tracked
  tracked="$( { git ls-files -- AGENTS.md CLAUDE.md .claude .agents .codex .mcp.json || true; } \
              | awk -F/ '{ print $1 }' | sort -u | tr '\n' ' ')"
  tracked="${tracked% }"
  [ -n "$tracked" ] || return 0
  warn "PRIVATE mode: git still tracks these bridge artifacts, so they keep being shared: ${tracked}"
  warn "  to stop sharing them, review and then run:  git rm -r --cached ${tracked}"
  warn "  (the working-tree files are kept; commit the removal for it to take effect)"
}

[ -f "$GITIGNORE_FILE" ] || touch "$GITIGNORE_FILE"

# The exact block this run would write. Making it a function is what lets the
# already-current check compare real content: the previous check compared
# proxies (mode, schema marker, mcp stanza) and so could not see a hand-deleted
# entry or a stanza that became required after the block was written — leaving
# diagnose reporting a problem whose auto fix was a provable no-op.
render_block() {
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
  if want_mcp_ignore; then
    echo
    echo "$MCP_IGNORE_MARKER"
    cat <<'GI'
# published plugin. Claude Code auto-registers a plugin-root .mcp.json, which
# would start `codex mcp-server` for every installer. Local dev use is fine;
# the file just stays untracked.
.mcp.json
GI
  fi
  if [ "$IS_PLUGIN_REPO" = "1" ] && [ "$PRIVATE" != "1" ]; then
    cat <<'GI'

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
}

# The cc-suite block currently in .gitignore, sentinels included, or nothing
# when there is none.
extract_existing_block() {
  python3 - <<'PY'
from pathlib import Path

text = Path(".gitignore").read_text()
start = text.find("# >>> cc-suite >>>")
end = text.find("# <<< cc-suite <<<")
if start == -1 or end == -1:
    raise SystemExit(0)
nl = text.find("\n", end)
print(text[start:(nl if nl != -1 else len(text))])
PY
}

EXISTING_PRIVATE=0
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

  if [ -n "${CC_SUITE_RESPECT_MODE:-}" ]; then
    PRIVATE="$EXISTING_PRIVATE"
  fi

  # Compare the block this run would write against the one on disk. Content
  # equality is the only check that cannot go stale: mode, schema marker, and
  # the mcp stanza were proxies, so a hand-deleted entry, or a stanza that
  # became required after the block was written (a project that later gains
  # .claude-plugin/plugin.json), left the block permanently un-refreshed while
  # diagnose reported it as broken with an auto fix that did nothing.
  if [ "$(render_block)" = "$(extract_existing_block)" ]; then
    skip ".gitignore already has current cc-suite block"
    self_heal_tracked_mcp
    warn_unowned_mcp_leak
    warn_tracked_private_paths
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
  render_block
} >> "$GITIGNORE_FILE"

mode_label=$([ "$PRIVATE" = "1" ] && echo private || echo public)
ok ".gitignore: cc-suite block written ($mode_label mode, schema ${SCHEMA_MARKER##*: })"

self_heal_tracked_mcp
warn_unowned_mcp_leak
warn_tracked_private_paths
