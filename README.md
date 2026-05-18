# cc-bridge

Claude Code plugin that bridges a repo's AI-assistant configuration across
**Claude Code**, **Codex CLI**, and **Gemini CLI** so all three tools share
the same context, skills, hooks, and MCP servers without hand-editing.

## What it bridges

| Bridge | Mechanism |
|---|---|
| **Instructions** | Single `AGENTS.md` as source of truth. `CLAUDE.md` and `GEMINI.md` become thin `@AGENTS.md` imports. Codex reads `AGENTS.md` natively. |
| **Skills** | `.agents/skills/` is a symlink to `.claude/skills/`. Codex and Gemini CLI both scan `.agents/skills/`; every Claude skill is automatically visible. |
| **Commands → Skills** | `.claude/commands/*.md` are converted to `.claude/skills/cmd-<name>/` (so Claude sees them too) and exposed to Codex via the `.agents/skills/ → .claude/skills/` symlink. Invoke explicitly with `$cmd-<name>` in Codex. Codex has no project-scoped slash commands; Skills are the portable equivalent. |
| **Hooks** | Mirrors the five overlapping events from `.claude/settings.json` into `.codex/hooks.json`. The same `.claude/hooks/*.py` scripts run from both tools. |
| **MCP (Claude → Codex tool)** | Adds the `codex-cli` MCP server to `.mcp.json` so Claude Code can invoke Codex as a tool. |
| **MCP (project servers → Codex config)** | Mirrors `.mcp.json` server entries into `.codex/config.toml` `[mcp_servers.*]` blocks so Codex can use the same project MCP servers. |
| **Codex / Gemini scaffolding** | Creates `.codex/prompts/`, `.codex/config.toml`, `.gemini/skills/`, `.gemini/commands/` with stubs and `.gitkeep`. |
| **gitignore** | Idempotently appends a `# >>> cc-bridge >>>` block (public or private mode). |

## What's not bridged

- **Rules.** Claude's `.claude/rules/*.md` (prose authoring guidance) and Codex's `.codex/rules/*.rules` (Starlark exec-policy) serve different purposes and aren't convertible. Put shared intent in `AGENTS.md`; write tool-specific rules by hand.
- **Codex subagents.** Claude's `.claude/agents/*.md` and Codex's `[agents.*]` in `config.toml` have different schemas and security-relevant fields. Migrate manually if needed.

## Install

```bash
# from the project you want to bridge:
claude plugin install cc-bridge@xiaolai --scope project
```

Or from a local checkout:

```bash
claude plugin install /path/to/cc-bridge --scope project
```

## Slash commands

| Command | Effect |
|---|---|
| `/cc-bridge:init` | Full bridge setup. Idempotent. Migrates existing `CLAUDE.md` → `AGENTS.md`. Optional steps for MCP mirror, hooks, and commands→skills. Args: `--private`, `--description "..."`. |
| `/cc-bridge:bridge-skills` | Create the `.agents/skills` → `.claude/skills` symlink only. |
| `/cc-bridge:bridge-hooks` | Mirror `.claude/settings.json` hooks → `.codex/hooks.json` (shared events only). |
| `/cc-bridge:status` | Show bridge state, MCP parity, and Codex runtime checks (trust, plugin_hooks, AGENTS.md size). |
| `/cc-bridge:unbridge` | Tear down bridge artifacts with confirmation. AGENTS.md content is restored to CLAUDE.md automatically when CLAUDE.md is a bare `@import`; otherwise backed up as `AGENTS.md.cc-bridge-backup`. `.codex/hooks.json` and `.codex/config.toml` are only modified if cc-bridge generated their content. |

## Scripts

All scripts are idempotent and safe to re-run directly:

| Script | What it does |
|---|---|
| `scripts/init.sh` | Core bridge: `AGENTS.md`, imports, scaffolding, symlink, `.gitignore` block |
| `scripts/bridge_skills.sh` | `.agents/skills` → `.claude/skills` symlink |
| `scripts/bridge_hooks.py` | `.claude/settings.json` hooks → `.codex/hooks.json` (shared events only) |
| `scripts/bridge_mcp.sh` | `.mcp.json` servers → `.codex/config.toml` `[mcp_servers.*]` blocks |
| `scripts/bridge_commands.sh` | `.claude/commands/*.md` → `.agents/skills/cmd-*/SKILL.md` (explicit invocation) |
| `scripts/mcp_codex.sh` | Adds `codex-cli` server to `.mcp.json` (Claude can invoke Codex as tool) |
| `scripts/status.sh` | Full status report including MCP parity and Codex runtime state |
| `scripts/unbridge.sh` | Tears down bridge artifacts; restores `CLAUDE.md` content first |

