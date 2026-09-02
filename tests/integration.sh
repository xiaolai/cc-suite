#!/usr/bin/env bash
# tests/integration.sh — integration tests for cc-suite scripts.
# Run from any directory: bash tests/integration.sh
# Or from repo root:     bash tests/integration.sh

set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
PASS=0
FAIL=0
declare -a ERRORS=()

# ── colours ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  G='\033[0;32m'; R='\033[0;31m'; B='\033[1;34m'; N='\033[0m'
else
  G=''; R=''; B=''; N=''
fi

# ── assert helpers ───────────────────────────────────────────────────────────
# Arithmetic assignment, not ((PASS++)): under `set -e` a post-increment from 0
# evaluates to 0, which bash reports as exit status 1 — so the suite aborted on
# its first *passing* assertion and never reached T02.
ok_msg()   { PASS=$((PASS + 1)); printf "${G}  ✓${N} %s\n" "$*"; }
fail_msg() { FAIL=$((FAIL + 1)); ERRORS+=("$*"); printf "${R}  ✗${N} %s\n" "$*"; }
section()  { printf "\n${B}%s${N}\n" "$*"; }

assert_file() {
  if [ -f "$1" ]; then ok_msg "file exists: $1"
  else                  fail_msg "MISSING file: $1"; fi
}
assert_no_file() {
  if [ ! -f "$1" ]; then ok_msg "file absent: $1"
  else                   fail_msg "UNEXPECTED file: $1"; fi
}
assert_dir() {
  if [ -d "$1" ]; then ok_msg "dir exists: $1"
  else                 fail_msg "MISSING dir: $1"; fi
}
assert_no_dir() {
  if [ ! -d "$1" ]; then ok_msg "dir absent: $1"
  else                   fail_msg "UNEXPECTED dir: $1"; fi
}
assert_symlink() {
  if [ -L "$1" ]; then ok_msg "symlink exists: $1"
  else                 fail_msg "NOT a symlink: $1"; fi
}
assert_no_symlink() {
  if [ ! -L "$1" ]; then ok_msg "no symlink at: $1"
  else                   fail_msg "UNEXPECTED symlink: $1"; fi
}
assert_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then ok_msg "contains '$2': $1"
  else                                    fail_msg "MISSING '$2' in $1"; fi
}
assert_not_contains() {
  if ! grep -qF -- "$2" "$1" 2>/dev/null; then ok_msg "absent '$2': $1"
  else                                      fail_msg "UNEXPECTED '$2' in $1"; fi
}
assert_symlink_target() {
  local link="$1" want="$2"
  local got
  got="$(readlink "$link" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then ok_msg "symlink target: $link → $want"
  else                          fail_msg "WRONG target: $link → '$got' (want '$want')"; fi
}
assert_file_content() {
  # Compares trimmed content (command substitution strips trailing newlines).
  local file="$1" want="$2"
  local got
  got="$(cat "$1" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then ok_msg "content ok: $file"
  else fail_msg "WRONG content in $file — want '$(printf '%s' "$want" | head -1)' got '$(printf '%s' "$got" | head -1)'"; fi
}
assert_exit0() {
  # Run command, assert it exits 0.
  if "$@" >/dev/null 2>&1; then ok_msg "exit 0: $*"
  else                          fail_msg "NONZERO exit: $*"; fi
}
assert_exit_nonzero() {
  # Run command, assert it exits non-0.
  if ! "$@" >/dev/null 2>&1; then ok_msg "exit nonzero (expected): $*"
  else                            fail_msg "EXPECTED FAILURE but got exit 0: $*"; fi
}
assert_count() {
  # assert_count pattern file N  — grep -c pattern file == N
  local pat="$1" file="$2" want="$3"
  local got
  got="$(grep -cF "$pat" "$file" 2>/dev/null || true)"
  if [ "$got" = "$want" ]; then ok_msg "count($pat in $file) = $want"
  else                          fail_msg "count($pat in $file) = $got (want $want)"; fi
}

# ── temp dir management ───────────────────────────────────────────────────────
TMP=""
# Every test runs under an isolated HOME. Several scripts write machine-global
# targets (~/.kimi/mcp.json, ~/.codex/…), and a bare `bridge_tools.py --unbridge`
# iterates every registry profile — so without this a suite run could delete the
# developer's real Kimi configuration. Tests that need a specific HOME still
# override it per command.
REAL_HOME="$HOME"
make_tmp() {
  TMP="$(mktemp -d)"
  cd "$TMP"
  mkdir -p "$TMP/home"
  HOME="$TMP/home"
  export HOME
}
cleanup() {
  cd /
  rm -rf "${TMP:-}"
  TMP=""
  HOME="$REAL_HOME"
  export HOME
}

# ═══════════════════════════════════════════════════════════════════════════════
# T00  harness — every test runs under an isolated HOME
# ═══════════════════════════════════════════════════════════════════════════════
# The suite exercises scripts that write machine-global paths (~/.kimi/mcp.json,
# ~/.codex/…) and a teardown that iterates every registry profile. If HOME ever
# stops being redirected, a suite run silently destroys the developer's real
# configuration — so assert the redirection itself rather than trusting it.
section "T00: harness — HOME is isolated inside each test"
make_tmp
if [ "$HOME" != "$REAL_HOME" ]; then ok_msg "HOME redirected away from the real home"
else fail_msg "HOME is the developer's real home — a global-config test would destroy it"; fi
if [ "$HOME" = "$TMP/home" ] && [ -d "$HOME" ]; then ok_msg "HOME points at the per-test sandbox"
else fail_msg "HOME is not the per-test sandbox ($HOME)"; fi
cleanup
if [ "$HOME" = "$REAL_HOME" ]; then ok_msg "cleanup restores the real HOME"
else fail_msg "cleanup left HOME pointing at a deleted directory"; fi

# ═══════════════════════════════════════════════════════════════════════════════
# T01  init.sh — fresh project (no CLAUDE.md, no AGENTS.md)
# ═══════════════════════════════════════════════════════════════════════════════
section "T01: init.sh — fresh project"
make_tmp

bash "$SCRIPTS/init.sh" --description "Test Project" >/dev/null 2>&1

assert_file "AGENTS.md"
assert_contains "AGENTS.md" "Test Project"
assert_file_content "CLAUDE.md" "@AGENTS.md"
assert_dir  ".codex/prompts"
assert_file ".codex/prompts/.gitkeep"
assert_file ".codex/config.toml"
assert_file ".gitignore"
assert_contains ".gitignore" "# >>> cc-suite >>>"
assert_contains ".gitignore" "# <<< cc-suite <<<"
assert_file ".cc-suite/provenance"
assert_contains ".cc-suite/provenance" "CC_SUITE_CREATED_CLAUDE=1"

# Consumer Gemini CLI access moved to `agy` on 2026-06-18; agy reads AGENTS.md
# natively. init must no longer create a GEMINI.md pointer or .gemini/ scaffolding.
assert_no_file "GEMINI.md"
assert_no_dir  ".gemini"
assert_not_contains ".cc-suite/provenance" "CC_SUITE_CREATED_GEMINI"
assert_not_contains ".gitignore" ".gemini/"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T02  init.sh — migrate existing CLAUDE.md
# ═══════════════════════════════════════════════════════════════════════════════
section "T02: init.sh — migrate existing CLAUDE.md"
make_tmp

printf "# My Project\n\nHello world.\n" > CLAUDE.md
assert_exit0 bash "$SCRIPTS/init.sh"

assert_file "AGENTS.md"
assert_contains "AGENTS.md" "# My Project"
assert_contains "AGENTS.md" "Hello world."
assert_file_content "CLAUDE.md" "@AGENTS.md"
# Original saved verbatim for perfect restore
assert_file ".cc-suite/original-claude.md"
assert_contains ".cc-suite/original-claude.md" "# My Project"
assert_contains ".cc-suite/provenance" "CLAUDE_MIGRATED=1"
# CLAUDE_MIGRATED migration means CC_SUITE_CREATED_CLAUDE should NOT be set
assert_not_contains ".cc-suite/provenance" "CC_SUITE_CREATED_CLAUDE=1"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T03  init.sh — skip pure @AGENTS.md CLAUDE.md (already bridged)
# ═══════════════════════════════════════════════════════════════════════════════
section "T03: init.sh — skip pure @AGENTS.md CLAUDE.md"
make_tmp

printf "@AGENTS.md\n" > CLAUDE.md
assert_exit0 bash "$SCRIPTS/init.sh"

# Fresh AGENTS.md should be created (no migration)
assert_file "AGENTS.md"
assert_not_contains "AGENTS.md" "Hello"   # no CLAUDE.md body leaked in
# CLAUDE.md untouched
assert_file_content "CLAUDE.md" "@AGENTS.md"
# No migration flag
assert_not_contains ".cc-suite/provenance" "CLAUDE_MIGRATED=1"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T04  init.sh — skip hybrid CLAUDE.md (@AGENTS.md + other content)
# ═══════════════════════════════════════════════════════════════════════════════
section "T04: init.sh — skip hybrid CLAUDE.md"
make_tmp

printf "@AGENTS.md\n\n# Extra content that must survive\n" > CLAUDE.md
assert_exit0 bash "$SCRIPTS/init.sh"

# Hybrid should be left alone (not overwritten with @AGENTS.md)
assert_contains "CLAUDE.md" "# Extra content that must survive"
assert_contains "CLAUDE.md" "@AGENTS.md"
# No migration
assert_not_contains ".cc-suite/provenance" "CLAUDE_MIGRATED=1"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T05  init.sh — idempotent re-run
# ═══════════════════════════════════════════════════════════════════════════════
section "T05: init.sh — idempotent re-run"
make_tmp

assert_exit0 bash "$SCRIPTS/init.sh"
hash1="$(md5 -q AGENTS.md 2>/dev/null || md5sum AGENTS.md | awk '{print $1}')"

assert_exit0 bash "$SCRIPTS/init.sh"
hash2="$(md5 -q AGENTS.md 2>/dev/null || md5sum AGENTS.md | awk '{print $1}')"

if [ "$hash1" = "$hash2" ]; then ok_msg "AGENTS.md unchanged on re-run"
else                              fail_msg "AGENTS.md changed on re-run"; fi

assert_count "# >>> cc-suite >>>" ".gitignore" 1

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T06  init.sh — --private mode sets gitignore block
# ═══════════════════════════════════════════════════════════════════════════════
section "T06: init.sh — --private mode"
make_tmp

bash "$SCRIPTS/init.sh" --private >/dev/null 2>&1

assert_contains ".gitignore" "cc-suite: PRIVATE mode"
assert_contains ".gitignore" "AGENTS.md"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T07  init.sh — --private mode change replaces sentinel block cleanly
# ═══════════════════════════════════════════════════════════════════════════════
section "T07: init.sh — switching --private mode replaces block"
make_tmp

assert_exit0 bash "$SCRIPTS/init.sh"           # public mode
assert_not_contains ".gitignore" "cc-suite: PRIVATE mode"

bash "$SCRIPTS/init.sh" --private >/dev/null 2>&1 # switch to private
assert_contains ".gitignore" "cc-suite: PRIVATE mode"
assert_count "# >>> cc-suite >>>" ".gitignore" 1  # no duplicate blocks

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T08  bridge_skills.sh — creates .agents/skills → .claude/skills symlink
# ═══════════════════════════════════════════════════════════════════════════════
section "T08: bridge_skills.sh — creates symlink"
make_tmp

mkdir -p .claude/skills/my-skill
echo "# My Skill" > .claude/skills/my-skill/SKILL.md

assert_exit0 bash "$SCRIPTS/bridge_skills.sh"

assert_symlink       ".agents/skills"
assert_symlink_target ".agents/skills" "../.claude/skills"
assert_file          ".agents/skills/my-skill/SKILL.md"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T09  bridge_skills.sh — idempotent re-run
# ═══════════════════════════════════════════════════════════════════════════════
section "T09: bridge_skills.sh — idempotent"
make_tmp

mkdir -p .claude/skills
assert_exit0 bash "$SCRIPTS/bridge_skills.sh"
assert_exit0 bash "$SCRIPTS/bridge_skills.sh"
assert_symlink ".agents/skills"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T10  bridge_skills.sh — refuses to replace a real directory
# ═══════════════════════════════════════════════════════════════════════════════
section "T10: bridge_skills.sh — refuses to overwrite real .agents/skills/"
make_tmp

mkdir -p .agents/skills .claude/skills
assert_exit_nonzero bash "$SCRIPTS/bridge_skills.sh"
assert_no_symlink ".agents/skills"   # still a real dir, not converted to symlink

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T11  bridge_hooks.py — mirrors shared events, skips Claude-only events
# ═══════════════════════════════════════════════════════════════════════════════
section "T11: bridge_hooks.py — mirrors SessionStart, skips Notification"
make_tmp
mkdir -p .claude

cat > .claude/settings.json <<'JSON'
{
  "hooks": {
    "SessionStart":    [{"hooks": [{"type": "command", "command": "echo start"}]}],
    "UserPromptSubmit":[{"hooks": [{"type": "command", "command": "echo prompt"}]}],
    "PreToolUse":      [{"hooks": [{"type": "command", "command": "echo pre"}]}],
    "Notification":    [{"hooks": [{"type": "command", "command": "echo notify"}]}],
    "SessionEnd":      [{"hooks": [{"type": "command", "command": "echo end"}]}]
  }
}
JSON

assert_exit0 python3 "$SCRIPTS/bridge_hooks.py"

