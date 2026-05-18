# cc-suite

One Claude Code plugin to synchronize **Claude Code**, **Codex CLI**, and **Gemini CLI** on the same project — and let them delegate work to each other.

## Why

Each tool reads from its own files. `CLAUDE.md`, `AGENTS.md`, `GEMINI.md` sit next to each other and drift. Skills written for Claude aren't visible to Codex. Hooks must be maintained in two places. MCP servers declared in `.mcp.json` are invisible to Codex's `.codex/config.toml`. And there's no built-in way to say "ask Codex for an adversarial review" from Claude, or "ask Claude to plan this" from Codex.

`cc-suite` fixes all of this with a single plugin install:

| Feature | What it does |
|---------|--------------|
| **Single-source instructions** | `AGENTS.md` is the source of truth. `CLAUDE.md` and `GEMINI.md` become thin `@AGENTS.md` imports. |
| **Shared skills** | `.agents/skills/` is symlinked to `.claude/skills/`. Every Claude skill is automatically visible to Codex and Gemini. |
| **Mirrored hooks** | Syncs the five shared hook events from `.claude/settings.json` into `.codex/hooks.json`. Same scripts, both tools. |
| **MCP parity** | Mirrors `.mcp.json` project servers into `.codex/config.toml` so Codex sees the same servers. |
| **Claude → Codex delegation** | Registers the `codex-cli` MCP server in `.mcp.json`. Claude can call `/audit`, `/implement`, `/bug-analyze`, and more directly. Full Codex job tracking, background mode, and stop-time review gate included. |
| **Codex → Claude delegation** | Registers the `claude-code` MCP server (claude-octopus) in `.codex/config.toml`. Codex skills `$claude-review`, `$claude-plan`, `$claude-implement`, `$claude-debug` delegate to Claude and return structured results. |

## Install

```bash
claude plugin install cc-suite@xiaolai --scope project
```

### Prerequisites

