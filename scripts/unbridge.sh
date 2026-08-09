#!/usr/bin/env bash
# cc-suite: tear down the bridge artifacts. Safe: never deletes .claude/ or its contents.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }

UNBRIDGE_FAILED=0

# Returns 0 if the named file contains only "@AGENTS.md" (bare import, no other content).
is_pure_import() {
  python3 -c '
import sys
from pathlib import Path
c = Path(sys.argv[1]).read_text().strip()
sys.exit(0 if c == "@AGENTS.md" else 1)
' "$1" 2>/dev/null
}

# Copy AGENTS.md to the first free AGENTS.md.cc-suite-backup[.N] slot and set
# AGENTS_BACKUP to the path used. Never overwrites an earlier backup.
AGENTS_BACKUP=""
backup_agents() {
  AGENTS_BACKUP="AGENTS.md.cc-suite-backup"
  _i=1
  while [ -f "$AGENTS_BACKUP" ]; do
    AGENTS_BACKUP="AGENTS.md.cc-suite-backup.$_i"
    _i=$((_i + 1))
  done
  cp AGENTS.md "$AGENTS_BACKUP"
}

# Name (without creating) the first free CLAUDE.md.cc-suite-backup[.N] slot.
# A pre-init CLAUDE.md backup that could not be restored is the sole copy of
# that content, and init.sh rewrites .cc-suite/original-claude.md
# unconditionally — so keeping it there loses it on the next init.
CLAUDE_BACKUP=""
next_claude_backup() {
  CLAUDE_BACKUP="CLAUDE.md.cc-suite-backup"
  _i=1
  while [ -e "$CLAUDE_BACKUP" ]; do
    CLAUDE_BACKUP="CLAUDE.md.cc-suite-backup.$_i"
    _i=$((_i + 1))
  done
}

# Returns 0 only if AGENTS.md is byte-for-byte what init.sh generates, so its
# deletion loses nothing. init.sh tells users to write their instructions into
# AGENTS.md, so any drift from the generated file is content that exists
# nowhere else. $1 is the migrated body file (empty for a fresh scaffold); the
# `> description` line is init's only free variable. A template from an older
# cc-suite release will not match — that errs toward keeping a backup.
agents_is_generated() {
  python3 - "${1:-}" <<'PY' 2>/dev/null
import sys
from pathlib import Path

HEAD = "# Project Instructions\n\n> "
FRESH_BODY = "## Guidelines\n\n<!-- Add project-specific instructions here -->"
# Must match the trailing TPL heredoc in init.sh verbatim.
TAIL = """## Shared Memory

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
"""

body_source = sys.argv[1]
body = Path(body_source).read_text(encoding="utf-8") if body_source else ""
# init.sh captures the body with $(cat CLAUDE.md), which strips trailing
# newlines, and writes FRESH_BODY when the result is empty. A CLAUDE.md that
# was empty at init time therefore produced the fresh scaffold, not an empty
# body, and must compare against that.
if not body.rstrip("\n"):
    body = FRESH_BODY
text = Path("AGENTS.md").read_text(encoding="utf-8")
if not text.startswith(HEAD):
    sys.exit(1)
rest = text[len(HEAD):]
nl = rest.find("\n")
if nl == -1:
    sys.exit(1)
sys.exit(0 if rest[nl + 1:] == "\n" + body.rstrip("\n") + "\n\n" + TAIL else 1)
PY
}

# Returns 0 if the named file is a hooks file cc-suite generated: the exact
# marker bridge_hooks.py writes, no sibling top-level keys, and no events
# outside the mirrored set.
is_bridge_hooks_file() {
  python3 - "$1" <<'PY' 2>/dev/null
import json, sys
from pathlib import Path

BRIDGE_EVENTS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"}
try:
    data = json.loads(Path(sys.argv[1]).read_text())
except Exception:
    sys.exit(1)
if not isinstance(data, dict) or data.get("_cc_bridge_version") != "1":
    sys.exit(1)
if set(data) - {"_cc_bridge_version", "hooks"}:
    sys.exit(1)
hooks = data.get("hooks", {})
sys.exit(0 if isinstance(hooks, dict) and set(hooks) <= BRIDGE_EVENTS else 1)
PY
}

# Read provenance written by init.sh. cc-suite state moved from .codex/ into
# .cc-suite/ so a project that bridges no Codex gets no .codex/ directory; the
# legacy paths are still honoured for repos initialized before that move.
PROVENANCE=".cc-suite/provenance"
LEGACY_PROVENANCE=".codex/.cc-suite.provenance"
[ -f "$PROVENANCE" ] || PROVENANCE="$LEGACY_PROVENANCE"

