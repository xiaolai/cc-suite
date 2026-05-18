# cc-bridge

Claude Code plugin that keeps **Claude Code**, **Codex CLI**, and **Gemini CLI** synchronized on the same project: one set of instructions, shared skills, mirrored hooks and MCP servers — no hand-editing of three separate config trees.

## Why

Each tool reads from its own files. `CLAUDE.md`, `AGENTS.md`, `GEMINI.md` sit next to each other and drift. Skills written for Claude aren't visible to Codex. Hooks have to be maintained in two places. MCP servers declared in `.mcp.json` are invisible to Codex's `.codex/config.toml`.

`cc-bridge` sets this up once and keeps it consistent:

| Bridge | Mechanism |
|---|---|
| **Instructions** | `AGENTS.md` is the single source of truth. `CLAUDE.md` and `GEMINI.md` become thin `@AGENTS.md` imports. Codex reads `AGENTS.md` natively. |
| **Skills** | `.agents/skills/` is symlinked to `.claude/skills/`. Codex and Gemini both scan `.agents/skills/`; every Claude skill is automatically visible. |
| **Commands → Skills** | `.claude/commands/*.md` are converted to `.claude/skills/cmd-<name>/SKILL.md` so Codex can reach them via the symlink. Invoke in Codex as `$cmd-<name>`. |
| **Hooks** | Mirrors the five events both tools share from `.claude/settings.json` into `.codex/hooks.json`. The same `.claude/hooks/` scripts run from both tools. |
| **MCP (Claude → Codex as tool)** | Adds the `codex-cli` MCP server to `.mcp.json` so Claude Code can call Codex as a tool. |
| **MCP (project servers → Codex)** | Mirrors `.mcp.json` server entries into `.codex/config.toml` `[mcp_servers.*]` blocks so Codex sees the same servers. |
| **Scaffolding** | Creates `.codex/prompts/`, `.codex/config.toml`, `.gemini/skills/`, `.gemini/commands/` stubs and `.gitignore` block. |

**Not bridged:**

- **Rules.** Claude's `.claude/rules/*.md` (prose guidance) and Codex's `.codex/rules/*.rules` (Starlark exec-policy) are semantically incompatible. Put shared intent in `AGENTS.md`; write tool-specific rules by hand.
- **Subagents.** Schema and security-relevant fields differ between tools. Fold into Skills with explicit `$name` invocation if portability matters.

## Install

```bash
# from the project you want to bridge:
claude plugin install cc-bridge@xiaolai --scope project

# or from a local checkout:
claude plugin install /path/to/cc-bridge --scope project
```

## Quick start

```
/cc-bridge:init
```

That's it. The command walks you through the full setup interactively, migrating any existing `CLAUDE.md` to `AGENTS.md`, creating imports for the other tools, and offering to wire up MCP, hooks, and commands as skills.

After init, edit `AGENTS.md` — all three tools pick up changes automatically.

## Slash commands

| Command | What it does |
|---|---|
| `/cc-bridge:init` | Full bridge setup. Idempotent. Optional args: `--private`, `--description "..."`. |
| `/cc-bridge:bridge-skills` | Create the `.agents/skills → .claude/skills` symlink only. |
| `/cc-bridge:bridge-hooks` | Mirror `.claude/settings.json` hooks → `.codex/hooks.json` (shared events only). |
| `/cc-bridge:status` | Show bridge state, MCP parity, and Codex runtime checks (trust, `plugin_hooks`, AGENTS.md size). |
| `/cc-bridge:unbridge` | Tear down bridge artifacts. AGENTS.md content is restored to CLAUDE.md automatically. `.claude/` and `.mcp.json` are never touched. |

## Scripts

All scripts are idempotent and safe to re-run directly (no plugin required):

| Script | What it does |
|---|---|
| `scripts/init.sh` | Core bridge: AGENTS.md, imports, scaffolding, symlink, .gitignore block |
| `scripts/bridge_skills.sh` | `.agents/skills → .claude/skills` symlink |
| `scripts/bridge_hooks.py` | `.claude/settings.json` hooks → `.codex/hooks.json` (shared events only) |
| `scripts/bridge_mcp.sh` | `.mcp.json` servers → `.codex/config.toml` `[mcp_servers.*]` blocks |
| `scripts/bridge_commands.sh` | `.claude/commands/*.md` → `.claude/skills/cmd-*/SKILL.md` |
| `scripts/mcp_codex.sh` | Adds `codex-cli` server to `.mcp.json` (Claude can invoke Codex as tool) |
| `scripts/status.sh` | Full status report including MCP parity and Codex runtime state |
| `scripts/unbridge.sh` | Tears down bridge artifacts; restores CLAUDE.md content first |

