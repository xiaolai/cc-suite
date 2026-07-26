---
name: cc-suite
description: "Project instructions for cc-suite — the Claude Code plugin that bridges Claude Code, Codex CLI, and Antigravity CLI (agy) with single-source AGENTS.md, shared skills, mirrored hooks, and bidirectional MCP delegation; adds a Claude→Grok delegation lane (ACP) and opt-in MCP bridging to more coding agents (Grok Build, opencode, Qwen Code, Kimi CLI)."
---

# Project Instructions

> cc-suite

## Guidelines

- Bump the version in `.claude-plugin/plugin.json` for every release (patch/minor/major per semver). `package.json` must carry the same version — a test enforces it.
- **`main` always equals the newest tag.** Every commit pushed to `main` is a release: bump, commit, `git tag -a vX.Y.Z`, push both. Do not land a change and leave it untagged "until the next real release" — that includes docs-only and `dev-docs/` changes, which take a patch bump. If `git describe --exact-match HEAD` fails, the release is unfinished.
- New commands go in `commands/`; new skills go in `skills/cc-suite/<name>/SKILL.md`.
- All scripts in `scripts/` must be idempotent — running twice must produce the same result.
- Write new project-level instructions into `AGENTS.md` only; never edit `CLAUDE.md` or legacy `GEMINI.md` directly.

## Prerequisites

- **Claude Code** (≥ 2.0) — primary host for all commands and skills
- **Codex CLI** (optional) — required for the `codex-cli` MCP delegation lane and `bridge_hooks.py`
- **Python 3** — required by `scripts/bridge_hooks.py`, MCP projections, and migration helpers
- **Antigravity CLI (`agy`)** (optional) — required for the Google backend, `/cc-suite:agy-preflight`, and headless agy delegation
- **Grok Build (`grok`, xAI)** (optional) — required for the Claude→Grok ACP delegation lane (`/cc-suite:grok`) and `/cc-suite:grok-preflight`
- **Bash** — required by all `scripts/*.sh` files
- **`claude-octopus`** (npm, pinned) — the MCP server cc-suite registers in `.codex/config.toml` so Codex can delegate to Claude. cc-suite does not install it explicitly; `mcp_claude.sh` writes a `npx -y claude-octopus@<pin>` invocation and npm fetches it on first Codex start. The pin lives in `scripts/lib/claude-octopus-pin.txt` — single source of truth, read by `mcp_claude.sh`, the integration suite, and the boot-handshake test.

### Coordinating the claude-octopus pin

When claude-octopus ships a new version that cc-suite should adopt:

1. Edit `scripts/lib/claude-octopus-pin.txt` (one line, just the version).
2. Run `bash tests/integration.sh` — T39 actually boots the new pin and exchanges one MCP `initialize` to verify it works.
3. Bump cc-suite's own version per the normal release workflow.