ORIGINAL_CLAUDE=".cc-suite/original-claude.md"
LEGACY_ORIGINAL_CLAUDE=".codex/.cc-suite-original-claude.md"
[ -f "$ORIGINAL_CLAUDE" ] || ORIGINAL_CLAUDE="$LEGACY_ORIGINAL_CLAUDE"

CLAUDE_MIGRATED=0
CC_SUITE_CREATED_CLAUDE=0
CC_SUITE_CREATED_GEMINI=0
# Empty means "not recorded" (legacy install or pre-existing AGENTS.md) and
# falls back to the scaffold-content heuristic below; "1" means init wrote
# AGENTS.md itself.
CC_SUITE_CREATED_AGENTS=""
if [ -f "$PROVENANCE" ]; then
  # shellcheck disable=SC1090
  while IFS='=' read -r k v; do
    case "$k" in
      CLAUDE_MIGRATED)            CLAUDE_MIGRATED="$v" ;;
      CC_SUITE_CREATED_CLAUDE)   CC_SUITE_CREATED_CLAUDE="$v" ;;
      CC_SUITE_CREATED_GEMINI)   CC_SUITE_CREATED_GEMINI="$v" ;;
      CC_SUITE_CREATED_AGENTS)   CC_SUITE_CREATED_AGENTS="$v" ;;
    esac
  done < "$PROVENANCE"
fi

# Original CLAUDE.md — restore it before anything else, and independently of
# AGENTS.md. The backup is the only copy of the pre-init instructions, so a
# missing AGENTS.md must not strand it (it is deleted further down).
RESTORED_ORIGINAL=0
next_claude_backup
if [ "$CLAUDE_MIGRATED" = "1" ] && [ -f "$ORIGINAL_CLAUDE" ]; then
  if [ -f CLAUDE.md ] && cmp -s "$ORIGINAL_CLAUDE" CLAUDE.md; then
    RESTORED_ORIGINAL=1
  elif [ ! -f CLAUDE.md ] || is_pure_import CLAUDE.md; then
    cp "$ORIGINAL_CLAUDE" CLAUDE.md
    if cmp -s "$ORIGINAL_CLAUDE" CLAUDE.md; then
      RESTORED_ORIGINAL=1
      ok "restored original CLAUDE.md content from cc-suite backup"
    else
      warn "restoring CLAUDE.md from $ORIGINAL_CLAUDE did not verify — original preserved as $CLAUDE_BACKUP"
      UNBRIDGE_FAILED=1
    fi
  else
    warn "CLAUDE.md has content of its own — left alone; original preserved as $CLAUDE_BACKUP"
  fi
fi