## Shared hooks

Claude Code and Codex CLI use the same hook event names and handler format for five events. The same `.claude/hooks/` scripts run unmodified from both tools.

| Event | Claude | Codex |
|---|---|---|
| `SessionStart` | ✓ | ✓ |
| `UserPromptSubmit` | ✓ | ✓ |
| `PreToolUse` | ✓ | ✓ |
| `PostToolUse` | ✓ | ✓ |
| `Stop` | ✓ | ✓ |
| `Notification` | ✓ | — skipped |
| `SubagentStop` | ✓ | — skipped |
| `SessionEnd` | ✓ | — skipped |

`bridge-hooks` copies the five shared events; Claude-only events are skipped with a printed notice. Existing `.codex/hooks.json` is never silently overwritten — if it exists, the output goes to `.codex/hooks.cc-bridge.json` for review.

## Commands as skills

Codex has no project-scoped slash commands. `bridge_commands.sh` converts each `.claude/commands/<name>.md` to a skill that lives under `.claude/skills/` (so Claude sees it too) and reaches Codex via the `.agents/skills/` symlink:

```
.claude/skills/cmd-<name>/     # physical location (Claude + Claude slash commands)
  SKILL.md                     # body from .claude/commands/<name>.md
  agents/openai.yaml           # allow_implicit_invocation: false

.agents/skills/cmd-<name>/     # virtual view via symlink (what Codex reads)
```

Users invoke with `$cmd-<name>` in Codex rather than `/cmd-name`. Skills are repo-scoped and survive clones.

## MCP architecture

Two directions, two scripts, no cross-read between tools:

```
Claude Code  ──(.mcp.json)──────────────────►  can call codex-cli as MCP tool
                                                (mcp_codex.sh)

Codex CLI    ──(.codex/config.toml)──────────►  can use project MCP servers
                                                (bridge_mcp.sh mirrors .mcp.json)
```

`bridge_mcp.sh` uses a sentinel-guarded block in `config.toml` so re-runs rewrite only the cc-bridge entries. Env var values are never mirrored (security); the script emits TOML comments documenting the required var names instead.

## Idempotency guarantees

All operations are safe to re-run:

- `AGENTS.md` is never overwritten if it already exists.
- `CLAUDE.md` and `GEMINI.md` are only rewritten when their current content is already a bare `@AGENTS.md` import.
- `.agents/skills` symlink is only created when the path doesn't exist as a real directory.
- `.codex/hooks.json` is only modified when it carries the cc-bridge marker; user-owned files are never touched.
- `.codex/config.toml` MCP entries use a sentinel block; manual entries outside it are never touched.
- `unbridge.sh` only removes `.codex/hooks.json` when it was written by cc-bridge (carries `_cc_bridge_version`) AND contains exclusively shared-event hooks.

## Codex runtime requirements

`/cc-bridge:status` checks these automatically and tells you exactly what to add:

- **Project trust.** `.codex/config.toml`, hooks, and rules only activate after Codex marks the project trusted. On a fresh clone a collaborator must accept the trust prompt (or add `[projects."<abs-path>"] trust_level = "trusted"` to `~/.codex/config.toml` manually). Skills are the only bridge artifact that works without trust.
- **`plugin_hooks` flag.** Plugin-bundled hooks require `[features] plugin_hooks = true` in `~/.codex/config.toml`.
- **AGENTS.md size.** Codex silently truncates at 32 KiB. Status warns when the limit is exceeded.

## Project layout after `/cc-bridge:init`

```text
your-repo/
├── AGENTS.md                    ← edit this; all three tools pick it up
├── CLAUDE.md                    → @AGENTS.md
├── GEMINI.md                    → @AGENTS.md
├── .mcp.json                    ← codex-cli MCP server + project servers
├── .gitignore                   ← includes cc-bridge sentinel block
├── .claude/
│   └── skills/
│       ├── <your-skill>/        ← existing Claude skills
│       └── cmd-<name>/          ← generated from .claude/commands/
│           ├── SKILL.md
│           └── agents/openai.yaml
├── .agents/
│   └── skills → ../.claude/skills/    ← symlink; Codex + Gemini read here
├── .codex/
│   ├── config.toml              ← Codex config + mirrored MCP servers
│   ├── prompts/.gitkeep
│   └── hooks.json               ← (if hooks were bridged)
└── .gemini/
    ├── skills/.gitkeep
    └── commands/.gitkeep
```

## Deep reference

`dev-docs/bridging-claude-and-codex.md` covers the full technical picture: file formats for each tool, exact schema diffs, Codex trust model internals, Gemini CLI specifics, discovery path reference, common silent failures, and prior art.

## License

ISC