## How shared hooks work

Claude Code and Codex CLI use the same hook event names and handler format for the most common events. The same shell/Python scripts in `.claude/hooks/` run from both tools.

| Event | Claude | Codex |
|---|---|---|
| `SessionStart` | ✓ | ✓ |
| `UserPromptSubmit` | ✓ | ✓ |
| `PreToolUse` | ✓ | ✓ |
| `PostToolUse` | ✓ | ✓ |
| `Stop` | ✓ | ✓ |
| `Notification` | ✓ | — |
| `SubagentStop` | ✓ | — |
| `SessionEnd` | ✓ | — |
| `PermissionRequest` | — | ✓ |

The `bridge-hooks` command copies the five shared events; Claude-only events are skipped with a notice.

## How the commands bridge works

Codex's custom prompts (its equivalent of slash commands) are user-scope only — they live in `~/.codex/prompts/` and are not repo-scoped. `bridge_commands.sh` converts each `.claude/commands/<name>.md` to a Skill **under `.claude/skills/`** (so Claude sees them too) and reaches Codex via the `.agents/skills/ → .claude/skills/` symlink:

```
.claude/skills/cmd-<name>/     # physical location (Claude reads here)
  SKILL.md                     # adapted from .claude/commands/<name>.md
  agents/openai.yaml           # allow_implicit_invocation: false

.agents/skills/cmd-<name>/     # virtual view via symlink (what Codex reads)
```

Users invoke with `$cmd-<name>` in Codex rather than `/cmd-name`. Skills are repo-scoped and survive clones.

## Codex runtime caveats

`/cc-bridge:status` checks these automatically:

- **Project trust.** `.codex/config.toml`, hooks, and rules only activate after Codex marks the project trusted (first-run prompt, or add `[projects."<path>"] trust_level = "trusted"` to `~/.codex/config.toml` manually).
- **plugin_hooks flag.** Plugin-bundled hooks require `[features] plugin_hooks = true` in `~/.codex/config.toml`.
- **AGENTS.md size.** Codex silently truncates files larger than 32 KiB. Status warns when the limit is approached.

## MCP architecture

Two separate directions, two separate scripts:

```
Claude Code ──(.mcp.json)──────────────────► can invoke codex-cli as tool
                                              (mcp_codex.sh)

Codex CLI   ──(.codex/config.toml)─────────► can use project MCP servers
                                              (bridge_mcp.sh mirrors .mcp.json)
```

These tools do not cross-read each other's MCP config files.

## Idempotency

All operations are safe to re-run:

- `AGENTS.md` is never overwritten if it already exists.
- `CLAUDE.md` is only rewritten if its content was just migrated to `AGENTS.md` in the same run.
- `.agents/skills` symlink is only created if the path doesn't exist as a real directory.
- `.codex/hooks.json` is never silently overwritten; if present, the new mirror goes to `.codex/hooks.cc-bridge.json` for review.
- `.codex/config.toml` MCP entries use a sentinel block; manual entries outside it are never touched.
- `.gitignore` block is only added if the cc-bridge sentinel is absent; re-running with a different `--private` mode replaces the block cleanly.
- On unbridge: `.codex/hooks.json` is only removed if it contains exclusively cc-bridge events. `.codex/config.toml` has only the cc-bridge-mcp block removed; other config is preserved.

## Layout (after running `/cc-bridge:init` with all optional steps)

```text
your-repo/
├── AGENTS.md                    # canonical instructions (single source)
├── CLAUDE.md                    # @AGENTS.md
├── GEMINI.md                    # @AGENTS.md
├── .mcp.json                    # codex-cli MCP server + project servers
├── .gitignore                   # includes cc-bridge block
├── .claude/
│   └── skills/
│       ├── <your-skill>/        # existing Claude skills
│       └── cmd-<name>/          # skills generated from .claude/commands/
│           ├── SKILL.md
│           └── agents/openai.yaml
├── .agents/
│   └── skills -> ../.claude/skills/   # symlink — Codex + Gemini scan path
├── .codex/
│   ├── config.toml              # Codex config + mirrored MCP servers
│   ├── prompts/.gitkeep
│   └── hooks.json               # (if hooks bridged)
└── .gemini/
    ├── skills/.gitkeep
    └── commands/.gitkeep
```

## License

MIT (or pick one before release).