assert_file ".codex/hooks.json"
assert_contains     ".codex/hooks.json" '"_cc_bridge_version"'
assert_contains     ".codex/hooks.json" '"SessionStart"'
assert_contains     ".codex/hooks.json" '"UserPromptSubmit"'
assert_contains     ".codex/hooks.json" '"PreToolUse"'
assert_not_contains ".codex/hooks.json" '"Notification"'
assert_not_contains ".codex/hooks.json" '"SessionEnd"'

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T12  bridge_hooks.py — existing hooks.json → writes .cc-suite.json instead
# ═══════════════════════════════════════════════════════════════════════════════
section "T12: bridge_hooks.py — doesn't overwrite existing hooks.json"
make_tmp
mkdir -p .claude .codex

echo '{"user_hooks": true}' > .codex/hooks.json

cat > .claude/settings.json <<'JSON'
{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo hi"}]}]}}
JSON

assert_exit0 python3 "$SCRIPTS/bridge_hooks.py"

assert_file    ".codex/hooks.cc-suite.json"
assert_file_content ".codex/hooks.json" '{"user_hooks": true}'  # original unchanged
assert_contains ".codex/hooks.cc-suite.json" '"SessionStart"'
assert_contains ".codex/hooks.cc-suite.json" '"_cc_bridge_version"'

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T13  bridge_mcp.sh — mirrors servers, skips codex-cli
# ═══════════════════════════════════════════════════════════════════════════════
section "T13: bridge_mcp.sh — mirrors servers, skips codex-cli"
make_tmp
mkdir -p .codex
echo "# existing config" > .codex/config.toml

cat > .mcp.json <<'JSON'
{
  "mcpServers": {
    "codex-cli":  {"type": "stdio", "command": "codex", "args": ["mcp-server"]},
    "my-server":  {"type": "stdio", "command": "npx", "args": ["-y", "my-pkg"]},
    "sse-server": {"type": "sse",   "url": "https://example.com/sse"}
  }
}
JSON

assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"

assert_contains     ".codex/config.toml" "[mcp_servers.my-server]"
assert_contains     ".codex/config.toml" "command = \"npx\""
assert_contains     ".codex/config.toml" "[mcp_servers.sse-server]"
assert_contains     ".codex/config.toml" "url = \"https://example.com/sse\""
assert_not_contains ".codex/config.toml" "[mcp_servers.codex-cli]"
assert_contains     ".codex/config.toml" "# >>> cc-suite-mcp >>>"
assert_contains     ".codex/config.toml" "# <<< cc-suite-mcp <<<"
# Original config preserved outside the sentinel block
assert_contains     ".codex/config.toml" "# existing config"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T14  bridge_mcp.sh — normalizes names to Codex's server-name grammar
# ═══════════════════════════════════════════════════════════════════════════════
section "T14: bridge_mcp.sh — normalizes names with special characters"
make_tmp
mkdir -p .codex
echo "# empty" > .codex/config.toml

cat > .mcp.json <<'JSON'
{
  "mcpServers": {
    "my.server":                         {"type": "stdio", "command": "cmd1"},
    "@hypothesi/tauri-mcp-server":       {"type": "stdio", "command": "cmd2"},
    "plain-server":                       {"type": "stdio", "command": "cmd3"}
  }
}
JSON

assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"

assert_contains     ".codex/config.toml" '[mcp_servers.my-server]'
assert_contains     ".codex/config.toml" '[mcp_servers.hypothesi-tauri-mcp-server]'
assert_contains     ".codex/config.toml" '[mcp_servers.plain-server]'
assert_contains     ".codex/config.toml" '# Claude MCP name: my.server'
assert_not_contains ".codex/config.toml" '[mcp_servers."my.server"]'
assert_not_contains ".codex/config.toml" '[mcp_servers."@hypothesi/tauri-mcp-server"]'

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T15  bridge_mcp.sh — env vars replaced with TOML comments (no secret leak)
# ═══════════════════════════════════════════════════════════════════════════════
section "T15: bridge_mcp.sh — env secrets not written to config.toml"
make_tmp
mkdir -p .codex
echo "# empty" > .codex/config.toml

cat > .mcp.json <<'JSON'
{
  "mcpServers": {
    "secret-srv": {
      "type": "stdio",
      "command": "cmd",
      "env": {"MY_API_KEY": "super-secret", "ANOTHER_VAR": "also-secret"}
    }
  }
}
JSON

assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"

assert_contains     ".codex/config.toml" "[mcp_servers.secret-srv]"
assert_not_contains ".codex/config.toml" "super-secret"     # literal value must not appear
assert_not_contains ".codex/config.toml" "also-secret"
assert_contains     ".codex/config.toml" "MY_API_KEY"       # name appears in comment
assert_contains     ".codex/config.toml" "ANOTHER_VAR"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T16  bridge_mcp.sh — idempotent re-run (no duplication)
# ═══════════════════════════════════════════════════════════════════════════════
section "T16: bridge_mcp.sh — idempotent re-run"
make_tmp
mkdir -p .codex
echo "# base config" > .codex/config.toml

cat > .mcp.json <<'JSON'
{"mcpServers": {"srv": {"type": "stdio", "command": "cmd"}}}
JSON

assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"
assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"

assert_count "[mcp_servers.srv]" ".codex/config.toml" 1

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T17  bridge_mcp.sh — half-sentinel guard (one marker present, one missing)
# ═══════════════════════════════════════════════════════════════════════════════
section "T17: bridge_mcp.sh — refuses to run when only one sentinel marker present"
make_tmp
mkdir -p .codex

# Simulate a botched previous run that left only the start marker
cat > .codex/config.toml <<'TOML'
# >>> cc-suite-mcp >>>
[mcp_servers.orphan]
command = "cmd"
TOML

cat > .mcp.json <<'JSON'
{"mcpServers": {"new-server": {"type": "stdio", "command": "cmd2"}}}
JSON

assert_exit_nonzero bash "$SCRIPTS/bridge_mcp.sh"
# The broken config should not have been modified
assert_not_contains ".codex/config.toml" "[mcp_servers.new-server]"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T18  bridge_commands.sh — converts .claude/commands/ to Claude skills
# ═══════════════════════════════════════════════════════════════════════════════
section "T18: bridge_commands.sh — converts commands to skills"
make_tmp
mkdir -p .claude/commands

cat > .claude/commands/review.md <<'MD'
---
description: Run a code review on the changed files.
---

# Review

Do a thorough code review.
MD

assert_exit0 bash "$SCRIPTS/bridge_commands.sh"

assert_file ".claude/skills/cmd-review/SKILL.md"
assert_file ".claude/skills/cmd-review/agents/openai.yaml"
assert_contains ".claude/skills/cmd-review/SKILL.md" "cmd-review"
assert_contains ".claude/skills/cmd-review/SKILL.md" "Do a thorough code review."
assert_contains ".claude/skills/cmd-review/agents/openai.yaml" "allow_implicit_invocation: false"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T19  bridge_commands.sh — YAML-escapes description with special chars
# ═══════════════════════════════════════════════════════════════════════════════
section "T19: bridge_commands.sh — safely quotes special chars in description"
make_tmp
mkdir -p .claude/commands

cat > .claude/commands/tricky.md <<'MD'
---
description: Handle "quoted" values & special: chars.
---
Body.
MD

assert_exit0 bash "$SCRIPTS/bridge_commands.sh"

assert_file ".claude/skills/cmd-tricky/SKILL.md"
# Description line must be quoted YAML (starts with double-quote)
if grep -qE '^description: "' ".claude/skills/cmd-tricky/SKILL.md"; then
  ok_msg "description is quoted YAML scalar"
else
  fail_msg "description with special chars should be quoted in YAML"
fi

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T20  bridge_commands.sh — idempotent
# ═══════════════════════════════════════════════════════════════════════════════
section "T20: bridge_commands.sh — idempotent re-run"
make_tmp
mkdir -p .claude/commands
cat > .claude/commands/foo.md <<'MD'
---
description: Foo.
---
Body.
MD

assert_exit0 bash "$SCRIPTS/bridge_commands.sh"
hash1="$(md5 -q .claude/skills/cmd-foo/SKILL.md 2>/dev/null || md5sum .claude/skills/cmd-foo/SKILL.md | awk '{print $1}')"

assert_exit0 bash "$SCRIPTS/bridge_commands.sh"
hash2="$(md5 -q .claude/skills/cmd-foo/SKILL.md 2>/dev/null || md5sum .claude/skills/cmd-foo/SKILL.md | awk '{print $1}')"

if [ "$hash1" = "$hash2" ]; then ok_msg "SKILL.md unchanged on re-run"
else                              fail_msg "SKILL.md changed on re-run"; fi

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T21  mcp_codex.sh — adds codex-cli to .mcp.json
# ═══════════════════════════════════════════════════════════════════════════════
section "T21: mcp_codex.sh — adds codex-cli server"
make_tmp

cat > .mcp.json <<'JSON'
{"mcpServers": {"other": {"type": "stdio", "command": "cmd"}}}
JSON

assert_exit0 bash "$SCRIPTS/mcp_codex.sh"

assert_contains ".mcp.json" '"codex-cli"'
assert_contains ".mcp.json" '"other"'    # original preserved

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T22  mcp_codex.sh — idempotent when codex-cli already registered
# ═══════════════════════════════════════════════════════════════════════════════
section "T22: mcp_codex.sh — idempotent"
make_tmp

cat > .mcp.json <<'JSON'
{"mcpServers": {"codex-cli": {"type": "stdio", "command": "codex", "args": ["mcp-server"]}}}
JSON
hash1="$(md5 -q .mcp.json 2>/dev/null || md5sum .mcp.json | awk '{print $1}')"

assert_exit0 bash "$SCRIPTS/mcp_codex.sh"
hash2="$(md5 -q .mcp.json 2>/dev/null || md5sum .mcp.json | awk '{print $1}')"

if [ "$hash1" = "$hash2" ]; then ok_msg ".mcp.json unchanged on re-run"
else                              fail_msg ".mcp.json changed on re-run"; fi

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T22b mcp_codex.sh — migrates a stale codex-cli entry to the canonical definition
# ═══════════════════════════════════════════════════════════════════════════════
section "T22b: mcp_codex.sh — migrates stale codex-cli entry"
make_tmp

cat > .mcp.json <<'JSON'
{"mcpServers": {"codex-cli": {"type": "stdio", "command": "npx", "args": ["-y", "codex-mcp-server@1.4.10"]}, "keep": {"type": "stdio", "command": "cmd"}}}
JSON

assert_exit0 bash "$SCRIPTS/mcp_codex.sh"

assert_contains     ".mcp.json" '"mcp-server"'      # migrated to the built-in server
assert_not_contains ".mcp.json" 'codex-mcp-server'  # stale npm reference removed
assert_contains     ".mcp.json" '"keep"'            # other servers preserved

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T22c status.sh — flags a stale codex-cli entry with !
# ═══════════════════════════════════════════════════════════════════════════════
section "T22c: status.sh — flags stale codex-cli entry"
make_tmp

cat > .mcp.json <<'JSON'
{"mcpServers": {"codex-cli": {"type": "stdio", "command": "npx", "args": ["-y", "codex-mcp-server@1.4.10"]}}}
JSON

_stale_out="$(bash "$SCRIPTS/status.sh" 2>&1)"
if printf '%s' "$_stale_out" | grep -q '! \.mcp\.json → Claude'; then
  ok_msg "status.sh: stale codex-cli flagged with !"
else
  fail_msg "status.sh: stale codex-cli not flagged with !"
fi
if printf '%s' "$_stale_out" | grep -q '/cc-suite:repair'; then
  ok_msg "status.sh: directs user to /cc-suite:repair"
else
  fail_msg "status.sh: missing /cc-suite:repair hint"
fi

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T23  unbridge.sh — CC_SUITE_CREATED_CLAUDE: removes cc-suite-created CLAUDE.md
# ═══════════════════════════════════════════════════════════════════════════════
section "T23: unbridge.sh — removes cc-suite-created CLAUDE.md"
make_tmp
mkdir -p .codex

# A genuinely cc-suite-created AGENTS.md carries the init.sh scaffold line;
# unbridge keys its delete decision on that marker, not on the CLAUDE flag.
printf '# Project Instructions\n\nNever modify `CLAUDE.md` directly — it only imports `AGENTS.md`.\n' > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
mkdir -p .cc-suite
printf "CC_SUITE_CREATED_CLAUDE=1\n" > .cc-suite/provenance

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_no_file "AGENTS.md"
assert_no_file "CLAUDE.md"    # cc-suite created it — remove on unbridge

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T23b  unbridge.sh — preserves a pre-existing AGENTS.md (no scaffold marker)
# ═══════════════════════════════════════════════════════════════════════════════
# CC_SUITE_CREATED_CLAUDE=1 records that init created CLAUDE.md — it says
# nothing about AGENTS.md. When init found a user-authored AGENTS.md, only the
# CLAUDE.md import belongs to cc-suite; deleting AGENTS.md would lose user
# content. The pre-fix behavior did exactly that.
section "T23b: unbridge.sh — preserves pre-existing AGENTS.md"
make_tmp
mkdir -p .codex

echo "# user-authored AGENTS content" > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
mkdir -p .cc-suite
printf "CC_SUITE_CREATED_CLAUDE=1\n" > .cc-suite/provenance

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_file "AGENTS.md"       # user content survives unbridge
assert_contains "AGENTS.md" "user-authored AGENTS content"
assert_no_file "CLAUDE.md"    # the import cc-suite created is still removed

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T23c  unbridge.sh — recorded CC_SUITE_CREATED_AGENTS beats the content heuristic
# ═══════════════════════════════════════════════════════════════════════════════
# A current init.sh records CC_SUITE_CREATED_AGENTS=1 whenever it wrote
# AGENTS.md itself. Unbridge must key on that record, not on mutable file
# content: here the scaffold marker line has been edited out of AGENTS.md,
# which would fool the legacy heuristic into keeping a cc-suite-created file.
section "T23c: unbridge.sh — provenance-recorded AGENTS.md removed despite edits"
make_tmp
mkdir -p .codex

printf '# Project Instructions\n\nEdited: the scaffold marker line is gone.\n' > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
mkdir -p .cc-suite
printf "CC_SUITE_CREATED_CLAUDE=1\nCC_SUITE_CREATED_AGENTS=1\n" > .cc-suite/provenance

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_no_file "AGENTS.md"    # provenance says init created it — removed
assert_no_file "CLAUDE.md"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T24  unbridge.sh — CLAUDE_MIGRATED: restores original CLAUDE.md verbatim
# ═══════════════════════════════════════════════════════════════════════════════
section "T24: unbridge.sh — restores original CLAUDE.md from LEGACY .codex/ paths"
# Deliberately uses the pre-0.14 locations: repos initialized before cc-suite
# state moved into .cc-suite/ must still unbridge cleanly. T24b covers the
# current paths.
make_tmp
mkdir -p .codex

printf "# My Original Project\n\nWith real content.\n" > .codex/.cc-suite-original-claude.md
echo "# AGENTS.md content + cc-suite scaffolding" > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
printf "CLAUDE_MIGRATED=1\n" > .codex/.cc-suite.provenance

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_no_file  "AGENTS.md"
assert_file     "CLAUDE.md"
assert_contains "CLAUDE.md" "# My Original Project"
assert_contains "CLAUDE.md" "With real content."
# Provenance backup removed after consumption
assert_no_file ".codex/.cc-suite-original-claude.md"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T24b unbridge.sh — same restore via the current .cc-suite/ paths
# ═══════════════════════════════════════════════════════════════════════════════
section "T24b: unbridge.sh — restores original CLAUDE.md from .cc-suite/ paths"
make_tmp
mkdir -p .cc-suite

printf "# My Original Project\n\nWith real content.\n" > .cc-suite/original-claude.md
echo "# AGENTS.md content + cc-suite scaffolding" > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
printf "CLAUDE_MIGRATED=1\n" > .cc-suite/provenance

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_no_file  "AGENTS.md"
assert_file     "CLAUDE.md"
assert_contains "CLAUDE.md" "# My Original Project"
assert_contains "CLAUDE.md" "With real content."
assert_no_file  ".cc-suite/original-claude.md"
assert_no_file  ".cc-suite/provenance"
assert_no_dir   ".cc-suite"          # emptied by unbridge, so removed

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T24c unbridge.sh — keeps .cc-suite/ when the user has advisor agents there
# ═══════════════════════════════════════════════════════════════════════════════
section "T24c: unbridge.sh — preserves .cc-suite/agents/ while clearing its own state"
make_tmp
mkdir -p .cc-suite/agents

printf -- "---\nname: reviewer\n---\nBe critical.\n" > .cc-suite/agents/reviewer.md
echo "# AGENTS content" > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
printf "CC_SUITE_CREATED_CLAUDE=1\n" > .cc-suite/provenance

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_no_file ".cc-suite/provenance"     # cc-suite's own state: gone
assert_file    ".cc-suite/agents/reviewer.md"  # the user's advisor: untouched
assert_dir     ".cc-suite"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T25  unbridge.sh — no provenance, CLAUDE.md has own content → backup AGENTS.md
# ═══════════════════════════════════════════════════════════════════════════════
section "T25: unbridge.sh — backup when CLAUDE.md has own content (no provenance)"
make_tmp

printf "# Own content\nNot going anywhere.\n" > CLAUDE.md
printf "# AGENTS content\n" > AGENTS.md
# no .cc-suite/provenance

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_no_file "AGENTS.md"
assert_file    "AGENTS.md.cc-suite-backup"
assert_file    "CLAUDE.md"
assert_contains "CLAUDE.md" "# Own content"   # untouched

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T26  unbridge.sh — backup counter for repeated runs (no overwrite)
# ═══════════════════════════════════════════════════════════════════════════════
section "T26: unbridge.sh — backup counter avoids overwriting existing backup"
make_tmp

# Pre-existing backup from a previous unbridge run
echo "previous backup" > AGENTS.md.cc-suite-backup

printf "# Own content\n" > CLAUDE.md
printf "# New AGENTS\n" > AGENTS.md

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_file "AGENTS.md.cc-suite-backup"        # original backup intact
assert_contains "AGENTS.md.cc-suite-backup" "previous backup"
assert_file "AGENTS.md.cc-suite-backup.1"      # second backup at .1
assert_contains "AGENTS.md.cc-suite-backup.1" "# New AGENTS"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T27  unbridge.sh — pure @AGENTS.md GEMINI.md removed
# ═══════════════════════════════════════════════════════════════════════════════
section "T27: unbridge.sh — removes pure @AGENTS.md GEMINI.md"
make_tmp
mkdir -p .codex

printf "@AGENTS.md\n" > GEMINI.md
echo "# AGENTS" > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
mkdir -p .cc-suite
printf "CC_SUITE_CREATED_CLAUDE=1\nCC_SUITE_CREATED_GEMINI=1\n" > .cc-suite/provenance

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_no_file "GEMINI.md"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T28  unbridge.sh — hybrid GEMINI.md left alone
# ═══════════════════════════════════════════════════════════════════════════════
section "T28: unbridge.sh — leaves hybrid GEMINI.md alone"
make_tmp
mkdir -p .codex

# Hybrid: @AGENTS.md + extra content — unbridge must NOT remove it
printf "@AGENTS.md\n\n# Custom Gemini instructions\n" > GEMINI.md
echo "# AGENTS" > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
mkdir -p .cc-suite
printf "CC_SUITE_CREATED_CLAUDE=1\n" > .cc-suite/provenance
# Note: CC_SUITE_CREATED_GEMINI is NOT set — user added content manually

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_file    "GEMINI.md"
assert_contains "GEMINI.md" "# Custom Gemini instructions"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T29  unbridge.sh — cc-suite hooks.json (with marker) removed
# ═══════════════════════════════════════════════════════════════════════════════
section "T29: unbridge.sh — removes cc-suite-generated hooks.json"
make_tmp
mkdir -p .codex

echo "# AGENTS" > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
mkdir -p .cc-suite
printf "CC_SUITE_CREATED_CLAUDE=1\n" > .cc-suite/provenance

cat > .codex/hooks.json <<'JSON'
{"_cc_bridge_version": "1", "hooks": {"SessionStart": [], "PreToolUse": []}}
JSON

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_no_file ".codex/hooks.json"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T30  unbridge.sh — user hooks.json (no marker) left alone
# ═══════════════════════════════════════════════════════════════════════════════
section "T30: unbridge.sh — leaves user hooks.json without _cc_bridge_version"
make_tmp
mkdir -p .codex

echo "# AGENTS" > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
mkdir -p .cc-suite
printf "CC_SUITE_CREATED_CLAUDE=1\n" > .cc-suite/provenance

cat > .codex/hooks.json <<'JSON'
{"hooks": {"SessionStart": [], "PreToolUse": []}}
JSON

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_file ".codex/hooks.json"   # must survive

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T31  unbridge.sh — removes cc-suite-mcp block, preserves other config.toml
# ═══════════════════════════════════════════════════════════════════════════════
section "T31: unbridge.sh — removes sentinel block, preserves rest of config.toml"
make_tmp
mkdir -p .codex

echo "# AGENTS" > AGENTS.md
printf "@AGENTS.md\n" > CLAUDE.md
mkdir -p .cc-suite
printf "CC_SUITE_CREATED_CLAUDE=1\n" > .cc-suite/provenance

cat > .codex/config.toml <<'TOML'
# My hand-written config
[settings]
timeout = 30

# >>> cc-suite-mcp >>>
[mcp_servers.mirrored-srv]
command = "cmd"
# <<< cc-suite-mcp <<<

[other]
key = "value"
TOML

assert_exit0 bash "$SCRIPTS/unbridge.sh"

assert_file ".codex/config.toml"
assert_contains     ".codex/config.toml" "[settings]"
assert_contains     ".codex/config.toml" "[other]"
assert_not_contains ".codex/config.toml" "# >>> cc-suite-mcp >>>"
assert_not_contains ".codex/config.toml" "[mcp_servers.mirrored-srv]"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T32  Full round-trip: init → bridge all → unbridge → back to original state
# ═══════════════════════════════════════════════════════════════════════════════
section "T32: full round-trip — init + all bridges + unbridge restores state"
make_tmp

# Setup: realistic project
printf "# My Real Project\n\nDo great things.\n" > CLAUDE.md
mkdir -p .claude/commands .claude/skills

cat > .claude/commands/lint.md <<'MD'
---
description: Run the linter.
---
Lint the code.
MD
cat > .claude/settings.json <<'JSON'
{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo hi"}]}]}}
JSON
cat > .mcp.json <<'JSON'
{"mcpServers": {"my-mcp": {"type": "stdio", "command": "npx", "args": ["-y", "my-mcp"]}}}
JSON

# init
assert_exit0 bash "$SCRIPTS/init.sh"
# bridge everything
python3 "$SCRIPTS/bridge_hooks.py"  >/dev/null 2>&1
bash    "$SCRIPTS/bridge_mcp.sh"    >/dev/null 2>&1
bash    "$SCRIPTS/bridge_commands.sh" >/dev/null 2>&1

# Verify bridged state
assert_file_content "CLAUDE.md" "@AGENTS.md"
assert_file         "AGENTS.md"
assert_symlink      ".agents/skills"
assert_file         ".codex/hooks.json"
assert_contains     ".codex/config.toml" "[mcp_servers.my-mcp]"
assert_file         ".claude/skills/cmd-lint/SKILL.md"

# unbridge
assert_exit0 bash "$SCRIPTS/unbridge.sh"

# Verify restored state
assert_no_file  "AGENTS.md"
assert_file     "CLAUDE.md"
assert_contains "CLAUDE.md" "# My Real Project"    # original content restored
assert_contains "CLAUDE.md" "Do great things."
assert_no_symlink ".agents/skills"
# .mcp.json and .claude/ untouched
assert_file ".mcp.json"
assert_file ".claude/settings.json"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T33  status.sh — clean output after full init+bridge (no bash quoting errors)
# ═══════════════════════════════════════════════════════════════════════════════
section "T33: status.sh — no errors after full init+bridge"
make_tmp

printf "# Real Project\n\nDo great things.\n" > CLAUDE.md
mkdir -p .claude/commands .claude/skills
cat > .claude/commands/deploy.md <<'MD'
---
description: Deploy.
---
Deploy the project.
MD
cat > .claude/settings.json <<'JSON'
{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "echo check"}]}]}}
JSON
cat > .mcp.json <<'JSON'
{"mcpServers": {"my-tool": {"type": "stdio", "command": "npx", "args": ["-y", "my-tool"]}}}
JSON

