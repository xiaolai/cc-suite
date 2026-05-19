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

## Smoke Test

After any setup change, run `/cc-suite:status` and confirm every bridge artifact shows `✓`.

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