# AGENTS.md — restore content to CLAUDE.md first, then delete. A pre-existing
# AGENTS.md that init.sh left untouched must survive unbridge — it is user
# content that exists nowhere else.
KEEP_AGENTS=0
# Set when a branch has already copied AGENTS.md somewhere durable.
AGENTS_PRESERVED=0
# The migrated body init.sh wrote into AGENTS.md; empty means a fresh scaffold.
AGENTS_BODY_SOURCE=""
if [ -f AGENTS.md ]; then
  if [ "$CC_SUITE_CREATED_CLAUDE" = "1" ]; then
    # Recorded provenance beats content inspection: init.sh writes
    # CC_SUITE_CREATED_AGENTS=1 whenever it created AGENTS.md itself. The
    # scaffold-content heuristic below remains only for legacy installs whose
    # provenance predates that key.
    if [ "$CC_SUITE_CREATED_AGENTS" = "1" ]; then
      # init.sh created both files from scratch — nothing original to restore.
      skip "CLAUDE.md was created by cc-suite; will be removed (no content to restore)"
    elif [ -n "$CC_SUITE_CREATED_AGENTS" ]; then
      # Explicitly recorded as NOT created by init — user content.
      KEEP_AGENTS=1
      skip "AGENTS.md predates cc-suite (recorded provenance) — left alone"
    elif grep -qF 'Never modify `CLAUDE.md` directly' AGENTS.md; then
      # Legacy install (no CC_SUITE_CREATED_AGENTS record): fall back to the
      # scaffold marker init.sh wrote into a cc-suite-created AGENTS.md.
      skip "CLAUDE.md was created by cc-suite; will be removed (no content to restore)"
    else
      # No record and no cc-suite scaffold: AGENTS.md predated init.sh, which
      # only created the CLAUDE.md import. Deleting it would lose user content.
      KEEP_AGENTS=1
      skip "AGENTS.md predates cc-suite — left alone"
    fi
  elif [ "$RESTORED_ORIGINAL" = "1" ]; then
    # The verbatim original CLAUDE.md is already back; AGENTS.md holds it
    # wrapped in cc-suite scaffolding.
    AGENTS_BODY_SOURCE="$ORIGINAL_CLAUDE"
  elif [ -f CLAUDE.md ] && is_pure_import CLAUDE.md; then
    # No provenance and CLAUDE.md is a bare @import — fall back to copying
    # AGENTS.md verbatim. May include scaffolding, but better than data loss.
    cp AGENTS.md CLAUDE.md
    AGENTS_PRESERVED=1
    warn "no provenance found; restored CLAUDE.md from AGENTS.md verbatim (may include cc-suite scaffolding)"
  elif [ ! -f CLAUDE.md ]; then
    cp AGENTS.md CLAUDE.md
    AGENTS_PRESERVED=1
    warn "no provenance found; created CLAUDE.md from AGENTS.md"
  else
    # CLAUDE.md has its own content — back up AGENTS.md beside it.
    backup_agents
    AGENTS_PRESERVED=1
    warn "CLAUDE.md has its own content; backed up AGENTS.md → $AGENTS_BACKUP"
  fi
  if [ "$KEEP_AGENTS" != "1" ]; then
    # Only cc-suite-generated AGENTS.md files reach here, but init.sh directs
    # users to write into this file: delete it unread only when it still
    # matches what init generated.
    if [ "$AGENTS_PRESERVED" != "1" ] && ! agents_is_generated "$AGENTS_BODY_SOURCE"; then
      backup_agents
      warn "AGENTS.md was edited after cc-suite generated it; backed up → $AGENTS_BACKUP"
    fi
    rm AGENTS.md
    ok "removed AGENTS.md"
  fi
else
  skip "AGENTS.md not present"
fi

# GEMINI.md — remove only a still-pure @import. A cc-suite-created file the
# user has since edited is their content now; deleting it would lose edits.
if [ -f GEMINI.md ]; then
  if is_pure_import GEMINI.md; then
    rm GEMINI.md
    ok "removed GEMINI.md (@AGENTS.md import)"
  elif [ "$CC_SUITE_CREATED_GEMINI" = "1" ]; then
    skip "GEMINI.md was cc-suite-created but has been edited — left alone"
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

# Provenance — remove after we've consumed it, from both the current and legacy
# locations so a repo that predates the move is left fully clean. The original
# CLAUDE.md backup goes only once its restoration is verified above; otherwise
# it is moved beside CLAUDE.md, because it is the sole copy of that content and
# the path it sits on is one a later init.sh overwrites without asking.
for _p in "$PROVENANCE" "$LEGACY_PROVENANCE"; do
  if [ -f "$_p" ]; then
    rm "$_p"
  fi
done
for _p in "$ORIGINAL_CLAUDE" "$LEGACY_ORIGINAL_CLAUDE"; do
  if [ -f "$_p" ]; then
    if [ "$RESTORED_ORIGINAL" = "1" ]; then
      rm "$_p"
    else
      next_claude_backup
      if mv "$_p" "$CLAUDE_BACKUP"; then
        warn "original CLAUDE.md backup was not restored; preserved as $CLAUDE_BACKUP"
      else
        warn "original CLAUDE.md backup kept at $_p — it was not restored, and moving it to $CLAUDE_BACKUP failed"
        UNBRIDGE_FAILED=1
      fi
    fi
  fi
done
# Drop .cc-suite/ only when nothing else lives there — declared advisor agents
# under .cc-suite/agents/ are the user's, and outlive the bridge.
if [ -d .cc-suite ]; then
  rmdir .cc-suite 2>/dev/null || true
fi

# .agents/mcp_config.json — remove only the cc-suite-managed entries. A user
# config, user entries in a generated file, and sibling top-level keys are
# all preserved; the file is deleted only when nothing at all remains.
if [ -f .agents/.cc-suite-mcp.provenance.json ]; then
  if python3 - <<'PY'; then
import json, sys
from pathlib import Path