bash "$SCRIPTS/init.sh"           >/dev/null 2>&1
python3 "$SCRIPTS/bridge_hooks.py" >/dev/null 2>&1
bash "$SCRIPTS/bridge_mcp.sh"     >/dev/null 2>&1

# status.sh must exit 0 and produce no output on stderr.
_status_stderr="$(bash "$SCRIPTS/status.sh" 2>&1 1>/dev/null)"
if [ -z "$_status_stderr" ]; then
  ok_msg "status.sh: no stderr output"
else
  fail_msg "status.sh: unexpected stderr: $_status_stderr"
fi
assert_exit0 bash "$SCRIPTS/status.sh"

# Spot-check key lines in stdout.
_status_out="$(bash "$SCRIPTS/status.sh" 2>/dev/null)"
if printf '%s' "$_status_out" | grep -q '✓ AGENTS.md'; then
  ok_msg "status.sh: AGENTS.md shows ✓"
else
  fail_msg "status.sh: AGENTS.md missing ✓ in output"
fi
if printf '%s' "$_status_out" | grep -q '✓ CLAUDE.md'; then
  ok_msg "status.sh: CLAUDE.md shows ✓"
else
  fail_msg "status.sh: CLAUDE.md missing ✓ in output"
fi
if printf '%s' "$_status_out" | grep -q '✓ .codex/hooks.json'; then
  ok_msg "status.sh: .codex/hooks.json shows ✓"
else
  fail_msg "status.sh: .codex/hooks.json missing ✓ in output"
fi
if printf '%s' "$_status_out" | grep -q '✓ mirrored to .codex/config.toml'; then
  ok_msg "status.sh: MCP mirrored shows ✓"
else
  fail_msg "status.sh: MCP mirrored missing ✓ in output"
fi

cleanup

PINNED_OCTOPUS_VERSION="$(tr -d '[:space:]' < "$SCRIPTS/lib/claude-octopus-pin.txt")"

# ═══════════════════════════════════════════════════════════════════════════════
# T34  mcp_claude.sh — appends claude-code block to a fresh config.toml
# ═══════════════════════════════════════════════════════════════════════════════
section "T34: mcp_claude.sh — appends claude-code MCP block"
make_tmp

assert_exit0 bash "$SCRIPTS/mcp_claude.sh"

assert_file ".codex/config.toml"
assert_contains ".codex/config.toml" ">>> cc-suite-claude-mcp >>>"
assert_contains ".codex/config.toml" "[mcp_servers.claude-code]"
assert_contains ".codex/config.toml" "claude-octopus@${PINNED_OCTOPUS_VERSION}"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T35  mcp_claude.sh — idempotent when cc-suite sentinel block already present
# ═══════════════════════════════════════════════════════════════════════════════
section "T35: mcp_claude.sh — idempotent on re-run"
make_tmp

bash "$SCRIPTS/mcp_claude.sh" >/dev/null 2>&1
hash1="$(md5 -q .codex/config.toml 2>/dev/null || md5sum .codex/config.toml | awk '{print $1}')"

assert_exit0 bash "$SCRIPTS/mcp_claude.sh"
hash2="$(md5 -q .codex/config.toml 2>/dev/null || md5sum .codex/config.toml | awk '{print $1}')"