Users get the new pin when they run `claude plugin update cc-suite@xiaolai` followed by `/cc-suite:update` — the second command re-renders the `.codex/config.toml` block in place (the pre-existing block won't be silently preserved because refresh-aware `mcp_claude.sh` detects the pin mismatch and rewrites).

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
# e.g. /cc-suite:status, /cc-suite:diagnose, /cc-suite:repair, /cc-suite:audit-fix
```

## Tests

Run the integration suite (72 test sections, 386 assertions):

```bash
bash tests/integration.sh
```

Tests cover every `scripts/*.sh`, the Codex and Antigravity MCP projection paths, the multi-tool bridge (`bridge_tools.py` — grok/opencode/qwen/kimi emitters, selection, unbridge), the grok delegation runner and preflight (`grok-runner.mjs`, `grok-preflight.sh`), legacy Gemini cleanup, `status.sh` output, refresh semantics for `mcp_claude.sh`, a real boot-and-handshake against the pinned `claude-octopus` (network-dependent — set `CC_SUITE_SKIP_BOOT_TEST=1` to skip), and the advisor-agent subsystem. Add a new `T<N>` section for any new behavior; the suite uses `make_tmp` / `cleanup` / `assert_*` helpers and tallies pass/fail counts in its summary. Command-file frontmatter is validated separately by `tests/commands.test.mjs` (`node --test`).

## Shared Memory

**Always write new instructions, rules, and memory to `AGENTS.md` only.**

Never modify `CLAUDE.md` or legacy `GEMINI.md` directly — they only import `AGENTS.md`.
This keeps Claude Code, Codex CLI, and Antigravity CLI (`agy`) on the same context.

## Project Structure

- `.claude/` — Claude Code skills, agents, rules, hooks, commands
- `.agents/skills/` — symlink to `.claude/skills/` (Codex skill scan path)
- `.agents/mcp_config.json` — generated Antigravity workspace MCP projection (ignored by default)
- `.codex/prompts/` — Codex slash-command prompts
- `.codex/hooks.json` / `.codex/config.toml` — Codex hooks/config (optional)
- `.mcp.json` — MCP server registrations shared by Claude Code and Codex
- `.cc-suite.md` — per-project config, incl. the `## Enabled Tools` list that selects which agents the multi-tool bridge targets
- `.grok/config.toml` / `opencode.json` / `.qwen/settings.json` / `~/.kimi/mcp.json` — MCP config mirrored into opt-in coding agents by `scripts/bridge_tools.py` (`/cc-suite:bridge-tools`); `.cc-suite-*.provenance.json` sidecars track cc-suite-owned entries and are gitignored
- `~/.gemini/config/` — Antigravity CLI's global MCP/plugin configuration
- `~/.gemini/antigravity-cli/skills/` — Antigravity CLI's global skills configuration
- `.cc-suite/agents/<name>.md` — declared advisor agents (see below)
- `.cc-suite/agents/<name>/timeline/` — per-agent consultation history (gitignored by default)

## Delegation lanes & multi-tool bridge

cc-suite connects agents two ways: **delegation runners** (drive another agent as a subprocess, with job tracking via `scripts/lib/state.mjs` and the shared `/cc-suite:status` / `/result` / `/cancel` / `/continue` surface) and the **config bridge** (mirror the shared MCP/skills/instruction surface into each agent's native files).

**Outbound lanes must refuse the hand-back.** `.agents/skills/` exposes cc-suite's own Claude-facing skills (`audit`, `verify`, `claude-*`) to every agent we delegate to, so a delegated task can be routed straight back to Claude and the independent judgment is lost. Two levers, in `scripts/lib/delegation-boundary.mjs`: `allow_implicit_invocation: false` guards in `skills/cc-suite/*/agents/openai.yaml` (Codex only — Antigravity's skill schema has no equivalent), plus the boundary text prepended to the prompt. The agy and Grok runners inject it in code; the Codex lane carries it as part 3 of the `codex-call.md` preamble.

Delegation lanes:

| Lane | Mechanism | Preflight |
|------|-----------|-----------|
| Claude → Codex | `codex-runner.mjs` (`codex exec`) + `codex-cli` MCP server | `/cc-suite:codex-preflight` (`codex-preflight.sh`) |
| Codex / agy → Claude | pinned `claude-octopus` MCP server (also exposes `claude_code_sessions` / `_transcript`) | — |
| Claude → agy | `agy-runner.mjs` (`agy -p`, conversation recovered by dir-diff) | `/cc-suite:agy-preflight` (`agy-preflight.sh`) |
| Claude → Grok | `grok-runner.mjs` — ACP client driving `grok agent stdio` (`initialize` → `session/new`/`load` → `session/prompt`); `threadId` is the ACP session id | `/cc-suite:grok-preflight` (`grok-preflight.sh`, fast/local) |

All preflight scripts emit the same JSON shape (`status`, `default_model`, `models`, `reasoning_efforts`, `sandbox_levels`, `error_code`). New backend runner ⇒ mirror `agy-runner.mjs` (parseArgs / executeX / runForeground / runBackground / runBackgroundWorker) and add a `<backend>-preflight`.

Multi-tool config bridge (`scripts/bridge_tools.py`, `/cc-suite:bridge-tools`): a declarative tool-profile registry that mirrors the project MCP surface into **Grok Build, opencode, Qwen Code, Kimi CLI** (three emitters: TOML `mcp_servers`, opencode nested `mcp`, JSON `mcpServers`). Tools are selected in `.cc-suite.md`'s `## Enabled Tools`; Claude/Codex/Antigravity keep their existing bridge scripts (`bridged_by: "existing"`). Env values and remote headers are never mirrored (secrets). Design: `dev-docs/supporting-more-coding-agents.md`.

## Advisor Agents (`.cc-suite/agents/`)

Advisor agents are project-scoped value-over-rules personas, each backed by a separately-configured `claude-octopus` MCP server. Both Claude and Codex can consult any advisor via `mcp__<name>__<tool_name>`. Each agent has its own model, system prompt, tool restrictions, working directory, and persistent timeline.

Lifecycle:

- **Create**: `/cc-suite:add-agent <preset>` copies a curated template into `.cc-suite/agents/<name>.md`, or `--custom` walks an interactive wizard. The agent-design skill (`skills/cc-suite/agent-design/SKILL.md`) is the load-bearing reference for what makes a good advisor.
- **List**: `/cc-suite:list-agents` shows every declared advisor and its consult tool.
- **Remove**: `/cc-suite:remove-agent <name>` deletes the file, cleans up MCP registrations, and (optionally) discards the timeline.
- **Re-bridge after editing**: `python3 scripts/bridge_agents.py`. Also runs as part of `/cc-suite:init`, `/cc-suite:repair`, and `/cc-suite:update`.

Mental model: an advisor is a *persona you consult*, not a *subagent that executes work*. If you'd describe the thing as "a person you'd ask for an opinion," it's an advisor. If you'd describe it as "a job you'd hand off," it's a Task subagent. If it's "a rulebook," it's a skill.

The preset library under `templates/agents/` ships starter advisors (`north_star_advisor`, `clarity_reviewer`, `simplicity_advocate`, `security_skeptic`, `deletion_advocate`, `documentation_critic`). Copy and edit — the *value* of your project's advisors is in how they reflect *this project's* priorities, not the generic preset.