target = Path('.agents/mcp_config.json')
provenance = Path('.agents/.cc-suite-mcp.provenance.json')
try:
    meta = json.loads(provenance.read_text())
    managed = set(meta.get('managed_servers', []))
    if target.exists():
        data = json.loads(target.read_text())
        if not isinstance(data, dict) or not isinstance(data.get('mcpServers', {}), dict):
            # SystemExit(1) is a BaseException — it bypasses the broad handler
            # below, so the shell wrapper records the failure and unbridge does
            # not announce completion over an uncleaned config.
            print('! .agents/mcp_config.json has an unexpected shape — left alone (provenance kept)', file=sys.stderr)
            raise SystemExit(1)
        servers = data.get('mcpServers', {})
        remaining = {k: v for k, v in servers.items() if k not in managed}
        if remaining:
            data['mcpServers'] = remaining
        else:
            data.pop('mcpServers', None)
        if data:
            target.write_text(json.dumps(data, indent=2) + '\n')
            print('✓ .agents/mcp_config.json: removed cc-suite-managed servers')
        else:
            target.unlink()
            print('✓ removed .agents/mcp_config.json (cc-suite generated)')
    provenance.unlink()
    print('✓ removed .agents/.cc-suite-mcp.provenance.json')
except Exception as exc:
    print(f'! could not safely remove Antigravity MCP bridge: {exc}', file=sys.stderr)
    raise SystemExit(1)
PY
    :
  else
    warn "Antigravity MCP cleanup failed — .agents/ bridge artifacts left in place"
    UNBRIDGE_FAILED=1
  fi
elif [ -f .agents/mcp_config.json ]; then
  skip ".agents/mcp_config.json has no cc-suite provenance — left alone"
fi

# Registry-bridged tools (grok / opencode / qwen / kimi) — remove cc-suite MCP
# blocks/entries from each tool's config, preserving user-managed servers and
# sibling keys. The engine owns the per-tool paths and provenance.
if ! python3 "${SCRIPT_DIR}/bridge_tools.py" --unbridge; then
  warn "tool-profile unbridge reported an issue — registry artifacts may remain"
  UNBRIDGE_FAILED=1
fi

# .agents/skills symlink only — never the .claude/skills/ target, and never a
# link the user pointed elsewhere (bridge_skills.sh refuses to overwrite those,
# so unbridge must not delete them either).
if [ -L .agents/skills ]; then
  _skills_target="$(readlink .agents/skills)"
  if [ "$_skills_target" = "../.claude/skills" ]; then
    rm .agents/skills
    ok "removed .agents/skills symlink"
    rmdir .agents 2>/dev/null && ok "removed empty .agents/" || true
  else
    skip ".agents/skills points to ${_skills_target} — not cc-suite-owned, left alone"
  fi
else
  skip ".agents/skills not a symlink"
fi