if [ "$hash1" = "$hash2" ]; then ok_msg ".codex/config.toml unchanged on re-run"
else                              fail_msg ".codex/config.toml changed on re-run"; fi

# Sentinel block must appear exactly once after re-run.
assert_count ">>> cc-suite-claude-mcp >>>" ".codex/config.toml" "1"
assert_count "[mcp_servers.claude-code]"  ".codex/config.toml" "1"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T36  mcp_claude.sh — refuses to clobber a pre-existing [mcp_servers.claude-code]
# ═══════════════════════════════════════════════════════════════════════════════
section "T36: mcp_claude.sh — leaves user-managed claude-code block alone"
make_tmp

mkdir -p .codex
cat > .codex/config.toml <<'TOML'
[mcp_servers.claude-code]
command = "node"
args    = ["/path/to/user/server.js"]
env     = {}
TOML

assert_exit0 bash "$SCRIPTS/mcp_claude.sh"

# cc-suite sentinel must NOT have been added, and the user's command must remain.
assert_not_contains ".codex/config.toml" ">>> cc-suite-claude-mcp >>>"
assert_not_contains ".codex/config.toml" "claude-octopus@"
assert_contains     ".codex/config.toml" "/path/to/user/server.js"
# And the file must still have exactly one [mcp_servers.claude-code] table —
# Codex would refuse to parse two duplicates, which is the bug this guards against.
assert_count "[mcp_servers.claude-code]" ".codex/config.toml" "1"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T36b mcp_claude.sh — also recognises the quoted-key form
# ═══════════════════════════════════════════════════════════════════════════════
section "T36b: mcp_claude.sh — recognises quoted [mcp_servers.\"claude-code\"]"
make_tmp

mkdir -p .codex
cat > .codex/config.toml <<'TOML'
[mcp_servers."claude-code"]
command = "node"
args    = ["other.js"]
TOML

assert_exit0 bash "$SCRIPTS/mcp_claude.sh"

assert_not_contains ".codex/config.toml" ">>> cc-suite-claude-mcp >>>"
assert_contains     ".codex/config.toml" 'other.js'

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T37  mcp_claude.sh — refreshes the sentinel block when the pin has moved
# ═══════════════════════════════════════════════════════════════════════════════
section "T37: mcp_claude.sh — refreshes stale sentinel block in place"
make_tmp

# Write a stale cc-suite-managed block (an older claude-octopus pin).
mkdir -p .codex
cat > .codex/config.toml <<'TOML'
# >>> cc-suite-claude-mcp >>>
[mcp_servers.claude-code]
command = "npx"
args    = ["-y", "claude-octopus@1.0.0"]
env     = {}
# <<< cc-suite-claude-mcp <<<
TOML

assert_exit0 bash "$SCRIPTS/mcp_claude.sh"

# The new pin must replace the old one — exactly once, no duplicates.
assert_contains     ".codex/config.toml" "claude-octopus@${PINNED_OCTOPUS_VERSION}"
assert_not_contains ".codex/config.toml" "claude-octopus@1.0.0"
assert_count ">>> cc-suite-claude-mcp >>>" ".codex/config.toml" "1"
assert_count "[mcp_servers.claude-code]"   ".codex/config.toml" "1"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T38  mcp_claude.sh — refresh preserves unrelated config in the same file
# ═══════════════════════════════════════════════════════════════════════════════
section "T38: mcp_claude.sh — refresh preserves unrelated TOML"
make_tmp

mkdir -p .codex
cat > .codex/config.toml <<'TOML'
# >>> cc-suite-claude-mcp >>>
[mcp_servers.claude-code]
command = "npx"
args    = ["-y", "claude-octopus@1.0.0"]
env     = {}
# <<< cc-suite-claude-mcp <<<

[other_setting]
foo = "bar"

[mcp_servers.something-else]
command = "node"
args    = ["unrelated.js"]
TOML

assert_exit0 bash "$SCRIPTS/mcp_claude.sh"

assert_contains     ".codex/config.toml" "claude-octopus@${PINNED_OCTOPUS_VERSION}"
assert_not_contains ".codex/config.toml" "claude-octopus@1.0.0"
assert_contains     ".codex/config.toml" "[other_setting]"
assert_contains     ".codex/config.toml" 'foo = "bar"'
assert_contains     ".codex/config.toml" "[mcp_servers.something-else]"
assert_contains     ".codex/config.toml" "unrelated.js"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T39  boot_test_claude_mcp.mjs — pinned claude-octopus boots and handshakes
#
# Network-dependent — uses npx to pull the pinned version. Set
# CC_SUITE_SKIP_BOOT_TEST=1 to skip (offline / pre-merge CI).
# ═══════════════════════════════════════════════════════════════════════════════
section "T39: boot test — pinned claude-octopus@${PINNED_OCTOPUS_VERSION} boots and responds"

if [ "${CC_SUITE_SKIP_BOOT_TEST:-0}" = "1" ]; then
  skip_msg="boot test skipped (CC_SUITE_SKIP_BOOT_TEST=1)"
  printf "${B}  · %s${N}\n" "$skip_msg"
else
  if node "$SCRIPTS/lib/boot_test_claude_mcp.mjs" >/dev/null 2>&1; then
    ok_msg "claude-octopus@${PINNED_OCTOPUS_VERSION} booted and responded to MCP initialize"
  else
    fail_msg "claude-octopus@${PINNED_OCTOPUS_VERSION} failed to boot or respond — pin may be broken"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# T40  bridge_agents.py — no-op when .cc-suite/agents/ does not exist
# ═══════════════════════════════════════════════════════════════════════════════
section "T40: bridge_agents.py — no-op without .cc-suite/agents/"
make_tmp

assert_exit0 python3 "$SCRIPTS/bridge_agents.py"

# Should leave no .mcp.json behind and create an empty .codex/config.toml at most.
assert_no_file ".mcp.json"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T41  bridge_agents.py — registers a single advisor in both registries
# ═══════════════════════════════════════════════════════════════════════════════
section "T41: bridge_agents.py — single advisor end-to-end"
make_tmp

mkdir -p .cc-suite/agents
cat > .cc-suite/agents/clarity_reviewer.md <<'AGENT'
---
name: clarity_reviewer
description: Reviews code for readability.
tool_name: clarity_review
model: sonnet
allowed_tools: [Read, Grep, Glob]
max_turns: 3
---

You value simplicity over cleverness.
AGENT

assert_exit0 python3 "$SCRIPTS/bridge_agents.py"

# .mcp.json: entry exists with the marker key.
assert_file ".mcp.json"
assert_contains ".mcp.json" '"clarity_reviewer"'
assert_contains ".mcp.json" '"_cc_suite_agent": "clarity_reviewer"'
assert_contains ".mcp.json" '"CLAUDE_TOOL_NAME": "clarity_review"'
assert_contains ".mcp.json" '"CLAUDE_MODEL": "sonnet"'

# .codex/config.toml: sentinel block and TOML table both present.
assert_contains ".codex/config.toml" ">>> cc-suite-agent: clarity_reviewer >>>"
assert_contains ".codex/config.toml" "[mcp_servers.clarity_reviewer]"
assert_contains ".codex/config.toml" 'CLAUDE_TOOL_NAME = "clarity_review"'
assert_contains ".codex/config.toml" "<<< cc-suite-agent: clarity_reviewer <<<"

# Timeline dir created, gitignore rule written.
assert_dir ".cc-suite/agents/clarity_reviewer/timeline"
assert_file ".cc-suite/.gitignore"
assert_contains ".cc-suite/.gitignore" "*/timeline/"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T42  bridge_agents.py — multiple agents registered, then idempotent re-run
# ═══════════════════════════════════════════════════════════════════════════════
section "T42: bridge_agents.py — multiple agents + idempotent re-run"
make_tmp

mkdir -p .cc-suite/agents
cat > .cc-suite/agents/north_star.md <<'AGENT'
---
name: north_star
description: Project north star.
---
You hold first-principles reasoning above retrieval.
AGENT
cat > .cc-suite/agents/security_skeptic.md <<'AGENT'
---
name: security_skeptic
description: Security-focused adversarial reviewer.
---
You assume any input is hostile until validated.
AGENT

assert_exit0 python3 "$SCRIPTS/bridge_agents.py"

assert_contains ".mcp.json" '"north_star"'
assert_contains ".mcp.json" '"security_skeptic"'
assert_count ">>> cc-suite-agent:" ".codex/config.toml" "2"

hash1="$(md5 -q .mcp.json 2>/dev/null || md5sum .mcp.json | awk '{print $1}')"
hash2="$(md5 -q .codex/config.toml 2>/dev/null || md5sum .codex/config.toml | awk '{print $1}')"

assert_exit0 python3 "$SCRIPTS/bridge_agents.py"

hash1b="$(md5 -q .mcp.json 2>/dev/null || md5sum .mcp.json | awk '{print $1}')"
hash2b="$(md5 -q .codex/config.toml 2>/dev/null || md5sum .codex/config.toml | awk '{print $1}')"

if [ "$hash1" = "$hash1b" ]; then ok_msg ".mcp.json unchanged on re-run"; else fail_msg ".mcp.json changed on re-run"; fi
if [ "$hash2" = "$hash2b" ]; then ok_msg ".codex/config.toml unchanged on re-run"; else fail_msg ".codex/config.toml changed on re-run"; fi

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T43  bridge_agents.py — agent file deleted → registration cleaned up
# ═══════════════════════════════════════════════════════════════════════════════
section "T43: bridge_agents.py — removal triggers cleanup in both registries"
make_tmp

mkdir -p .cc-suite/agents
cat > .cc-suite/agents/ephemeral.md <<'AGENT'
---
name: ephemeral
description: Temporary advisor.
---
Body.
AGENT
python3 "$SCRIPTS/bridge_agents.py" >/dev/null

assert_contains ".mcp.json" '"ephemeral"'
assert_contains ".codex/config.toml" ">>> cc-suite-agent: ephemeral >>>"

rm .cc-suite/agents/ephemeral.md
assert_exit0 python3 "$SCRIPTS/bridge_agents.py"

assert_not_contains ".mcp.json" '"ephemeral"'
assert_not_contains ".codex/config.toml" "cc-suite-agent: ephemeral"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T44  bridge_agents.py — refuses to clobber a user-managed entry with the same name
# ═══════════════════════════════════════════════════════════════════════════════
section "T44: bridge_agents.py — refuses to overwrite user-managed .mcp.json entry"
make_tmp

mkdir -p .cc-suite/agents
cat > .cc-suite/agents/my_advisor.md <<'AGENT'
---
name: my_advisor
description: Would-be cc-suite advisor.
---
Body.
AGENT

cat > .mcp.json <<'JSON'
{
  "mcpServers": {
    "my_advisor": {
      "command": "node",
      "args": ["/path/to/my/server.js"]
    }
  }
}
JSON

# Should exit non-zero because of the conflict.
assert_exit_nonzero python3 "$SCRIPTS/bridge_agents.py"

# The user's manual entry must still be there and untouched.
assert_contains ".mcp.json" '"/path/to/my/server.js"'
assert_not_contains ".mcp.json" '"_cc_suite_agent"'

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T45  bridge_agents.py — freshen: changing agent body updates the registration
# ═══════════════════════════════════════════════════════════════════════════════
section "T45: bridge_agents.py — freshens registration when agent body changes"
make_tmp

mkdir -p .cc-suite/agents
cat > .cc-suite/agents/drifter.md <<'AGENT'
---
name: drifter
description: First version.
---
The first system prompt.
AGENT
python3 "$SCRIPTS/bridge_agents.py" >/dev/null
assert_contains ".mcp.json" "The first system prompt."

cat > .cc-suite/agents/drifter.md <<'AGENT'
---
name: drifter
description: Second version.
---
The second system prompt — completely different.
AGENT
assert_exit0 python3 "$SCRIPTS/bridge_agents.py"

assert_contains     ".mcp.json" "The second system prompt"
assert_not_contains ".mcp.json" "The first system prompt"
# Exactly one entry should exist for this name.
assert_count '"_cc_suite_agent": "drifter"' ".mcp.json" "1"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T46  bridge_agents.py — preserves unrelated TOML config in .codex/config.toml
# ═══════════════════════════════════════════════════════════════════════════════
section "T46: bridge_agents.py — preserves unrelated TOML when rewriting agent blocks"
make_tmp

mkdir -p .codex .cc-suite/agents
cat > .codex/config.toml <<'TOML'
[other_section]
keep = "me"

[mcp_servers.unrelated_server]
command = "node"
args    = ["unrelated.js"]
TOML

cat > .cc-suite/agents/advisor_x.md <<'AGENT'
---
name: advisor_x
description: New advisor.
---
Body.
AGENT

assert_exit0 python3 "$SCRIPTS/bridge_agents.py"

assert_contains ".codex/config.toml" "[other_section]"
assert_contains ".codex/config.toml" 'keep = "me"'
assert_contains ".codex/config.toml" "[mcp_servers.unrelated_server]"
assert_contains ".codex/config.toml" 'unrelated.js'
assert_contains ".codex/config.toml" ">>> cc-suite-agent: advisor_x >>>"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T47  bridge_agents.py — rejects an agent file with no frontmatter
# ═══════════════════════════════════════════════════════════════════════════════
section "T47: bridge_agents.py — invalid agent file is rejected"
make_tmp

mkdir -p .cc-suite/agents
echo "no frontmatter at all" > .cc-suite/agents/broken.md

assert_exit_nonzero python3 "$SCRIPTS/bridge_agents.py"

# Nothing should have been written.
assert_no_file ".mcp.json"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T48  ensure_gitignore.sh — plugin repo: .mcp.json ignored + self-heal untrack
# ═══════════════════════════════════════════════════════════════════════════════
section "T48: ensure_gitignore.sh — plugin repo untracks & ignores .mcp.json"
make_tmp

