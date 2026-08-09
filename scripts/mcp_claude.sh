#!/usr/bin/env bash
# cc-suite: add (or refresh) the claude-octopus MCP server in .codex/config.toml.
#
# claude-octopus wraps the Anthropic Claude Agent SDK and exposes claude_code /
# claude_code_reply tools so Codex can delegate tasks back to Claude, plus
# claude_code_sessions / claude_code_transcript so Codex can list and read
# Claude Code's session history for the repo.
#
# The pinned version lives in scripts/lib/claude-octopus-pin.txt — single source
# of truth, also read by the boot-handshake test and the integration suite.
# Override at runtime with CC_SUITE_CLAUDE_MCP_VERSION=<version> for testing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_FILE="${SCRIPT_DIR}/lib/claude-octopus-pin.txt"

if [ -z "${CC_SUITE_CLAUDE_MCP_VERSION:-}" ]; then
  if [ ! -f "$PIN_FILE" ]; then
    printf '! pin file missing: %s\n' "$PIN_FILE" >&2
    exit 1
  fi
  CC_SUITE_CLAUDE_MCP_VERSION="$(tr -d '[:space:]' < "$PIN_FILE")"
fi

ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '· %s\n' "$*"; }
die()  { printf '! %s\n' "$*" >&2; exit 1; }

# Guard the pin before it is interpolated into TOML: it must be an exact
# semantic version, not merely a string of allowed characters — `latest`,
# `1.2`, `01.2.3`, or `1.2.3-alpha..1` would defeat the pinning contract while
# passing a looser check. This is semver.org's official grammar, the same one
# scripts/lib/pin.py enforces for the Python consumers of the pin. Matched with
# bash's `=~` rather than grep because grep is line-oriented: a value carrying
# a newline would pass on its first line and smuggle the rest into the TOML.
EXACT_SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [[ ! $CC_SUITE_CLAUDE_MCP_VERSION =~ $EXACT_SEMVER_RE ]]; then
  die "invalid claude-octopus version pin: '${CC_SUITE_CLAUDE_MCP_VERSION}' (expected an exact semver, e.g. 1.2.3)"
fi

# Ensure .codex/ exists — mcp_codex.sh / init.sh should have run first, but
# guard defensively so this script can also be called standalone.
if [ ! -d .codex ]; then
  mkdir -p .codex
fi

TOML=".codex/config.toml"

# Every mutation below writes a same-directory temp file and renames it into
# place, which forces two things to be handled explicitly:
#
#   - a rename onto a symlink replaces the link with a regular file and leaves
#     the real config unwritten, so writes must target the link's destination
#     (Nix/home-manager, chezmoi and stow all link .codex/config.toml);
#   - mktemp creates the temp at 0600, so the destination's mode has to be
#     applied AFTER the content is written — copying it beforehand makes a
#     read-only destination's own mode deny the write that follows.
TOML_TARGET="$TOML"
if [ -L "$TOML" ]; then
  TOML_TARGET="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$TOML")"
  [ -d "$(dirname "$TOML_TARGET")" ] \
    || die "$TOML links to $TOML_TARGET, whose directory does not exist — repair the link, then re-run"
fi

# Permission bits of an existing file, as four octal digits chmod accepts.
file_mode() {
  python3 -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o7777, "04o"))' "$1"
}

# What a plain `> file` would have created: 0666 masked by the umask.
new_file_mode() { printf '%04o\n' "$(( 0666 & ~0$(umask) ))"; }

# Sentinel used inside config.toml to guard the claude-code block.
SENTINEL_OPEN="# >>> cc-suite-claude-mcp >>>"
SENTINEL_CLOSE="# <<< cc-suite-claude-mcp <<<"
PIN_MARKER="claude-octopus@${CC_SUITE_CLAUDE_MCP_VERSION}"