# .codex/prompts — only if empty of real content.
if [ -d .codex/prompts ] && [ -z "$(ls -A .codex/prompts 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
  rm -rf .codex/prompts && ok "removed empty .codex/prompts/"
else
  skip ".codex/prompts/ non-empty or missing"
fi

# .codex/hooks.json — only if it carries the exact bridge marker and shape.
if [ -f .codex/hooks.json ]; then
  if is_bridge_hooks_file .codex/hooks.json; then
    rm .codex/hooks.json && ok "removed .codex/hooks.json (cc-suite generated)"
  else
    skip ".codex/hooks.json has non-bridge events or is non-standard — left alone"
  fi
fi
# Same test for the side file: a user who replaced it owns it now.
if [ -f .codex/hooks.cc-suite.json ]; then
  if is_bridge_hooks_file .codex/hooks.cc-suite.json; then
    rm .codex/hooks.cc-suite.json && ok "removed .codex/hooks.cc-suite.json"
  else
    skip ".codex/hooks.cc-suite.json is not cc-suite-generated — left alone"
  fi
fi

# .codex/config.toml — strip the cc-suite sentinel blocks; delete the whole
# file only when init.sh created it AND the non-sentinel remainder still
# matches the init template exactly (i.e. it has not been hand-edited since).
if [ -f .codex/config.toml ]; then
  if ! python3 - <<'PY'; then
import sys
from pathlib import Path
# Both cc-suite-owned sentinel blocks: MCP mirror (bridge_mcp.sh) and the
# claude-octopus registration (mcp_claude.sh).
BLOCKS = [
    ("# >>> cc-suite-mcp >>>", "# <<< cc-suite-mcp <<<"),
    ("# >>> cc-suite-claude-mcp >>>", "# <<< cc-suite-claude-mcp <<<"),
]
INIT_MARKER = "# cc-suite: generated-by-init"
# Must match the CFG heredoc in init.sh verbatim.
INIT_TEMPLATE = """\
# cc-suite: generated-by-init  (this comment is consumed by unbridge)
# Codex CLI configuration for this project.
# See: https://developers.openai.com/codex/config-reference

# Uncomment to also read CLAUDE.md as a fallback instruction source:
# project_doc_fallback_filenames = ["CLAUDE.md"]

# MCP servers mirrored from .mcp.json are added below by /cc-suite:bridge-mcp.
"""
p = Path(".codex/config.toml")
text = p.read_text(encoding="utf-8")

# Validate every managed block before rewriting anything: a duplicated,
# unpaired, out-of-order, or overlapping marker pair means the file no longer
# looks like what cc-suite wrote, and slicing it would corrupt the rest of the
# config.
#
# Spans are resolved against the ORIGINAL text and removed right-to-left. Both
# halves matter: computing offsets per iteration against a text the previous
# iteration already mutated meant that removing one block could swallow the
# opening marker of an interleaved one, after which find() returned -1 and the
# slice silently duplicated the tail into the file.
spans = []
for s_marker, e_marker in BLOCKS:
    opens = text.count(s_marker)
    closes = text.count(e_marker)
    if opens == 0 and closes == 0:
        continue
    start = text.find(s_marker)
    end = text.find(e_marker)
    if opens != 1 or closes != 1 or end < start:
        print(
            f"! .codex/config.toml: {s_marker} block is duplicated, unpaired, or out of "
            f"order (opens={opens}, closes={closes}) — left alone",
            file=sys.stderr,
        )
        raise SystemExit(1)
    nl = text.find("\n", end)
    spans.append((start, len(text) if nl == -1 else nl + 1))

spans.sort()
for (first_start, first_end), (second_start, _) in zip(spans, spans[1:]):
    if second_start < first_end:
        print(
            "! .codex/config.toml: cc-suite sentinel blocks are nested or interleaved "
            "— left alone",
            file=sys.stderr,
        )
        raise SystemExit(1)

cleaned = text
removed_any = False
for start, end in reversed(spans):
    tail = cleaned[end:]
    cleaned = cleaned[:start].rstrip("\n") + ("\n" + tail if tail else "")
    removed_any = True
if cleaned.strip() == INIT_TEMPLATE.strip():
    # Unedited init output (the exact-template match implies the init marker):
    # safe to delete outright.
    p.unlink()
    print("✓ removed .codex/config.toml (cc-suite-generated, unedited)")
elif removed_any:
    if cleaned.strip():
        p.write_text(cleaned + "\n", encoding="utf-8")
        print("✓ .codex/config.toml: removed cc-suite sentinel block(s)")
    else:
        p.unlink()
        print("✓ removed .codex/config.toml (only contained cc-suite blocks)")
elif INIT_MARKER in cleaned:
    print("· .codex/config.toml was created by init but has been edited — left alone")
else:
    print("· .codex/config.toml has no cc-suite markers — left alone")
PY
    warn ".codex/config.toml cleanup failed — sentinel blocks left in place"
    UNBRIDGE_FAILED=1
  fi
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
  if ! python3 - <<'PY'; then
import sys
from pathlib import Path
OPEN_MARKER  = "# >>> cc-suite >>>"
CLOSE_MARKER = "# <<< cc-suite <<<"
text = Path(".gitignore").read_text()
start = text.find(OPEN_MARKER)
end   = text.find(CLOSE_MARKER)
# One correctly ordered pair, or nothing is rewritten: overlapping slices from
# duplicated or reversed markers would duplicate or destroy unrelated rules.
if text.count(OPEN_MARKER) != 1 or text.count(CLOSE_MARKER) != 1 or end < start:
    print(
        "! .gitignore: cc-suite markers are duplicated, unpaired, or out of order "
        "— left alone",
        file=sys.stderr,
    )
    raise SystemExit(1)
nl = text.find("\n", end)
end_line = nl + 1 if nl != -1 else len(text)
new = text[:start].rstrip() + "\n" + text[end_line:]
Path(".gitignore").write_text(new.lstrip("\n"))
print("✓ removed cc-suite block from .gitignore")
PY
    warn ".gitignore cleanup failed — cc-suite block left in place"
    UNBRIDGE_FAILED=1
  fi
fi

echo
if [ "$UNBRIDGE_FAILED" = "1" ]; then
  warn "cc-suite unbridge finished with errors — see messages above."
  exit 1
fi
ok "cc-suite unbridge complete. .mcp.json and .claude/ are left alone."