git init -q; git config user.email t@t; git config user.name t
mkdir -p .claude-plugin
echo '{"name":"x","version":"0.1.0"}' > .claude-plugin/plugin.json
printf '{"mcpServers":{"codex-cli":{"type":"stdio","command":"codex","args":["mcp-server"]}}}\n' > .mcp.json
git add -A; git commit -qm init >/dev/null 2>&1

assert_exit0 git ls-files --error-unmatch .mcp.json      # tracked before fix
bash "$SCRIPTS/ensure_gitignore.sh" >/dev/null 2>&1
assert_contains ".gitignore" "cc-suite-schema: 7"
assert_exit_nonzero git ls-files --error-unmatch .mcp.json   # now untracked
assert_exit0 git check-ignore .mcp.json                      # now ignored
assert_file ".mcp.json"                                      # working file kept

# Plugin-local consumer scaffolding is also ignored, but remains available for
# local smoke tests when deliberately created.
mkdir -p .codex/prompts .gemini/skills
touch .codex/config.toml .codex/prompts/.gitkeep .gemini/skills/.gitkeep
printf '@AGENTS.md\n' > GEMINI.md
assert_exit0 git check-ignore .codex/config.toml
assert_exit0 git check-ignore .codex/prompts/.gitkeep
assert_exit0 git check-ignore .gemini/skills/.gitkeep
assert_exit0 git check-ignore GEMINI.md

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T49  ensure_gitignore.sh — non-plugin app repo keeps .mcp.json shared
# ═══════════════════════════════════════════════════════════════════════════════
section "T49: ensure_gitignore.sh — app repo leaves .mcp.json tracked"
make_tmp

git init -q; git config user.email t@t; git config user.name t
printf '{"mcpServers":{}}\n' > .mcp.json
git add -A; git commit -qm init >/dev/null 2>&1

bash "$SCRIPTS/ensure_gitignore.sh" >/dev/null 2>&1
assert_exit0 git ls-files --error-unmatch .mcp.json     # stays tracked
assert_exit_nonzero git check-ignore .mcp.json          # not ignored

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T50  ensure_gitignore.sh — old schema migration self-heals a leak
# ═══════════════════════════════════════════════════════════════════════════════
section "T50: ensure_gitignore.sh — schema migration untracks leaked .mcp.json"
make_tmp

git init -q; git config user.email t@t; git config user.name t
mkdir -p .claude-plugin
echo '{"name":"x","version":"0.1.0"}' > .claude-plugin/plugin.json
printf '{"mcpServers":{"codex-cli":{"type":"stdio","command":"codex","args":["mcp-server"]}}}\n' > .mcp.json
printf '# >>> cc-suite >>>\n# cc-suite-schema: 2\n.claude/settings.local.json\n# <<< cc-suite <<<\n' > .gitignore
git add -A; git commit -qm init >/dev/null 2>&1

bash "$SCRIPTS/ensure_gitignore.sh" >/dev/null 2>&1
assert_contains ".gitignore" "cc-suite-schema: 7"
assert_count "# >>> cc-suite >>>" ".gitignore" 1   # single block, no duplication
assert_exit_nonzero git ls-files --error-unmatch .mcp.json   # migrated + untracked
assert_exit0 git check-ignore .mcp.json

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T51  agy-preflight.sh — agy absent → structured error, never a crash
# ═══════════════════════════════════════════════════════════════════════════════
section "T51: agy-preflight.sh — agy not on PATH"
make_tmp

# Use only system binaries so a Homebrew directory containing both `node` and
# `agy` cannot accidentally make the absent-binary fixture non-sterile.
STERILE_PATH="/usr/bin:/bin"

out="$(env PATH="$STERILE_PATH" AGY_PREFLIGHT_NO_CACHE=1 bash "$SCRIPTS/agy-preflight.sh" 2>/dev/null)"
printf '%s' "$out" > preflight.json

assert_contains "preflight.json" '"status":"error"'
assert_contains "preflight.json" "antigravity-cli"
# reasoning_efforts must be empty: agy encodes effort in the model name, so a
# caller offering an effort picker for this backend would be wrong.
assert_contains "preflight.json" '"reasoning_efforts":[]'
# Must still be parseable JSON, not a shell error dump.
assert_exit0 python3 -c "import json,sys; json.load(open('preflight.json'))"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T52  agy-runner.mjs — no prompt → exits non-zero
# ═══════════════════════════════════════════════════════════════════════════════
section "T52: agy-runner.mjs — missing prompt is rejected"
make_tmp

assert_exit_nonzero node "$SCRIPTS/agy-runner.mjs" --kind agy

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T53  agy-runner.mjs — agy absent → status=failed with an actionable message
# ═══════════════════════════════════════════════════════════════════════════════
section "T53: agy-runner.mjs — agy not on PATH"
make_tmp

mkdir -p node-bin
ln -s "$(command -v node)" node-bin/node
STERILE_PATH="$PWD/node-bin:/usr/bin:/bin"

# Runner reports failure in-band (JSON on stdout) and exits 1; capture both.
out="$(env PATH="$STERILE_PATH" node "$SCRIPTS/agy-runner.mjs" \
        --kind agy --timeout-ms 10000 -- "smoke" 2>/dev/null || true)"
printf '%s' "$out" > result.json

assert_exit0 python3 -c "import json,sys; json.load(open('result.json'))"
assert_contains "result.json" '"status":"failed"'
assert_contains "result.json" "agy not found on PATH"
# A failed spawn must still register a job so /cc-suite:status can see it.
assert_contains "result.json" '"jobId"'

cleanup

# ══════════ T54  codex-preflight.sh — latest frontier model first ════════════
section "T54: codex-preflight.sh — orders models with latest frontier first"
make_tmp

mkdir -p bin home/.codex cache
cat > bin/codex <<'CODEX'
#!/usr/bin/env bash
case "$*" in
  "--version") echo "codex-cli 0.144.4" ;;
  "login status") echo "Logged in with ChatGPT" ;;
  "cloud list") exit 1 ;;
  *) exit 0 ;;
esac
CODEX
chmod +x bin/codex

cat > home/.codex/models_cache.json <<'JSON'
{
  "models": [
    {
      "slug": "gpt-5.5",
      "display_name": "GPT-5.5",
      "description": "Older frontier model",
      "priority": 0,
      "supported_reasoning_levels": [{"effort": "medium"}, {"effort": "high"}]
    },
    {
      "slug": "gpt-5.6-sol",
      "display_name": "GPT-5.6-Sol",
      "description": "Latest frontier agentic coding model",
      "priority": 1,
      "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}, {"effort": "max"}, {"effort": "ultra"}]
    }
  ]
}
JSON

PYTHON_BIN_DIR="$(dirname "$(command -v python3)")"
out="$(env HOME="$PWD/home" XDG_CACHE_HOME="$PWD/cache" CODEX_PREFLIGHT_NO_CACHE=1 \
  PATH="$PWD/bin:$PYTHON_BIN_DIR:/usr/bin:/bin" bash "$SCRIPTS/codex-preflight.sh" 2>/dev/null)"
printf '%s' "$out" > preflight.json

assert_contains "preflight.json" '"default_model":"gpt-5.6-sol"'
assert_contains "preflight.json" '"models":["gpt-5.6-sol","gpt-5.5"]'
assert_contains "preflight.json" '"reasoning_efforts":["low","medium","high","xhigh","max","ultra"]'
assert_exit0 python3 -c "import json; d=json.load(open('preflight.json')); assert d['preflight_schema'] == 4"

cleanup

# ══════════ T54b  codex-preflight.sh — missing cache populated via exec ══════
# `codex login --refresh` was removed in codex-cli 0.147.0; the CLI only writes
# models_cache.json at session start. The preflight must trigger a minimal
# `codex exec` when the cache is absent, and surface the reason when it fails.
section "T54b: codex-preflight.sh — populates missing cache via codex exec"
make_tmp

mkdir -p bin home/.codex cache
cat > bin/codex <<'CODEX'
#!/usr/bin/env bash
case "$1" in
  "--version") echo "codex-cli 0.147.0" ;;
  "login") echo "Logged in with ChatGPT" ;;
  "exec")
    mkdir -p "$HOME/.codex"
    printf '{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"Latest frontier agentic coding model","priority":1,"supported_reasoning_levels":[{"effort":"medium"},{"effort":"high"}]}]}\n' \
      > "$HOME/.codex/models_cache.json"
    echo "ok" ;;
  *) exit 1 ;;
esac
CODEX
chmod +x bin/codex

PYTHON_BIN_DIR="$(dirname "$(command -v python3)")"
out="$(env HOME="$PWD/home" XDG_CACHE_HOME="$PWD/cache" CODEX_PREFLIGHT_NO_CACHE=1 \
  PATH="$PWD/bin:$PYTHON_BIN_DIR:/usr/bin:/bin" bash "$SCRIPTS/codex-preflight.sh" 2>stderr.log)"
printf '%s' "$out" > preflight.json

assert_contains "preflight.json" '"status":"ok"'
assert_contains "preflight.json" '"default_model":"gpt-5.6-sol"'
assert_file "home/.codex/models_cache.json"
assert_contains "stderr.log" "Models cache populated successfully"

# Failure path: exec cannot create the cache — the reason must reach stderr
# and the error JSON must carry accurate guidance (login no longer helps).
rm -f home/.codex/models_cache.json
cat > bin/codex <<'CODEX'
#!/usr/bin/env bash
case "$1" in
  "--version") echo "codex-cli 0.147.0" ;;
  "login") echo "Logged in with ChatGPT" ;;
  "exec") echo "stream error: quota exceeded" >&2; exit 1 ;;
  *) exit 1 ;;
esac
CODEX
chmod +x bin/codex

out="$(env HOME="$PWD/home" XDG_CACHE_HOME="$PWD/cache" CODEX_PREFLIGHT_NO_CACHE=1 \
  PATH="$PWD/bin:$PYTHON_BIN_DIR:/usr/bin:/bin" bash "$SCRIPTS/codex-preflight.sh" 2>stderr.log || true)"
printf '%s' "$out" > preflight.json

assert_contains "preflight.json" '"status":"error"'
assert_contains "preflight.json" "No usable models cache"
assert_contains "preflight.json" "codex exec"
assert_contains "stderr.log" "stream error: quota exceeded"

cleanup

# ══════════ T53a  fence-aware config parsing and convergent repair ══════════
# Four defects that shared one shape: a check or parser that reads a proxy for
# the truth instead of the truth, so the tool reports a problem its own repair
# cannot clear.
section "T53a: config parsing and repair converge"

# (a) `## Enabled Tools` inside a fenced block is documentation, not the section.
make_tmp
cat > .cc-suite.md <<'MD'
# Config

Document the section like this:

```markdown
## Enabled Tools

- [x] claude
```

## Enabled Tools

- [x] claude
- [x] grok
- [x] opencode
MD
enabled="$(python3 "$SCRIPTS/bridge_tools.py" --enabled 2>/dev/null | tr '\n' ' ')"
if [ "$enabled" = "claude grok opencode " ]; then ok_msg "fenced example ignored; real selection parsed"
else fail_msg "tool selection read from the fenced example: '$enabled'"; fi
cleanup

# (b) A hand-deleted entry is restored, and the run stays idempotent.
make_tmp
git init -q .
bash "$SCRIPTS/ensure_gitignore.sh" >/dev/null 2>&1
grep -v '^\.claude/settings\.local\.json$' .gitignore > .g && mv .g .gitignore
bash "$SCRIPTS/ensure_gitignore.sh" >/dev/null 2>&1
assert_contains ".gitignore" ".claude/settings.local.json"
out="$(bash "$SCRIPTS/ensure_gitignore.sh" 2>&1)"
case "$out" in
  *"already has current cc-suite block"*) ok_msg "gitignore refresh is idempotent" ;;
  *) fail_msg "gitignore rewritten on an unchanged tree: $out" ;;
esac
cleanup

# (c) Becoming a plugin repo after the block was written must converge.
make_tmp
git init -q .
printf '{"mcpServers":{"myserver":{"type":"stdio","command":"foo"}}}\n' > .mcp.json
bash "$SCRIPTS/ensure_gitignore.sh" >/dev/null 2>&1
mkdir -p .claude-plugin && printf '{"name":"p"}\n' > .claude-plugin/plugin.json
bash "$SCRIPTS/ensure_gitignore.sh" >/dev/null 2>&1
assert_contains ".gitignore" ".codex/prompts/"
assert_contains ".gitignore" "GEMINI.md"
cleanup

# (d) A legacy codex-cli registration is cc-suite's, not a stranger's: treating
# it as foreign left a plugin's .mcp.json tracked and shipping.
make_tmp
git init -q .
mkdir -p .claude-plugin && printf '{"name":"p"}\n' > .claude-plugin/plugin.json
printf '{"mcpServers":{"codex-cli":{"type":"stdio","command":"npx","args":["-y","@openai/codex-mcp"]}}}\n' > .mcp.json
git add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
bash "$SCRIPTS/ensure_gitignore.sh" >/dev/null 2>&1
assert_contains ".gitignore" ".mcp.json"
if git ls-files --error-unmatch .mcp.json >/dev/null 2>&1; then
  fail_msg "legacy codex-cli .mcp.json left tracked — it ships to every installer"
else ok_msg "legacy codex-cli .mcp.json untracked and ignored"; fi
cleanup