# ── build the canonical TOML block ───────────────────────────────────────────
BLOCK="$(cat <<TOML
${SENTINEL_OPEN}
[mcp_servers.claude-code]
command = "npx"
args    = ["-y", "${PIN_MARKER}"]
env     = {}
# Codex default tool_timeout_sec is too short for claude_code calls: a
# single multi-turn agent invocation can run several minutes, so 900s
# matches the forward-direction codex-runner deadline. startup_timeout_sec
# covers cold-cache npx -y downloads on first launch.
startup_timeout_sec = 60
tool_timeout_sec    = 900
${SENTINEL_CLOSE}
TOML
)"

# ── idempotency / freshen check ──────────────────────────────────────────────
# Four cases:
#   1. Sentinel block found AND body matches the canonical one → skip (no-op)
#   2. Sentinel block found AND body differs in any way        → rewrite
#   3. Sentinel absent  AND user-managed [mcp_servers.claude-code] present
#                                                              → skip with warning
#   4. Sentinel absent  AND no claude-code block at all         → append
if [ -f "$TOML" ]; then
  # Whole-line matching (-x) throughout, because the awk extraction and removal
  # below compare `$0 == sentinel`. Substring detection here would recognise an
  # indented or suffixed marker that awk then refuses to strip, and the append
  # that follows would leave two [mcp_servers.claude-code] tables — invalid
  # TOML. A marker awk cannot match is treated as no marker at all, which lands
  # in the user-managed branch below and leaves the file alone.
  if grep -qxF "$SENTINEL_OPEN" "$TOML" || grep -qxF "$SENTINEL_CLOSE" "$TOML"; then
    # Require exactly one balanced, ordered sentinel pair before editing: an
    # unmatched opener would make the rewrite awk below discard everything
    # from the opener to EOF, and duplicate markers would splice user content.
    open_n="$(grep -cxF "$SENTINEL_OPEN" "$TOML" || true)"
    close_n="$(grep -cxF "$SENTINEL_CLOSE" "$TOML" || true)"
    if [ "$open_n" != "1" ] || [ "$close_n" != "1" ]; then
      die "$TOML cc-suite-claude-mcp sentinel markers are unbalanced or duplicated (open=$open_n close=$close_n) — repair by hand, then re-run"
    fi
    open_line="$(grep -nxF "$SENTINEL_OPEN" "$TOML" | head -n1 | cut -d: -f1)"
    close_line="$(grep -nxF "$SENTINEL_CLOSE" "$TOML" | head -n1 | cut -d: -f1)"
    if [ "$open_line" -gt "$close_line" ]; then
      die "$TOML cc-suite-claude-mcp sentinel markers are out of order — repair by hand, then re-run"
    fi

    # Extract the sentinel block and check whether it already pins the current
    # version. Doing this with awk keeps macOS/Linux behavior identical.
    current_block="$(awk -v sopen="$SENTINEL_OPEN" -v sclose="$SENTINEL_CLOSE" '
      $0 == sopen  { capture=1 }
      capture      { print }
      $0 == sclose { capture=0 }
    ' "$TOML")"

    # cc-suite generates this block whole, so the only up-to-date state is a
    # verbatim match against the canonical definition. Searching for the pin
    # and the string `tool_timeout_sec` instead would accept a block whose
    # comments carry both while its command, args, table, or timeout values are
    # stale or malformed.
    if [ "$current_block" = "$BLOCK" ]; then
      skip "$TOML already pins ${PIN_MARKER}"
      exit 0
    fi

    # Pin moved (or block is malformed) — rewrite in place. Same-directory
    # temp files + a final rename keep the destination complete at all times;
    # the EXIT trap cleans up if anything fails midway.
    stripped="$(mktemp "${TOML_TARGET}.XXXXXX")"
    newfile="$(mktemp "${TOML_TARGET}.XXXXXX")"
    trap 'rm -f "$stripped" "$newfile"' EXIT
    mode="$(file_mode "$TOML_TARGET")"
    # Delete the sentinel block (inclusive) and one immediately-following
    # blank separator line, if present. Leaves the rest of the file untouched.
    awk -v sopen="$SENTINEL_OPEN" -v sclose="$SENTINEL_CLOSE" '
      $0 == sopen                       { skip=1; next }
      $0 == sclose                      { skip=0; trailing_blank=1; next }
      skip                              { next }
      trailing_blank && /^[[:space:]]*$/ { trailing_blank=0; next }
      { trailing_blank=0; print }
    ' "$TOML" > "$stripped"

    {
      cat "$stripped"
      [ -s "$stripped" ] && printf '\n'
      printf '%s\n' "$BLOCK"
    } > "$newfile"
    chmod "$mode" "$newfile"
    mv -f "$newfile" "$TOML_TARGET"
    rm -f "$stripped"
    ok "$TOML: claude-code MCP server refreshed (now pinned @${CC_SUITE_CLAUDE_MCP_VERSION})"
    exit 0
  fi

  # No sentinel — but does a user-managed claude-code registration exist?
  # A structural scan (not a single header regex) so every TOML spelling is
  # recognized: quoted root or key segments, whitespace around dots, trailing
  # comments, sub-table headers ([mcp_servers.claude-code.env]), and dotted-key
  # assignments (`claude-code.command = ...` under [mcp_servers], or a fully
  # dotted `mcp_servers.claude-code = {...}` at top level).
  if python3 - "$TOML" <<'PY'