- [Codex CLI](https://github.com/openai/codex) installed — required for Claude→Codex delegation commands
- [claude-octopus](https://www.npmjs.com/package/claude-octopus) — required for Codex→Claude delegation. Delivered via `npx -y` at runtime, no pre-install needed. Uses the same credential store as Claude CLI (`~/.claude/.credentials.json`).

## Quick start

```
/cc-suite:init
```

Walks through the full setup: AGENTS.md bridge, MCP server registration, and project audit config. All steps are idempotent — safe to re-run.

After init, edit `AGENTS.md` — all three tools pick up changes automatically.

## Commands

### Bridge management

| Command | What it does |
|---------|--------------|
| `/cc-suite:init` | Full setup: bridge init, Codex MCP, Claude MCP, project config. Idempotent. |
| `/cc-suite:bridge-skills` | Create `.agents/skills → .claude/skills` symlink. |
| `/cc-suite:bridge-hooks` | Mirror `.claude/settings.json` hooks → `.codex/hooks.json`. |
| `/cc-suite:status` | Bridge health, MCP registration, and Codex runtime checks. |
| `/cc-suite:unbridge` | Tear down bridge artifacts, restoring `CLAUDE.md` from `AGENTS.md`. |

### Claude → Codex (audit and implementation)

All commands delegate to Codex via the `codex-cli` MCP server. Codex runs in a sandboxed subprocess; Claude tracks jobs, handles background mode, and can continue threads.

| Command | What it does |
|---------|--------------|
| `/audit` | Run a mini (5-dimension) or full (9-dimension) audit via Codex |
| `/audit-fix` | Audit → fix → verify loop. Iterates up to 3 rounds. |
| `/audit-agent` | Multi-agent parallel audit (coordinator + specialists) |
| `/audit-plugin` | Audit Claude Code plugin artifacts |
| `/audit-skill` | Audit Codex SKILL.md files |
| `/audit-rules` | Audit `.claude/rules/` files |
| `/audit-nlp` | Audit natural-language programming artifacts |
| `/implement` | Implement a feature or change via Codex |
| `/review-plan` | Generate an implementation plan via Codex |
| `/bug-analyze` | Root-cause analysis for a failing test or error |
| `/verify` | Verify that a fix or implementation is correct |
| `/cancel` | Cancel a running Codex job |
| `/continue` | Continue a previous Codex thread by ID |
| `/result` | Show the output of a completed Codex job |
| `/status` | Show active and recent Codex jobs |
| `/preflight` | Check Codex CLI availability and list available models |
| `/setup` | Manage the stop-time review gate |
| `/refresh-knowledge` | Update the Claude Code conventions skill from latest docs |

### Codex → Claude (delegation skills)

When Codex has `claude-code` registered in `.codex/config.toml`, it can invoke these skills to delegate tasks back to Claude:

| Skill | Invocation | What it does |
|-------|-----------|--------------|
| `claude-review` | `$claude-review` | Delegate a code review to Claude. Returns structured findings by severity. |
| `claude-plan` | `$claude-plan` | Ask Claude to produce an implementation plan. Returns numbered steps with file paths. |
| `claude-implement` | `$claude-implement` | Delegate an implementation task to Claude. Claude makes the file changes directly. |
| `claude-debug` | `$claude-debug` | Send a bug or failing test to Claude for root-cause analysis and fix. |

All delegation calls include a provenance disclosure so Claude evaluates the work with full rigor rather than deferring to it.

## Bidirectional delegation

```
Claude Code ──── codex-cli MCP ────►  Codex CLI
              (audit, implement,         │
               review-plan, etc.)        │ claude-code MCP (claude-octopus)
                                         ▼
                                     Claude Code
                                  (review, plan,
                                   implement, debug)
```

Both paths use `npx -y` for delivery — no separate installs. Both use the same shared credential store.

## Bridge table

| What | How |
|------|-----|
| Instructions | `AGENTS.md` → `CLAUDE.md` (`@AGENTS.md`) + `GEMINI.md` (`@AGENTS.md`) |
| Skills | `.agents/skills/ → ../.claude/skills/` symlink |
| Hooks | `.claude/settings.json` (5 shared events) → `.codex/hooks.json` |
| MCP parity | `.mcp.json` entries → `.codex/config.toml [mcp_servers.*]` blocks |
| Codex MCP | `codex-cli` entry in `.mcp.json` (via `mcp_codex.sh`) |
| Claude MCP | `claude-code` entry in `.codex/config.toml` (via `mcp_claude.sh`) |

**Not bridged:**

- **Rules.** Claude's `.claude/rules/*.md` and Codex's `.codex/rules/*.rules` are semantically incompatible. Put shared intent in `AGENTS.md`.
- **Subagents.** Schema and security fields differ per tool. Use Skills with explicit `$name` invocation for portability.

## Idempotency guarantees

All scripts are safe to re-run:

- `AGENTS.md` is never overwritten if it already exists.
- `CLAUDE.md` and `GEMINI.md` are only rewritten when their current content is a bare `@AGENTS.md` import.
- `.agents/skills` symlink is only created if the path doesn't already exist as a real directory.
- `.codex/hooks.json` is only modified when it carries the cc-suite marker; user-owned files are left alone.
- `.codex/config.toml` MCP entries use sentinel blocks; manual entries outside are never touched.

## Codex runtime requirements

`/cc-suite:status` checks these and prints exactly what to add:

- **Project trust.** `.codex/config.toml`, hooks, and rules only activate after Codex marks the project trusted. On a fresh clone, run Codex once and accept the trust prompt — or add `[projects."<abs-path>"] trust_level = "trusted"` to `~/.codex/config.toml`.
- **`plugin_hooks` flag.** Plugin-bundled hooks need `[features] plugin_hooks = true` in `~/.codex/config.toml`.
- **AGENTS.md size.** Codex silently truncates at 32 KiB. Status warns when the limit is exceeded.

## Project layout after `/cc-suite:init`

```text
your-repo/
├── AGENTS.md                         ← edit this; all tools pick it up
├── CLAUDE.md                         → @AGENTS.md
├── GEMINI.md                         → @AGENTS.md
├── .codex-toolkit.md                 ← audit/implement settings
├── .mcp.json                         ← codex-cli MCP server + project servers
├── .gitignore                        ← includes cc-suite sentinel block
├── .claude/
│   └── skills/
│       ├── cc-suite/
│       │   ├── claude-code-conventions/  ← Codex convention knowledge
│       │   ├── claude-review/            ← delegate review to Claude
│       │   ├── claude-plan/              ← delegate planning to Claude
│       │   ├── claude-implement/         ← delegate implementation to Claude
│       │   └── claude-debug/             ← delegate debugging to Claude
│       └── <your-skills>/
├── .agents/
│   └── skills → ../.claude/skills/   ← symlink; Codex + Gemini read here
├── .codex/
│   ├── config.toml                   ← Codex config + project MCP servers
│   │                                    including claude-code (claude-octopus)
│   ├── prompts/.gitkeep
│   └── hooks.json                    ← (if hooks were bridged)
└── .gemini/
    ├── skills/.gitkeep
    └── commands/.gitkeep
```

## License

ISC