# (e) A control character in a mirrored server must not make diagnose disagree
# with the file bridge_mcp.sh just wrote.
make_tmp
mkdir -p "$TMP/fakehome"
python3 -c "
import json
json.dump({'mcpServers':{'tabby':{'type':'stdio','command':'node','args':['--eval','a\tb']}}}, open('.mcp.json','w'))
"
assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"
HOME="$TMP/fakehome" python3 "$SCRIPTS/diagnose.py" --json --no-preflight > diag.json 2>/dev/null || true
python3 - <<'PY' && ok_msg "mcp parity converges with control characters" || fail_msg "mcp parity never converges on a control character"
import json
checks = {c["id"]: c for c in json.load(open("diag.json"))["checks"]}
assert checks["mcp_parity"]["status"] == "healthy", checks["mcp_parity"]
PY
cleanup

# ══════════ T54d  codex-preflight.sh — a failed refresh is not retried per call
# The refresh is a real, billable model roundtrip, and the preflight runs from
# hooks and from every model-selecting command. Without a cooldown a machine
# with a broken cache spends one call per invocation to fail identically.
section "T54d: codex-preflight.sh — failed cache refresh is rate limited"
make_tmp

mkdir -p bin home/.codex cache
CALLLOG="$PWD/codex-exec-calls.txt"; : > "$CALLLOG"
cat > bin/codex <<'CODEX'
#!/usr/bin/env bash
case "$1" in
  "--version") echo "codex-cli 0.147.0" ;;
  "login") echo "Logged in with ChatGPT" ;;
  "exec") echo "CALLED" >> "$CALLLOG"; echo "stream error: quota exceeded" >&2; exit 1 ;;
  *) exit 1 ;;
esac
CODEX
chmod +x bin/codex

PYTHON_BIN_DIR="$(dirname "$(command -v python3)")"
for _ in 1 2 3; do
  env HOME="$PWD/home" XDG_CACHE_HOME="$PWD/cache" CODEX_PREFLIGHT_NO_CACHE=1 CALLLOG="$CALLLOG" \
    PATH="$PWD/bin:$PYTHON_BIN_DIR:/usr/bin:/bin" \
    bash "$SCRIPTS/codex-preflight.sh" >/dev/null 2>&1 || true
done
calls="$(wc -l < "$CALLLOG" | tr -d ' ')"
if [ "$calls" = "1" ]; then ok_msg "three preflight runs made exactly one billable codex exec call"
else fail_msg "expected 1 billable codex exec call across three runs, got $calls"; fi

cleanup

# ══════════ T54e  codex-preflight.sh — cloud probe never litters the project ═
# `codex cloud list` writes an error.log carrying the ChatGPT account id into
# its working directory on every run, and `-C` does not relocate it. The probe
# must run from a private temp dir that is gone by the time the script exits;
# otherwise the preflight leaves the account id in every project it checks.
section "T54e: codex-preflight.sh — cloud probe runs from a temp dir and cleans up"
make_tmp

mkdir -p bin home/.codex cache tmp
cat > bin/codex <<'CODEX'
#!/usr/bin/env bash
case "$*" in
  "--version") echo "codex-cli 0.152.0" ;;
  "login status") echo "Logged in with ChatGPT" ;;
  "cloud list") printf 'auth: mode=ChatGPT account_id=acct-secret\n' > "$PWD/error.log"; exit 0 ;;
  *) exit 1 ;;
esac
CODEX
chmod +x bin/codex
printf '{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"Latest frontier agentic coding model","priority":1,"supported_reasoning_levels":[{"effort":"medium"}]}]}\n' \
  > home/.codex/models_cache.json

PYTHON_BIN_DIR="$(dirname "$(command -v python3)")"
out="$(env HOME="$PWD/home" XDG_CACHE_HOME="$PWD/cache" CODEX_PREFLIGHT_NO_CACHE=1 TMPDIR="$PWD/tmp" \
  PATH="$PWD/bin:$PYTHON_BIN_DIR:/usr/bin:/bin" bash "$SCRIPTS/codex-preflight.sh" 2>/dev/null)"
printf '%s' "$out" > preflight.json

assert_contains "preflight.json" '"codex_cloud":true'
assert_no_file "error.log"
# The probe dir — and the error.log inside it — must not outlive the script.
leftover="$(find tmp -mindepth 1 | wc -l | tr -d ' ')"
if [ "$leftover" = "0" ]; then ok_msg "cloud probe left nothing under TMPDIR"
else fail_msg "cloud probe left $leftover entries under TMPDIR: $(find tmp -mindepth 1 | tr '\n' ' ')"; fi

cleanup

# ══════════ T54c  unbridge.sh — sentinel stripping never corrupts config.toml ═
# Marker spans are resolved against the original text and removed right to left.
# Computing them per iteration against already-mutated text let one block's
# removal swallow an interleaved block's opening marker, after which the slice
# silently duplicated the file's tail and the script still exited 0.
section "T54c: unbridge.sh — interleaved/nested sentinels fail closed, separate ones strip cleanly"

toml_is_valid() {
  python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$1" 2>/dev/null
}

# (a) interleaved markers — must refuse and leave the file valid and intact
make_tmp
mkdir -p .codex
cat > .codex/config.toml <<'TOML'
[settings]
a = 1
# >>> cc-suite-mcp >>>
x = 1
# >>> cc-suite-claude-mcp >>>
y = 2
# <<< cc-suite-mcp <<<
[other]
b = 2
# <<< cc-suite-claude-mcp <<<
[tail]
z = 1
TOML
cp .codex/config.toml expected.toml
assert_exit_nonzero bash "$SCRIPTS/unbridge.sh"
if toml_is_valid .codex/config.toml; then ok_msg "interleaved: config.toml still parses as TOML"
else fail_msg "interleaved: config.toml was corrupted"; fi
if cmp -s .codex/config.toml expected.toml; then ok_msg "interleaved: config.toml left byte-identical"
else fail_msg "interleaved: config.toml was rewritten"; fi
cleanup

# (b) nested markers — same refusal, and the final byte is not dropped
make_tmp
mkdir -p .codex
printf '[settings]
a = 1
# >>> cc-suite-mcp >>>
x = 1
# >>> cc-suite-claude-mcp >>>
y = 2
# <<< cc-suite-claude-mcp <<<
# <<< cc-suite-mcp <<<
[tail]
zzz = "LASTCHAR"' > .codex/config.toml
cp .codex/config.toml expected.toml
assert_exit_nonzero bash "$SCRIPTS/unbridge.sh"
if toml_is_valid .codex/config.toml; then ok_msg "nested: config.toml still parses as TOML"
else fail_msg "nested: config.toml was corrupted"; fi
if cmp -s .codex/config.toml expected.toml; then ok_msg "nested: config.toml left byte-identical"
else fail_msg "nested: final byte dropped or file rewritten"; fi
cleanup

# (c) two separate blocks — the supported shape still strips cleanly
make_tmp
mkdir -p .codex
cat > .codex/config.toml <<'TOML'
[settings]
a = 1
# >>> cc-suite-mcp >>>
x = 1
# <<< cc-suite-mcp <<<
[middle]
m = 1
# >>> cc-suite-claude-mcp >>>
y = 2
# <<< cc-suite-claude-mcp <<<
[tail]
z = 1
TOML
assert_exit0 bash "$SCRIPTS/unbridge.sh"
if toml_is_valid .codex/config.toml; then ok_msg "separate: config.toml still parses as TOML"
else fail_msg "separate: config.toml was corrupted"; fi
assert_not_contains ".codex/config.toml" "cc-suite-mcp"
assert_not_contains ".codex/config.toml" "cc-suite-claude-mcp"
assert_contains ".codex/config.toml" "[middle]"
assert_contains ".codex/config.toml" "[tail]"
cleanup

# ══════════ T55  bridge_mcp.sh — Codex + Antigravity projections ═════════════
section "T55: bridge_mcp.sh — writes Codex and agy workspace projections"
make_tmp

mkdir -p .codex
printf '# base config\n' > .codex/config.toml
cat > .mcp.json <<'JSON'
{
  "mcpServers": {
    "codex-cli": {"type":"stdio","command":"codex","args":["mcp-server"]},
    "workspace-tools": {"type":"stdio","command":"node","args":["server.mjs"],"env":{"TOKEN":"local-secret"}},
    "remote-tools": {"type":"sse","url":"https://example.com/mcp"}
  }
}
JSON

assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"
assert_file ".agents/mcp_config.json"
assert_file ".agents/.cc-suite-mcp.provenance.json"
assert_contains ".agents/mcp_config.json" '"claude-code"'
assert_contains ".agents/mcp_config.json" '"workspace-tools"'
assert_contains ".agents/mcp_config.json" '"serverUrl": "https://example.com/mcp"'
assert_not_contains ".agents/mcp_config.json" '"url": "https://example.com/mcp"'
assert_exit0 python3 -c "import json; d=json.load(open('.agents/mcp_config.json')); assert set(['codex-cli','workspace-tools','remote-tools','claude-code']) <= set(d['mcpServers'])"

agy_hash1="$(md5 -q .agents/mcp_config.json 2>/dev/null || md5sum .agents/mcp_config.json | awk '{print $1}')"
assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"
agy_hash2="$(md5 -q .agents/mcp_config.json 2>/dev/null || md5sum .agents/mcp_config.json | awk '{print $1}')"
if [ "$agy_hash1" = "$agy_hash2" ]; then ok_msg "agy MCP projection unchanged on re-run"
else fail_msg "agy MCP projection changed on re-run"; fi

assert_exit0 bash "$SCRIPTS/unbridge.sh"
assert_no_file ".agents/mcp_config.json"
assert_no_file ".agents/.cc-suite-mcp.provenance.json"
assert_file ".mcp.json"

cleanup

# ══════════ T56  bridge_agy_mcp.py — refuses user-owned config conflicts ══════
section "T56: bridge_agy_mcp.py — refuses user-owned config"
make_tmp

mkdir -p .agents
cat > .agents/mcp_config.json <<'JSON'
{"mcpServers":{"workspace-tools":{"type":"stdio","command":"user-server"}}}
JSON
cat > .mcp.json <<'JSON'
{"mcpServers":{"workspace-tools":{"type":"stdio","command":"cc-suite-server"}}}
JSON

assert_exit_nonzero python3 "$SCRIPTS/bridge_agy_mcp.py"
assert_contains ".agents/mcp_config.json" '"command":"user-server"'
assert_no_file ".agents/.cc-suite-mcp.provenance.json"

cleanup

# ══════════ T57  agy-preflight.sh — bounded probe + workspace status ═════════
section "T57: agy-preflight.sh — success and timeout are structured"
make_tmp

mkdir -p bin home .agents cache
cat > bin/agy <<'AGY'
#!/usr/bin/env bash
case "$1" in
  "--version") echo "agy 1.1.2" ;;
  "models") echo "Gemini 3.1 Pro (High)"; echo "Gemini 3.5 Flash (Low)" ;;
  *) exit 0 ;;
esac
AGY
chmod +x bin/agy
printf '{"mcpServers":{"claude-code":{"command":"npx","args":["claude-octopus@1.2.0"]}}}\n' > .agents/mcp_config.json

PYTHON_BIN_DIR="$(dirname "$(command -v python3)")"
out="$(env HOME="$PWD/home" XDG_CACHE_HOME="$PWD/cache" AGY_PREFLIGHT_NO_CACHE=1 \
  PATH="$PWD/bin:$PYTHON_BIN_DIR:/usr/bin:/bin" bash "$SCRIPTS/agy-preflight.sh" 2>/dev/null)"
printf '%s' "$out" > preflight.json
assert_contains "preflight.json" '"backend":"agy"'
assert_contains "preflight.json" '"status":"ok"'
assert_contains "preflight.json" '"default_model":"Gemini 3.1 Pro (High)"'
assert_contains "preflight.json" '"workspace_mcp_registered":true'
assert_exit0 python3 -c "import json; d=json.load(open('preflight.json')); assert d['preflight_schema'] == 2"

cat > bin/agy <<'AGY'
#!/usr/bin/env bash
case "$1" in
  "--version") echo "agy 1.1.2" ;;
  "models") sleep 3 ;;
  *) exit 0 ;;
esac
AGY
chmod +x bin/agy
out="$(env HOME="$PWD/home" XDG_CACHE_HOME="$PWD/cache" AGY_PREFLIGHT_NO_CACHE=1 AGY_MODELS_TIMEOUT_SECONDS=1 \
  PATH="$PWD/bin:$PYTHON_BIN_DIR:/usr/bin:/bin" bash "$SCRIPTS/agy-preflight.sh" 2>/dev/null)"
printf '%s' "$out" > timeout.json
assert_contains "timeout.json" '"error_code":"agy_probe_timeout"'
assert_exit0 python3 -c "import json; json.load(open('timeout.json'))"

cleanup

# ══════════ T58  bridge_mcp.sh — removes stale Codex sentinel entries ═════════
section "T58: bridge_mcp.sh — removes stale entries when source servers disappear"
make_tmp

mkdir -p .codex
printf '# base config\n# >>> cc-suite-mcp >>>\n[mcp_servers.removed]\ncommand = "old"\n# <<< cc-suite-mcp <<<\n' > .codex/config.toml
printf '{"mcpServers":{}}\n' > .mcp.json

assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"
assert_not_contains ".codex/config.toml" "mcp_servers.removed"
assert_contains ".codex/config.toml" "# base config"

cleanup

# ══════════ T59  status.sh — detects normalization collisions ════════════════
section "T59: status.sh — does not mark a colliding source name as mirrored"
make_tmp

mkdir -p .codex
printf '{"mcpServers":{"a.b":{"type":"stdio","command":"one"},"a-b":{"type":"stdio","command":"two"}}}\n' > .mcp.json
printf '# >>> cc-suite-mcp >>>\n[mcp_servers.a-b]\n# Claude MCP name: a.b\ncommand = "one"\n# <<< cc-suite-mcp <<<\n' > .codex/config.toml

bash "$SCRIPTS/status.sh" > status.txt 2>/dev/null
assert_contains "status.txt" "a.b → a-b"
assert_contains "status.txt" "NOT mirrored to Codex config"
assert_contains "status.txt" "'a-b'"