import re, sys

KEY_TOKEN = r'"(?:[^"\\]|\\.)*"|\'[^\']*\'|[A-Za-z0-9_-]+'


def unquote(tok: str) -> str:
    tok = tok.strip()
    if len(tok) >= 2 and tok[0] == tok[-1] == "'":
        return tok[1:-1]
    if len(tok) >= 2 and tok[0] == tok[-1] == '"':
        return re.sub(r"\\(.)", r"\1", tok[1:-1])
    return tok


def key_parts(s: str) -> list:
    return [unquote(t) for t in re.findall(KEY_TOKEN, s)]


text = open(sys.argv[1], encoding="utf-8").read()
TARGET = ["mcp_servers", "claude-code"]
current: list = []
for raw in text.splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    header = re.match(r"^\[(?!\[)\s*(.+?)\s*\]\s*(?:#.*)?$", line)
    if header:
        current = key_parts(header.group(1))
        if current[:2] == TARGET:
            sys.exit(0)
        continue
    assign = re.match(
        r"^((?:%(tok)s)(?:\s*\.\s*(?:%(tok)s))*)\s*=" % {"tok": KEY_TOKEN}, line
    )
    if assign and (current + key_parts(assign.group(1)))[:2] == TARGET:
        sys.exit(0)
sys.exit(1)
PY
  then
    skip "$TOML already registers [mcp_servers.claude-code] (not cc-suite-managed) — leaving it alone"
    skip "  to let cc-suite manage it, remove the existing block and re-run /cc-suite:repair"
    exit 0
  fi
fi

# ── append a fresh block ─────────────────────────────────────────────────────
# Same-directory temp + rename here too, so every mutation path leaves the
# destination either untouched or complete. A direct append interrupted midway
# would leave a half-written sentinel block, and the balance check above then
# refuses to repair it automatically.
newfile="$(mktemp "${TOML_TARGET}.XXXXXX")"
trap 'rm -f "$newfile"' EXIT
if [ -f "$TOML" ]; then
  mode="$(file_mode "$TOML_TARGET")"
  {
    cat "$TOML"
    printf '\n'
    printf '%s\n' "$BLOCK"
  } > "$newfile"
  chmod "$mode" "$newfile"
  mv -f "$newfile" "$TOML_TARGET"
  ok "$TOML: claude-code MCP server appended (pinned @${CC_SUITE_CLAUDE_MCP_VERSION})"
else
  printf '%s\n' "$BLOCK" > "$newfile"
  chmod "$(new_file_mode)" "$newfile"
  mv -f "$newfile" "$TOML_TARGET"
  ok "$TOML created with claude-code MCP server (pinned @${CC_SUITE_CLAUDE_MCP_VERSION})"
fi
