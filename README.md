# cc-suite

[![Validated by NLPM](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/xiaolai/cc-suite/main/nlpm-badge.json)](https://github.com/xiaolai/cc-suite/blob/main/nlpm-badge.json)

One Claude Code plugin to synchronize **Claude Code**, **Codex CLI**, and **Antigravity CLI** (`agy`) on the same project — and let them delegate work to each other. Adds a Claude→**Grok Build** delegation lane (ACP) and opt-in MCP bridging to more coding agents (**opencode**, **Qwen Code**, **Kimi CLI**).

## Why

Each tool reads from its own files. `CLAUDE.md` and `AGENTS.md` sit next to each other and drift. Skills written for Claude aren't visible to Codex. Hooks must be maintained in two places. MCP servers declared in `.mcp.json` are invisible to Codex's `.codex/config.toml`. And there's no built-in way to say "ask Codex for an adversarial review" from Claude, or "ask Claude to plan this" from Codex.

`cc-suite` fixes all of this with a single plugin install:

| Feature | What it does |
|---------|--------------|
| **Single-source instructions** | `AGENTS.md` is the source of truth. `CLAUDE.md` becomes a thin `@AGENTS.md` import. Codex and `agy` read `AGENTS.md` natively. |
| **Shared skills** | `.agents/skills/` is symlinked to `.claude/skills/`. Claude, Codex, and `agy` can use the same workspace skills. |
| **No circular delegation** | Because the skills tree is shared, an agent Claude delegates to can see cc-suite's own Claude-facing skills and hand the task straight back. Every outbound lane blocks that: implicit-invocation guards on the Codex side, and a delegation boundary prepended to the prompt on all lanes. |
| **Mirrored hooks** | Syncs the five shared hook events from `.claude/settings.json` into `.codex/hooks.json`. Same scripts, both tools. |
| **MCP parity** | Mirrors `.mcp.json` project servers into `.codex/config.toml` and `.agents/mcp_config.json` so Codex and `agy` see the same servers. |
| **Claude → Codex delegation** | `/cc-suite:audit`, `/cc-suite:implement`, `/cc-suite:bug-analyze`, and more delegate to Codex through the deadline-bounded CLI runner, with full job tracking, background mode, and the stop-time review gate. The `codex-cli` MCP server registered in `.mcp.json` is an additional direct tool surface. |
| **Codex → Claude delegation** | Registers the `claude-code` MCP server (claude-octopus) in `.codex/config.toml`. Codex skills `$claude-review`, `$claude-plan`, `$claude-implement`, `$claude-debug` delegate to Claude and return structured results. |
| **Codex reads Claude session history** | The same `claude-code` MCP server exposes `claude_code_sessions` (list this repo's Claude Code sessions, or all projects with `all_projects: true`) and `claude_code_transcript` (read a session by id). Codex can enumerate and read past Claude conversations for the repo. |
| **Claude → `agy` delegation** | `scripts/agy-runner.mjs` drives Antigravity CLI headlessly, with the same job tracking, background mode, deadline enforcement, and conversation resume as the Codex runner. |
| **`agy` → Claude delegation** | The same claude-octopus MCP server, registered in `agy`'s workspace config. |
| **Claude → Grok delegation** | `/cc-suite:grok` drives **Grok Build** over the Agent Client Protocol (`scripts/grok-runner.mjs` acts as the ACP client to `grok agent stdio`), with the same job tracking, background mode, deadline enforcement, and session resume as the Codex/agy runners. |
| **More coding agents (opt-in)** | `/cc-suite:bridge-tools` mirrors the project MCP surface into **Grok Build**, **opencode**, **Qwen Code**, and **Kimi CLI** — each selected in `.cc-suite.md`'s `## Enabled Tools` list. Grok, opencode, and Kimi read `AGENTS.md` and shared skills natively, so only MCP config is mirrored (per tool's native format); Qwen Code also gets a skills symlink and an instruction-file setting, since it reads neither by default. China-aware: Qwen/Kimi/opencode work natively in mainland China; Grok is VPN-only. |

## More coding agents (opt-in)

`/cc-suite:init` asks which agents to bridge. It probes `PATH`, pre-selects the ones you actually have installed, shows each tool's China tier, and only writes config for what you pick — a Claude-only project gets no `.codex/` tree. Nothing is forced on except Claude itself, which is the source of truth the others mirror from.

Beyond Claude / Codex / Antigravity, cc-suite can bridge additional agentic CLIs. Most of them read `AGENTS.md` and the shared skills tree on their own, so the bridge only has to mirror MCP — but this is **not** uniform, and the exceptions are called out below. Change the selection any time by re-ticking `.cc-suite.md` and running `/cc-suite:bridge-tools`:

```markdown
## Enabled Tools

- [x] claude
- [x] codex
- [x] antigravity
- [ ] grok
- [x] opencode
- [x] qwen
- [x] kimi
```

Then run `/cc-suite:bridge-tools` (or `python3 scripts/bridge_tools.py`). Each enabled tool gets the project's `.mcp.json` servers plus the pinned `claude-octopus` server — so `claude_code_sessions` / delegation work everywhere — written to its own native MCP config:

| Tool | MCP target | China tier |
|------|-----------|:---:|
| Grok Build (xAI) | `.grok/config.toml` (`[mcp_servers.*]`) | C — VPN-only |
| opencode (SST) | `opencode.json` (`mcp`) | A — native |
| Qwen Code (Alibaba) | `.qwen/settings.json` (`mcpServers`) + `.qwen/skills` symlink | A — native |
| Kimi CLI (Moonshot) | `~/.kimi/mcp.json` | A — native |

Env-var values and remote headers are never written into a mirrored config (potential secrets); the vars that need setting are reported instead. User-managed servers and sibling config keys are preserved; `--status` shows the enabled set, `--unbridge` tears it down. Design notes: `dev-docs/supporting-more-coding-agents.md`.

### What each tool picks up on its own

The bridge only mirrors MCP config. Everything else depends on what the tool already discovers, which varies:

| Tool | Reads `AGENTS.md` | Finds project `.agents/skills/` | cc-suite compensates |
|------|:---:|:---:|---|
| Grok Build | ✅ on its own | ✅ (also `.claude/skills/`) | nothing needed |
| opencode | ✅ on its own | ✅ (also `.claude/skills/`) | nothing needed |
| Kimi CLI | ✅ on its own | ✅ (also `.claude/skills/`) | nothing needed |
| Qwen Code | ⚠️ only once bridged | ❌ `.qwen/skills/` only | `.qwen/skills` symlink **+** `context.fileName` |

**Qwen Code needs help on both axes, and the bridge now provides both.** Its skill scan covers only `~/.qwen/skills/` and `.qwen/skills/`, hence the symlink. Its default context file is `QWEN.md`: `getContextFileNames()` in qwen-code 0.21.0 returns `["QWEN.md"]` whenever the setting is unset, so an unbridged project's `AGENTS.md` is silently ignored — no error, the instructions simply never load. `/cc-suite:bridge-tools` therefore also writes:

```json
{ "context": { "fileName": ["AGENTS.md", "QWEN.md"] } }
```

into `.qwen/settings.json`. `QWEN.md` stays in the list so a project that already has one keeps working, and an existing user value is extended rather than replaced. `--unbridge` removes only the entries it added, and leaves the list alone once you have reordered it.

Grok and opencode were verified directly against the installed CLIs (`grok inspect`, `opencode debug skill`) with a probe skill behind the real `.agents/skills → ../.claude/skills` symlink. The Qwen behaviour was verified against qwen-code 0.21.0's own bundled source — the settings schema defines `context.fileName` as `string | string[]` defaulting to undefined, and the resolver falls back to `["QWEN.md"]`. Kimi is from its published docs; it is not installed here.

### Local models (Ollama)

Ollama is **not** a bridge target and has no profile. It is a model runner, not an agent: no MCP client or server ([still an open request](https://github.com/ollama/ollama/issues/7865)), no `AGENTS.md`, and a home-only `~/.ollama/skills/` with no project scope — so there is no config file for the bridge to write.

It sits one layer below cc-suite instead. `ollama launch <tool>` starts an already-bridged CLI — `opencode`, `codex`, `qwen`, `kimi`, `claude`, and others — pointed at a local model, so the bridged MCP surface and shared skills still apply. It does not touch `opencode.json`, `.codex/config.toml`, or `.mcp.json`, so it will not disturb anything the bridge wrote.

## Claude → Grok delegation (ACP)

Beyond the config bridge, cc-suite can **drive Grok Build as an agent**. `/cc-suite:grok "<prompt>"` sends a task to Grok and returns its answer:

```bash
/cc-suite:grok "Review the changes on this branch for correctness bugs"
/cc-suite:grok --sandbox workspace-write "Add a --json flag to the CLI"
/cc-suite:grok --resume <session-id> "Now also update the tests"
```

`scripts/grok-runner.mjs` acts as an **Agent Client Protocol (ACP) client** to `grok agent stdio` (Grok is the agent, the runner is the client). The ACP handshake — `initialize` → `session/new` (or `session/load` on resume) → `session/prompt` — streams Grok's answer from `session/update` notifications. Because it's a structured protocol, the runner gets reliable session ids (resume carries full context), tool-call visibility, and permission control — richer than a text-scraping CLI runner.

| Flag | Meaning |
|------|---------|
| `--model <id>` | Grok model id (default: Grok's configured default; `grok models` lists them) |
| `--effort <level>` | `none`…`max` reasoning effort (Grok takes an effort flag; agy does not) |
| `--sandbox` | `read-only` (default) · `workspace-write` · `danger-full-access` |
| `--background` / `--resume <id>` | Same job-tracking + resume as the Codex/agy runners |

It shares the runner infrastructure (`/cc-suite:status`, `/cc-suite:result`, `/cc-suite:cancel`) with the other backends — resume a Grok session via `/cc-suite:grok --resume <id>` (`/cc-suite:continue` resumes Codex threads only) — and gates on `/cc-suite:grok-preflight` — a fast, **local** readiness check (binary + auth, no network round-trip) that fails fast with a `grok login` hint instead of hanging until the deadline. Pair it with the MCP bridge (`grok` enabled in `## Enabled Tools`) so Grok can call *back* into Claude via the `claude-code` server — a full round trip. Requires the `grok` binary on PATH ([install](https://x.ai/cli)).

## Antigravity CLI (`agy`)

Google moved consumer Gemini CLI access to [Antigravity CLI](https://antigravity.google)
(binary: `agy`) on **2026-06-18**. See Google's [transition announcement](https://developers.googleblog.com/en/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)
and the [official migration guide](https://antigravity.google/docs/gcli-migration).
Enterprise Gemini CLI and paid API access remain available, so cc-suite treats
Gemini files as an explicit legacy path rather than deleting custom content. New
projects use `AGENTS.md` and `.agents/` workspace assets. Run
`/cc-suite:migrate-google` for an existing Gemini setup; the command asks before
running `agy plugin import gemini` and preserves custom legacy files by default.

What works, and what does not:

| | Status |
|---|---|
| `AGENTS.md` as shared context | ✅ native — no bridging needed |
| Claude → `agy` delegation | ✅ `scripts/agy-runner.mjs` (job tracking, background, resume) |
| `agy` → Claude delegation | ✅ register claude-octopus in `.agents/mcp_config.json` |
| Project-scoped skills (`.agents/skills/`) | ✅ native workspace path |
| Project-scoped MCP servers (`.agents/mcp_config.json`) | ✅ native workspace path |

Current Antigravity documentation defines `.agents/skills/` and
`.agents/mcp_config.json` as workspace paths. cc-suite uses those paths and keeps
the generated MCP config ignored by default because server definitions may contain
credentials or machine-specific paths. Global configuration remains supported for
users who want servers or skills shared across every workspace.

Two further `agy` limitations shape the runner: there is **no reasoning-effort flag**
(effort is encoded in the model name, e.g. `Gemini 3.1 Pro (High)`), and there is
**no machine-readable output** — `agy -p` prints prose, so there is no cost or
turn accounting, and the conversation id must be recovered by diffing
`~/.gemini/antigravity-cli/conversations/`. That recovery is best-effort: when two
`agy` runs finish concurrently the diff is ambiguous, and the runner records no
conversation id rather than attach the wrong one.

## Install

Two install paths — both reach the same code. Pick one:

**Via Anthropic's official community marketplace** (curated; updates lag the maintainer's marketplace by up to ~24h):

```bash
claude plugin marketplace add anthropics/claude-plugins-community
claude plugin install cc-suite@claude-community --scope project
```

**Via the xiaolai marketplace** (latest version lands here first):

```bash
claude plugin marketplace add xiaolai/claude-plugin-marketplace
claude plugin install cc-suite@xiaolai --scope project
```

### Prerequisites

- [Codex CLI](https://github.com/openai/codex) installed — required for Claude→Codex delegation commands
- [Antigravity CLI](https://github.com/google-antigravity/antigravity-cli) (`agy`) installed — required for Google-backed delegation and `/cc-suite:agy-preflight`
- [Grok Build](https://x.ai/cli) (`grok`, xAI) installed — required for the Claude→Grok ACP delegation lane (`/cc-suite:grok`) and `/cc-suite:grok-preflight`
- [claude-octopus](https://www.npmjs.com/package/claude-octopus) — required for Codex→Claude delegation. Delivered via `npx -y` at runtime, no pre-install needed. Uses the same credential store as Claude CLI (`~/.claude/.credentials.json`).

## Quick start

```
/cc-suite:init
```

Walks through the full setup: AGENTS.md bridge, MCP server registration, and project audit config. All steps are idempotent — safe to re-run. Re-running with an existing `.cc-suite.md` tops up the config non-destructively and re-runs the non-interactive bridge steps, so missing artifacts (e.g. after a fresh clone) are recreated.

After init, edit `AGENTS.md` — all three tools pick up changes automatically.

## Commands

### Bridge management

| Command | What it does |
|---------|--------------|
| `/cc-suite:init` | Full setup: bridge init, Codex MCP, Claude MCP, project config. Idempotent. |
| `/cc-suite:bridge-skills` | Create `.agents/skills → .claude/skills` symlink. |
| `/cc-suite:bridge-hooks` | Mirror `.claude/settings.json` hooks → `.codex/hooks.json`. |
| `/cc-suite:sync-mcp` | Sync Claude's `.mcp.json` project servers → Codex and Antigravity workspace configs. Alias: `/cc-suite:bridge-mcp`. |
| `/cc-suite:bridge-tools` | Mirror the project MCP surface into opt-in coding agents (Grok Build, opencode, Qwen Code, Kimi CLI) selected in `.cc-suite.md`'s `## Enabled Tools`. |
| `/cc-suite:migrate-google` | Convert legacy Gemini CLI extensions/configuration and establish the agy workspace bridge. |
| `/cc-suite:status` | Show active and recent delegation jobs (Codex, agy, Grok). Bridge health and MCP registration checks live in `/cc-suite:diagnose`. |
| `/cc-suite:unbridge` | Tear down bridge artifacts, restoring `CLAUDE.md` from `AGENTS.md`. |

### Claude → Codex (audit and implementation)

Codex-backed commands delegate through the CLI runner (`scripts/codex-runner.mjs`, which shells out to `codex exec` — deadline-bounded, killable, with a streamed heartbeat); the `codex-cli` MCP server registered in `.mcp.json` is a separate, direct tool surface, not the delegation path. Codex runs in a sandboxed subprocess; Claude tracks jobs, handles background mode, and can continue threads. `/cc-suite:audit-plugin` is the local exception — it analyzes plugin artifacts without an external model call.

| Command | What it does |
|---------|--------------|
| `/cc-suite:audit` | Run a mini (5-dimension) or full (9-dimension) audit via Codex |
| `/cc-suite:audit-fix` | Audit → fix → verify loop. Iterates up to 3 rounds. |
| `/cc-suite:audit-agent` | Audit Claude Code agent definitions (triggering, prompt quality, tools, examples) |
| `/cc-suite:audit-plugin` | Audit Claude Code plugin artifacts (local analysis, no Codex call) |
| `/cc-suite:audit-skill` | Audit Claude Code SKILL.md files |
| `/cc-suite:audit-rules` | Audit `.claude/rules/` files |
| `/cc-suite:audit-nlp` | Audit natural-language programming artifacts |
| `/cc-suite:implement` | Implement a feature or change via Codex |
| `/cc-suite:review-plan` | Send a plan to Codex for architectural review |
| `/cc-suite:bug-analyze` | Root-cause analysis for a failing test or error |
| `/cc-suite:verify` | Verify that a fix or implementation is correct |
| `/cc-suite:cancel` | Cancel a running Codex job |
| `/cc-suite:continue` | Continue a previous Codex thread by ID (Codex threads only — Grok/agy resume via their own commands' `--resume`) |
| `/cc-suite:result` | Show the output of a completed job |
| `/cc-suite:status` | Show active and recent delegation jobs |
| `/cc-suite:codex-preflight` | Check Codex CLI availability and list available models |
| `/cc-suite:agy-preflight` | Check Antigravity CLI availability, authentication, models, and workspace MCP parity |
| `/cc-suite:agy` | Delegate a bounded prompt directly to Antigravity CLI with shared job tracking |
| `/cc-suite:grok-preflight` | Check Grok Build readiness (binary, auth, models) — fast and local, no network |
| `/cc-suite:grok` | Delegate a bounded prompt to Grok Build over ACP with shared job tracking |
| `/cc-suite:setup` | Manage the stop-time review gate |
| `/cc-suite:refresh-knowledge` | Update the Claude Code conventions skill from latest docs |

### Codex → Claude (delegation skills)

When Codex has `claude-code` registered in `.codex/config.toml`, it can invoke these skills to delegate tasks back to Claude:

| Skill | Invocation | What it does |
|-------|-----------|--------------|
| `claude-review` | `$claude-review` | Delegate a code review to Claude. Returns structured findings by severity. |
| `claude-plan` | `$claude-plan` | Ask Claude to produce an implementation plan. Returns numbered steps with file paths. |
| `claude-implement` | `$claude-implement` | Delegate an implementation task to Claude. Claude makes the file changes directly. |
| `claude-debug` | `$claude-debug` | Send a bug or failing test to Claude for root-cause analysis and fix. |

All delegation calls include a provenance disclosure so Claude evaluates the work with full rigor rather than deferring to it.

Codex model selection is dynamic: `/cc-suite:codex-preflight` reads the local Codex model
catalog, excludes review-only entries from the default, and prefers the catalog's
latest marker followed by the newest model version. No model name is hardcoded in
the plugin, so a Codex catalog refresh automatically moves the default forward.
`/cc-suite:init` extends this to the project config: by default it writes the policy
value `latest` into `.cc-suite.md` (re-resolved via preflight by every command that
goes through the shared model selection), and only writes a concrete model slug when
you explicitly choose to pin one. If a pinned model later disappears from the catalog,
model-selecting commands warn, recommend the current default, and offer to repair the
config line; `/cc-suite:diagnose` flags the same stale pin with a one-line fix. Configs
generated by older cc-suite versions contain a resolved slug, which is now read as a
deliberate pin — edit the `Default model` line to `latest` to switch to tracking.

Beyond delegation, the `claude-code` MCP server also lets Codex **read Claude's session history** directly (no skill needed — these are plain MCP tools Codex discovers automatically):

| Tool | What it does |
|------|--------------|
| `claude_code_sessions` | List Claude Code sessions, newest first. Scoped to the current repo by default; pass `all_projects: true` to list every project on the machine. Returns `session_id`, title, first prompt, git branch, and timestamps. |
| `claude_code_transcript` | Read a full session transcript by `session_id` (from `claude_code_sessions`). |

> Privacy note: reading a transcript surfaces that conversation's content to Codex (and thus to OpenAI). Session listing is repo-scoped by default; `all_projects: true` widens it to every project on the machine.

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

The Codex→Claude path delivers `claude-octopus` via `npx -y` at runtime — no pre-install. The Claude→Codex path uses the Codex CLI's own built-in MCP server (`codex mcp-server`), so it needs the `codex` binary on PATH. Each side reuses its host CLI's existing login — no separate credentials.

## Bridge table

| What | How |
|------|-----|
| Instructions | `AGENTS.md` → `CLAUDE.md` (`@AGENTS.md`); Codex and `agy` read `AGENTS.md` directly |
| Skills | `.agents/skills/ → ../.claude/skills/` symlink (Codex + agy workspace skills) |
| Hooks | `.claude/settings.json` (5 shared events) → `.codex/hooks.json` |
| MCP parity | `.mcp.json` entries → `.codex/config.toml [mcp_servers.*]` + `.agents/mcp_config.json` |
| Codex MCP | `codex-cli` entry in `.mcp.json` (via `mcp_codex.sh`) |
| Claude MCP | `claude-code` entry in `.codex/config.toml` (via `mcp_claude.sh`) and `.agents/mcp_config.json` (via `bridge_mcp.sh`) |

**Not bridged:**

- **Rules.** Claude's `.claude/rules/*.md` and Codex's `.codex/rules/*.rules` are semantically incompatible. Put shared intent in `AGENTS.md`.
- **Subagents.** Schema and security fields differ per tool. Use Skills with explicit `$name` invocation for portability.
- **Google legacy files.** Existing `GEMINI.md` and `.gemini/` content is not deleted automatically. Migrate it deliberately, then use `/cc-suite:unbridge` only for generated/bare legacy artifacts.

## Idempotency guarantees

All scripts are safe to re-run:

- `AGENTS.md` is never overwritten if it already exists.
- `CLAUDE.md` is only rewritten when its current content is a bare `@AGENTS.md` import.
- `.agents/skills` symlink is only created if the path doesn't already exist as a real directory.
- `.codex/hooks.json` is only modified when it carries the cc-suite marker; user-owned files are left alone.
- `.codex/config.toml` MCP entries use sentinel blocks; manual entries outside are never touched.
- `.agents/mcp_config.json` is refreshed only when its cc-suite provenance file is present; user-managed configs are refused rather than overwritten.

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
├── .cc-suite.md                 ← audit/implement settings
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
├── .cc-suite/
│   ├── agents/                       ← your advisor agents; commit these
│   ├── provenance                    ← what init created; local, ignored
│   └── original-claude.md            ← pre-bridge CLAUDE.md backup; ignored
├── .agents/
│   ├── skills → ../.claude/skills/   ← symlink; Codex + agy read here
│   └── mcp_config.json               ← generated from .mcp.json; ignored by default
└── .codex/                           ← only when Codex is one of the bridges
    ├── config.toml                   ← Codex config + project MCP servers
    │                                    including claude-code (claude-octopus)
    ├── prompts/.gitkeep
    └── hooks.json                    ← (if hooks were bridged)
```

Only the bridges you picked at `init` are written. A Claude-only project has no
`.codex/` at all — cc-suite's own bookkeeping lives in `.cc-suite/`, never in
another tool's directory.

`agy` reads `AGENTS.md` natively. Workspace skills and MCP servers live under
`.agents/`; global settings remain under `~/.gemini/` when intentionally shared.

## License

ISC