cleanup

# ══════════ T60  agy-preflight.sh — stdout auth error is not a model ═════════
section "T60: agy-preflight.sh — rejects agy auth errors printed on stdout"
make_tmp

mkdir -p bin cache home
cat > bin/agy <<'AGY'
#!/usr/bin/env bash
case "$1" in
  "--version") echo "agy 1.1.2" ;;
  "models") echo "Error: Please sign in to view available models."; exit 1 ;;
  *) exit 0 ;;
esac
AGY
chmod +x bin/agy

PYTHON_BIN_DIR="$(dirname "$(command -v python3)")"
out="$(env HOME="$PWD/home" XDG_CACHE_HOME="$PWD/cache" AGY_PREFLIGHT_NO_CACHE=1 \
  PATH="$PWD/bin:$PYTHON_BIN_DIR:/usr/bin:/bin" bash "$SCRIPTS/agy-preflight.sh" 2>/dev/null)"
printf '%s' "$out" > preflight.json
assert_contains "preflight.json" '"status":"error"'
assert_contains "preflight.json" '"error_code":"agy_not_authenticated"'
assert_contains "preflight.json" '"models":[]'
assert_exit0 python3 -c "import json; d=json.load(open('preflight.json')); assert d['status'] == 'error'"

cleanup

# ══════════ T61  stop hook — uses current Codex CLI flags ════════════════════
section "T61: stop-review-gate-hook.mjs — no removed approval flags"
make_tmp

mkdir -p bin state
cat > bin/codex <<'CODEX'
#!/bin/sh
printf '%s\n' "$@" > "$CODEX_ARGS"
printf 'ALLOW: test review passed\n'
CODEX
chmod +x bin/codex

NODE_BIN="$(command -v node)"
CLAUDE_PLUGIN_DATA="$PWD/state" "$NODE_BIN" --input-type=module -e \
  "const {setConfig}=await import('$SCRIPTS/lib/state.mjs'); setConfig(process.cwd(),'stopReviewGate',true)"

hook_input="{\"cwd\":\"$PWD\"}"
env PATH="$PWD/bin:/usr/bin:/bin" CLAUDE_PLUGIN_DATA="$PWD/state" CODEX_ARGS="$PWD/codex-args" \
  "$NODE_BIN" "$SCRIPTS/stop-review-gate-hook.mjs" <<< "$hook_input" > hook-output.txt

assert_not_contains "codex-args" "--ask-for-approval"
assert_not_contains "codex-args" "--approval-policy"
assert_not_contains "codex-args" "--model"
assert_contains "codex-args" "--sandbox"
assert_contains "codex-args" "--color"

cleanup

# ══════════ T62  bridge_mcp.sh — removes stale entries when source is absent ══
section "T62: bridge_mcp.sh — clears stale entries when .mcp.json is absent"
make_tmp

mkdir -p .codex
printf '# base config\n# >>> cc-suite-mcp >>>\n[mcp_servers.removed]\ncommand = "old"\n# <<< cc-suite-mcp <<<\n' > .codex/config.toml

assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"
assert_not_contains ".codex/config.toml" "mcp_servers.removed"
assert_contains ".codex/config.toml" "# base config"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
section "T63: bridge_tools.py — emits per-tool MCP config; never writes secrets"
# ═══════════════════════════════════════════════════════════════════════════════
make_tmp
cat > .mcp.json <<'JSON'
{ "mcpServers": {
    "codex-cli":  { "type": "stdio", "command": "codex", "args": ["mcp-server"] },
    "secret-srv": { "type": "stdio", "command": "x", "env": { "API_KEY": "LEAKVALUE" } } } }
JSON
cat > .cc-suite.md <<'MD'
## Enabled Tools
- [x] grok
- [x] opencode
- [ ] qwen
MD
assert_exit0 python3 "$SCRIPTS/bridge_tools.py"
assert_file      ".grok/config.toml"
assert_contains  ".grok/config.toml" "[mcp_servers.codex-cli]"
assert_contains  ".grok/config.toml" "[mcp_servers.claude-code]"    # claude-octopus auto-added
assert_file      "opencode.json"
assert_contains  "opencode.json" '"type": "local"'
assert_no_file   ".qwen/settings.json"                              # not enabled
assert_not_contains ".grok/config.toml" "LEAKVALUE"                 # env value never written
assert_not_contains "opencode.json"     "LEAKVALUE"
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
section "T64: bridge_tools.py — default selection bridges no registry tools"
# ═══════════════════════════════════════════════════════════════════════════════
make_tmp
echo '{ "mcpServers": {} }' > .mcp.json         # no .cc-suite.md → default claude/codex/antigravity
assert_exit0   python3 "$SCRIPTS/bridge_tools.py"
assert_no_file ".grok/config.toml"
assert_no_file "opencode.json"
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
section "T65: bridge_tools.py — idempotent; preserves user entries; refuses conflicts"
# ═══════════════════════════════════════════════════════════════════════════════
make_tmp
echo '{ "mcpServers": { "shared": { "type": "stdio", "command": "x" } } }' > .mcp.json
printf '## Enabled Tools\n- [x] opencode\n' > .cc-suite.md
assert_exit0 python3 "$SCRIPTS/bridge_tools.py"
cp opencode.json opencode.json.bak
assert_exit0 python3 "$SCRIPTS/bridge_tools.py"
if diff -q opencode.json opencode.json.bak >/dev/null; then ok_msg "opencode.json unchanged on idempotent re-run"
else fail_msg "opencode.json changed on idempotent re-run"; fi
python3 -c "import json;d=json.load(open('opencode.json'));d['mcp']['mine']={'type':'local','command':['y'],'enabled':True};d['theme']='x';json.dump(d,open('opencode.json','w'),indent=2)"
assert_exit0    python3 "$SCRIPTS/bridge_tools.py"
assert_contains "opencode.json" '"mine"'                            # user server preserved
assert_contains "opencode.json" '"theme"'                           # sibling key preserved
python3 -c "import json;p=json.load(open('.cc-suite-opencode.json.provenance.json'));p['managed_servers']=[];json.dump(p,open('.cc-suite-opencode.json.provenance.json','w'))"
assert_exit_nonzero python3 "$SCRIPTS/bridge_tools.py"              # 'shared' now user-owned → refuse
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
section "T66: bridge_tools.py --unbridge — removes cc-suite artifacts, keeps user content"
# ═══════════════════════════════════════════════════════════════════════════════
make_tmp
echo '{ "mcpServers": {} }' > .mcp.json
printf '## Enabled Tools\n- [x] grok\n- [x] opencode\n' > .cc-suite.md
assert_exit0 python3 "$SCRIPTS/bridge_tools.py"
printf '\nmodel = "grok-build"\n' >> .grok/config.toml               # user setting outside the block
assert_exit0 python3 "$SCRIPTS/bridge_tools.py" --unbridge grok,opencode
assert_contains     ".grok/config.toml" "grok-build"                # user line kept
assert_not_contains ".grok/config.toml" "cc-suite-mcp"              # cc-suite block removed
assert_no_file      "opencode.json"                                 # was cc-suite-only → removed
assert_no_file      ".cc-suite-opencode.json.provenance.json"       # provenance removed
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
section "T67: grok-runner.mjs — missing prompt is rejected"
# ═══════════════════════════════════════════════════════════════════════════════
make_tmp
assert_exit_nonzero node "$SCRIPTS/grok-runner.mjs" --kind grok
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
section "T68: grok-runner.mjs — grok absent → failed with an install hint"
# ═══════════════════════════════════════════════════════════════════════════════
make_tmp
mkdir -p node-bin
ln -s "$(command -v node)" node-bin/node
STERILE_PATH="$PWD/node-bin:/usr/bin:/bin"

# Runner reports failure in-band (JSON on stdout) and exits 1; capture both.
out="$(env PATH="$STERILE_PATH" node "$SCRIPTS/grok-runner.mjs" \
        --kind grok --timeout-ms 10000 -- "smoke" 2>/dev/null || true)"
printf '%s' "$out" > result.json

assert_exit0 python3 -c "import json,sys; json.load(open('result.json'))"
assert_contains "result.json" '"status":"failed"'
assert_contains "result.json" "grok not found on PATH"
# A failed spawn must still register a job so /cc-suite:status can see it.
assert_contains "result.json" '"jobId"'

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
section "T69: grok-preflight.sh — grok absent → error JSON with install hint"
# ═══════════════════════════════════════════════════════════════════════════════
make_tmp
# Sterile PATH: python3 available, grok (in ~/.local/bin) is not.
STERILE_PATH="$(dirname "$(command -v python3)"):/usr/bin:/bin"
out="$(env PATH="$STERILE_PATH" bash "$SCRIPTS/grok-preflight.sh" 2>/dev/null || true)"
printf '%s' "$out" > pf.json

assert_exit0 python3 -c "import json,sys; json.load(open('pf.json'))"
assert_contains "pf.json" '"status":"error"'
assert_contains "pf.json" '"error_code":"grok_not_found"'
assert_contains "pf.json" "x.ai/cli/install.sh"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
section "T70: migrate_config.py — tops up .cc-suite.md non-destructively"
# ═══════════════════════════════════════════════════════════════════════════════
make_tmp
printf '# CC-Suite Configuration\n\n## Project\n\n- **Stack**: TypeScript\n' > .cc-suite.md
assert_exit0    python3 "$SCRIPTS/migrate_config.py"
assert_contains ".cc-suite.md" "## Enabled Tools"     # managed section appended
assert_contains ".cc-suite.md" "[ ] grok"
assert_contains ".cc-suite.md" "TypeScript"           # user content preserved

cp .cc-suite.md before.md
assert_exit0 python3 "$SCRIPTS/migrate_config.py"     # idempotent
if diff -q .cc-suite.md before.md >/dev/null; then ok_msg "migrate_config.py idempotent on re-run"
else fail_msg "migrate_config.py changed the file on idempotent re-run"; fi

rm .cc-suite.md
assert_exit0   python3 "$SCRIPTS/migrate_config.py"   # no config → no-op, exit 0
assert_no_file ".cc-suite.md"                         # must NOT create the file itself

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T71  bridge_tools.py --detect / --set-enabled — the init tool picker
# ═══════════════════════════════════════════════════════════════════════════════
section "T71: bridge_tools.py — detect and set enabled tools"
make_tmp

assert_exit0 python3 "$SCRIPTS/bridge_tools.py" --detect
python3 "$SCRIPTS/bridge_tools.py" --detect > detect.json 2>/dev/null
assert_contains "detect.json" '"id": "claude"'
assert_contains "detect.json" '"installed"'
assert_contains "detect.json" '"china_tier"'
# Claude is the host: always reported present even without a binary on PATH.
assert_exit0 python3 -c "
import json
d = {t['id']: t for t in json.load(open('detect.json'))}
assert d['claude']['installed'] is True, 'claude must always be installed'
assert set(d) == {'claude','codex','antigravity','grok','opencode','qwen','kimi'}, d.keys()
"

printf '# cc-suite\n\nSettings.\n' > .cc-suite.md
python3 "$SCRIPTS/migrate_config.py" >/dev/null 2>&1
assert_exit0 python3 "$SCRIPTS/bridge_tools.py" --set-enabled codex,opencode
assert_contains     ".cc-suite.md" "- [x] codex"
assert_contains     ".cc-suite.md" "- [x] opencode"
assert_contains     ".cc-suite.md" "- [x] claude"     # always forced on
assert_not_contains ".cc-suite.md" "- [x] antigravity"
assert_not_contains ".cc-suite.md" "- [x] qwen"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T72  init.sh — honours the enabled-tools selection
# ═══════════════════════════════════════════════════════════════════════════════
section "T72: init.sh — skips Codex scaffolding when codex is not enabled"
make_tmp

# Claude-only project: no .codex/ artifacts should be created at all.
printf '# cc-suite\n\nSettings.\n' > .cc-suite.md
python3 "$SCRIPTS/migrate_config.py" >/dev/null 2>&1
python3 "$SCRIPTS/bridge_tools.py" --set-enabled claude >/dev/null 2>&1
bash "$SCRIPTS/init.sh" --description "Claude Only" >/dev/null 2>&1

assert_file    "AGENTS.md"
assert_no_file ".codex/config.toml"
assert_no_dir  ".codex/prompts"

# A project that bridges no Codex gets no .codex/ at all. cc-suite's own
# bookkeeping lives in .cc-suite/, so nothing needs the Codex directory.
assert_no_dir ".codex"
assert_file   ".cc-suite/provenance"
assert_contains ".cc-suite/provenance" "CC_SUITE_CREATED_CLAUDE=1"

cleanup

section "T72b: init.sh — still bridges Codex when enabled (and by default)"
make_tmp

printf '# cc-suite\n\nSettings.\n' > .cc-suite.md
python3 "$SCRIPTS/migrate_config.py" >/dev/null 2>&1
python3 "$SCRIPTS/bridge_tools.py" --set-enabled codex >/dev/null 2>&1
bash "$SCRIPTS/init.sh" --description "With Codex" >/dev/null 2>&1

assert_file ".codex/config.toml"
assert_file ".codex/prompts/.gitkeep"

cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T73  bridge_mcp.sh — honours the enabled-tools selection
# ═══════════════════════════════════════════════════════════════════════════════
section "T73: bridge_mcp.sh — codex disabled → no .codex/ created"
make_tmp
printf '## Enabled Tools\n- [x] claude\n- [x] antigravity\n' > .cc-suite.md
echo '{ "mcpServers": { "my-server": { "type": "stdio", "command": "x" } } }' > .mcp.json
assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"
assert_no_dir ".codex"
assert_file   ".agents/mcp_config.json"          # antigravity still projected
cleanup

