---
name: cc-suite
description: "Project instructions for cc-suite — the Claude Code plugin that bridges Claude, Codex CLI, and Gemini CLI with single-source AGENTS.md, shared skills, mirrored hooks, and bidirectional MCP delegation."
---

# Project Instructions

> cc-suite

## Guidelines

- Bump the version in `.claude-plugin/plugin.json` for every release (patch/minor/major per semver).
- New commands go in `commands/`; new skills go in `skills/cc-suite/<name>/SKILL.md`.
- All scripts in `scripts/` must be idempotent — running twice must produce the same result.
- Write new project-level instructions into `AGENTS.md` only; never edit `CLAUDE.md` or `GEMINI.md` directly.

## Prerequisites

- **Claude Code** (≥ 2.0) — primary host for all commands and skills
- **Codex CLI** (optional) — required for the `codex-cli` MCP delegation lane and `bridge_hooks.py`
- **Python 3** — required by `scripts/bridge_hooks.py`
- **Bash** — required by all `scripts/*.sh` files
- **`claude-octopus`** (npm, pinned) — the MCP server cc-suite registers in `.codex/config.toml` so Codex can delegate to Claude. cc-suite does not install it explicitly; `mcp_claude.sh` writes a `npx -y claude-octopus@<pin>` invocation and npm fetches it on first Codex start. The pin lives in `scripts/lib/claude-octopus-pin.txt` — single source of truth, read by `mcp_claude.sh`, the integration suite, and the boot-handshake test.

### Coordinating the claude-octopus pin

When claude-octopus ships a new version that cc-suite should adopt:

1. Edit `scripts/lib/claude-octopus-pin.txt` (one line, just the version).
2. Run `bash tests/integration.sh` — T39 actually boots the new pin and exchanges one MCP `initialize` to verify it works.
3. Bump cc-suite's own version per the normal release workflow.

Users get the new pin when they run `claude plugin update cc-suite@xiaolai` followed by `/cc-suite:update` — the second command re-renders the `.codex/config.toml` block in place (the pre-existing block won't be silently preserved because freshen-aware `mcp_claude.sh` detects the pin mismatch and rewrites).

## Smoke Test

After any setup change, run `/cc-suite:status` and confirm every bridge artifact shows `✓`.

## Build / Run

cc-suite is a Claude Code plugin — there is no compilation step. During development, exercise it as follows:

```bash
# Install for the current project (one-time)
claude plugin install cc-suite@xiaolai --scope project

# Refresh the bridge layer in a target project after editing any script
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"

# Run cc-suite commands from the project root
# e.g. /cc-suite:status, /cc-suite:doctor, /cc-suite:repair, /cc-suite:audit-fix
```

## Tests

Run the integration suite (39+ test sections, 197+ assertions):

```bash
bash tests/integration.sh
```

Tests cover every `scripts/*.sh`, the `mcp_codex.sh` migration path, `status.sh` output, freshen semantics for `mcp_claude.sh` (T34–T38), and a real boot-and-handshake against the pinned `claude-octopus` (T39, network-dependent — set `CC_SUITE_SKIP_BOOT_TEST=1` to skip). Add a new `T<N>` section for any new behavior; the suite uses `make_tmp` / `cleanup` / `assert_*` helpers and tallies pass/fail counts in its summary.

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