section "T73b: bridge_mcp.sh — codex disabled reconciles an existing config"
make_tmp
printf '## Enabled Tools\n- [x] claude\n' > .cc-suite.md
echo '{ "mcpServers": { "my-server": { "type": "stdio", "command": "x" } } }' > .mcp.json
mkdir -p .codex
cat > .codex/config.toml <<'TOML'
# user setting
model = "gpt-5.6-sol"
# >>> cc-suite-mcp >>>
[mcp_servers.my-server]
command = "x"
# <<< cc-suite-mcp <<<
TOML
assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"
assert_contains     ".codex/config.toml" "# user setting"          # user TOML preserved
assert_not_contains ".codex/config.toml" "[mcp_servers.my-server]" # cc-suite block removed
assert_no_dir ".agents"                                            # antigravity disabled too
cleanup

section "T73c: bridge_mcp.sh — antigravity disabled → no .agents/ created, codex still projected"
make_tmp
printf '## Enabled Tools\n- [x] claude\n- [x] codex\n' > .cc-suite.md
echo '{ "mcpServers": { "my-server": { "type": "stdio", "command": "x" } } }' > .mcp.json
assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"
assert_contains ".codex/config.toml" "[mcp_servers.my-server]"
assert_no_dir   ".agents"
cleanup

section "T73d: bridge_mcp.sh — no .cc-suite.md keeps legacy behavior (both projected)"
make_tmp
echo '{ "mcpServers": { "my-server": { "type": "stdio", "command": "x" } } }' > .mcp.json
assert_exit0 bash "$SCRIPTS/bridge_mcp.sh"
assert_contains ".codex/config.toml" "[mcp_servers.my-server]"
assert_file     ".agents/mcp_config.json"
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T74  bridge_agents.py — honours the enabled-tools selection
# ═══════════════════════════════════════════════════════════════════════════════
section "T74: bridge_agents.py — codex disabled → advisor registered in .mcp.json only"
make_tmp
printf '## Enabled Tools\n- [x] claude\n' > .cc-suite.md
mkdir -p .cc-suite/agents
cat > .cc-suite/agents/tester.md <<'MD'
---
description: Test advisor.
---
Be a test advisor.
MD
assert_exit0 python3 "$SCRIPTS/bridge_agents.py"
assert_contains '.mcp.json' '"tester"'
assert_no_dir   ".codex"
cleanup

section "T74b: bridge_agents.py — codex disabled clears advisor blocks in an existing config"
make_tmp
printf '## Enabled Tools\n- [x] claude\n' > .cc-suite.md
mkdir -p .cc-suite/agents .codex
cat > .cc-suite/agents/tester.md <<'MD'
---
description: Test advisor.
---
Be a test advisor.
MD
cat > .codex/config.toml <<'TOML'
# user setting
# >>> cc-suite-agent: stale_advisor >>>
[mcp_servers.stale_advisor]
command = "npx"
# <<< cc-suite-agent: stale_advisor <<<
TOML
assert_exit0 python3 "$SCRIPTS/bridge_agents.py"
assert_contains     ".codex/config.toml" "# user setting"
assert_not_contains ".codex/config.toml" "stale_advisor"
assert_not_contains ".codex/config.toml" "tester"        # disabled → no new advisor projected
assert_contains     ".mcp.json" '"tester"'
cleanup

section "T74c: bridge_agents.py — codex enabled keeps projecting advisors"
make_tmp
printf '## Enabled Tools\n- [x] claude\n- [x] codex\n' > .cc-suite.md
mkdir -p .cc-suite/agents
cat > .cc-suite/agents/tester.md <<'MD'
---
description: Test advisor.
---
Be a test advisor.
MD
assert_exit0 python3 "$SCRIPTS/bridge_agents.py"
assert_contains ".mcp.json" '"tester"'
assert_contains ".codex/config.toml" "cc-suite-agent: tester"
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T76  diagnose.py — structured diagnostic engine
# ═══════════════════════════════════════════════════════════════════════════════
section "T76: diagnose.py — empty project reports issues as JSON"
make_tmp
if mkdir -p "$TMP/fakehome"; HOME="$TMP/fakehome" python3 "$SCRIPTS/diagnose.py" --json --no-preflight > diag.json 2>/dev/null; then
  fail_msg "diagnose.py should exit non-zero on an unbridged project"
else
  ok_msg "diagnose.py exits non-zero on an unbridged project"
fi
python3 - <<'PY' && ok_msg "empty project: agents_md + skills links are issues with auto fixes" || fail_msg "empty-project JSON assertions failed"
import json
d = json.load(open("diag.json"))
checks = {c["id"]: c for c in d["checks"]}
assert d["summary"]["issue"] > 0
assert checks["agents_md"]["status"] == "issue"
assert checks["agents_md"]["fix"]["auto"], "agents_md must carry an auto fix"
assert checks["claude_skills_link"]["status"] == "issue"
PY
cleanup

section "T76b: diagnose.py — disabled tools classify as expected_absent, not issues"
make_tmp
printf '## Enabled Tools\n- [x] claude\n' > .cc-suite.md
mkdir -p "$TMP/fakehome"; HOME="$TMP/fakehome" python3 "$SCRIPTS/diagnose.py" --json --no-preflight > diag.json 2>/dev/null || true
python3 - <<'PY' && ok_msg "codex/agy checks are expected_absent when disabled" || fail_msg "disabled-tools classification failed"
import json
d = json.load(open("diag.json"))
checks = {c["id"]: c for c in d["checks"]}
for cid in ("codex_artifacts", "mcp_codex_cli", "claude_code_reg", "mcp_parity", "agy_mcp", "codex_runtime", "agents_skills_link"):
    assert checks[cid]["status"] == "expected_absent", f"{cid}: {checks[cid]['status']}"
PY
cleanup

section "T76c: diagnose.py — initialized project is healthy on the hermetic checks"
make_tmp
printf '# X\n' > AGENTS.md
bash "$SCRIPTS/init.sh"          >/dev/null 2>&1
bash "$SCRIPTS/bridge_skills.sh" >/dev/null 2>&1
bash "$SCRIPTS/mcp_codex.sh"     >/dev/null 2>&1
bash "$SCRIPTS/mcp_claude.sh"    >/dev/null 2>&1
bash "$SCRIPTS/bridge_mcp.sh"    >/dev/null 2>&1
printf '## Enabled Tools\n- [x] claude\n- [x] codex\n- [x] antigravity\n\n## Defaults\n\n- **Default model**: latest\n' > .cc-suite.md
mkdir -p "$TMP/fakehome"; HOME="$TMP/fakehome" python3 "$SCRIPTS/diagnose.py" --json --no-preflight > diag.json 2>/dev/null || true
python3 - <<'PY' && ok_msg "initialized project: bridge checks healthy, latest policy healthy" || fail_msg "initialized-project assertions failed"
import json
d = json.load(open("diag.json"))
checks = {c["id"]: c for c in d["checks"]}
for cid in ("agents_md", "claude_md", "claude_skills_link", "agents_skills_link",
            "codex_config", "mcp_codex_cli", "claude_code_reg", "agy_mcp", "gitignore", "model_pin"):
    assert checks[cid]["status"] == "healthy", f"{cid}: {checks[cid]['status']} — {checks[cid]['detail']}"
assert d["summary"].get("issue", 0) == 0, d["summary"]
PY
cleanup

section "T76d: diagnose.py — malformed model field is informational, stale advisor parity is an issue"
make_tmp
printf '## Defaults\n\n- **Default model**: latest\n- **Default model**: gpt-old\n' > .cc-suite.md
mkdir -p .cc-suite/agents
printf -- '---\ndescription: t.\n---\nx\n' > .cc-suite/agents/ghost.md
mkdir -p "$TMP/fakehome"; HOME="$TMP/fakehome" python3 "$SCRIPTS/diagnose.py" --json --no-preflight > diag.json 2>/dev/null || true
python3 - <<'PY' && ok_msg "duplicate model field → info; unregistered advisor → issue" || fail_msg "T76d assertions failed"
import json
d = json.load(open("diag.json"))
checks = {c["id"]: c for c in d["checks"]}
assert checks["model_pin"]["status"] == "info", checks["model_pin"]
assert checks["advisors"]["status"] == "issue", checks["advisors"]
PY
cleanup

section "T76e: diagnose.py — unbridged enabled registry tool surfaces via --health"
make_tmp
printf '## Enabled Tools\n- [x] claude\n- [x] grok\n' > .cc-suite.md
mkdir -p "$TMP/fakehome"; HOME="$TMP/fakehome" python3 "$SCRIPTS/diagnose.py" --json --no-preflight > diag.json 2>/dev/null || true
python3 - <<'PY' && ok_msg "grok enabled but unbridged → tool_grok issue with bridge-tools fix" || fail_msg "T76e assertions failed"
import json
d = json.load(open("diag.json"))
checks = {c["id"]: c for c in d["checks"]}
assert checks["tool_grok"]["status"] == "issue", checks.get("tool_grok")
assert any("bridge_tools" in cmd for cmd in checks["tool_grok"]["fix"]["auto"])
PY
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T77  fix_plugin_hooks.py — section-scoped idempotent TOML edit
# ═══════════════════════════════════════════════════════════════════════════════
section "T77: fix_plugin_hooks.py — replaces, inserts once, leaves other tables alone"
make_tmp
printf '[features]\nplugin_hooks = false\n[other]\nplugin_hooks = false\n' > cfg.toml
export FIX="$SCRIPTS/fix_plugin_hooks.py"
assert_exit0 python3 "$SCRIPTS/fix_plugin_hooks.py" cfg.toml
python3 - <<'PY' && ok_msg "replaced in [features], [other] untouched, idempotent" || fail_msg "fix_plugin_hooks assertions failed"
import subprocess, sys, tomllib
d = tomllib.load(open("cfg.toml", "rb"))
assert d["features"]["plugin_hooks"] is True and d["other"]["plugin_hooks"] is False
subprocess.run([sys.executable, __import__("os").environ["FIX"], "cfg.toml"], check=True, capture_output=True)
text = open("cfg.toml").read()
assert text.count("plugin_hooks") == 2  # one per table, no duplicates added
PY
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T75  status.sh — advisor block with the current pin must not mask a stale claude-code pin
# ═══════════════════════════════════════════════════════════════════════════════
section "T75: status.sh — stale claude-code pin flagged despite current-pin advisor block"
make_tmp
_current_pin="$(tr -d '[:space:]' < "$SCRIPTS/lib/claude-octopus-pin.txt")"
mkdir -p .codex
cat > .codex/config.toml <<TOML
# >>> cc-suite-claude-mcp >>>
[mcp_servers.claude-code]
command = "npx"
args = ["-y", "claude-octopus@0.0.1"]
# <<< cc-suite-claude-mcp <<<

# >>> cc-suite-agent: advisor >>>
[mcp_servers.advisor]
command = "npx"
args = ["-y", "claude-octopus@${_current_pin}"]
# <<< cc-suite-agent: advisor <<<
TOML
_mask_out="$(bash "$SCRIPTS/status.sh" 2>&1)"
if printf '%s' "$_mask_out" | grep -q 'claude-code pinned @claude-octopus@0.0.1\|but plugin expects'; then
  ok_msg "status.sh: stale claude-code pin flagged (advisor block did not mask it)"
else
  fail_msg "status.sh: stale claude-code pin masked by advisor block"
fi
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T78  qwen-runner.mjs — no prompt → exits non-zero
# ═══════════════════════════════════════════════════════════════════════════════
section "T78: qwen-runner.mjs — missing prompt is rejected"
make_tmp
assert_exit_nonzero node "$SCRIPTS/qwen-runner.mjs" --kind qwen-review
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T79  qwen-runner.mjs — qwen absent → failed job with install hint
# ═══════════════════════════════════════════════════════════════════════════════
section "T79: qwen-runner.mjs — qwen not on PATH"
make_tmp
mkdir -p node-bin
ln -s "$(command -v node)" node-bin/node
STERILE_PATH="$PWD/node-bin:/usr/bin:/bin"

out="$(env PATH="$STERILE_PATH" CLAUDE_PLUGIN_DATA="$PWD/plugin-data" \
  node "$SCRIPTS/qwen-runner.mjs" --kind qwen-review \
  --max-resumes 0 --attempt-timeout-ms 1000 --idle-timeout-ms 1000 \
  --timeout-ms 2000 -- "smoke" 2>/dev/null || true)"
printf '%s' "$out" > result.json

assert_exit0 python3 -c "import json; json.load(open('result.json'))"
assert_contains "result.json" '"status":"failed"'
assert_contains "result.json" '"errorCode":"qwen_not_found"'
assert_contains "result.json" '"jobId"'
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# T80  qwen-preflight.sh — qwen absent → error JSON
# ═══════════════════════════════════════════════════════════════════════════════
section "T80: qwen-preflight.sh — qwen not on PATH"
make_tmp
STERILE_PATH="$(dirname "$(command -v python3)"):/usr/bin:/bin"
out="$(env PATH="$STERILE_PATH" bash "$SCRIPTS/qwen-preflight.sh" 2>/dev/null || true)"
printf '%s' "$out" > pf.json

assert_exit0 python3 -c "import json; json.load(open('pf.json'))"
assert_contains "pf.json" '"status":"error"'
assert_contains "pf.json" '"error_code":"qwen_not_found"'
cleanup

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo
printf '%.0s═' {1..60}
echo
printf "${B}Results: ${G}%d passed${N}" "$PASS"
if [ "$FAIL" -gt 0 ]; then
  printf ", ${R}%d FAILED${N}\n" "$FAIL"
  echo
  printf "${R}Failed assertions:${N}\n"
  for e in "${ERRORS[@]}"; do
    printf "  ${R}✗${N} %s\n" "$e"
  done
  exit 1
else
  printf ", ${G}0 failed${N}\n"
fi
