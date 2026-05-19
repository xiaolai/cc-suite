---
name: claude-code-conventions
description: "Canonical reference for Claude Code plugin artifact schemas, hook events, frontmatter fields, and naming conventions. Used to inject domain knowledge into Codex audit prompts. Run /cc-suite:refresh-knowledge to update from latest docs."
version: 0.2.0
---

# Claude Code Plugin Conventions Reference

> **Purpose**: This skill is the single source of truth for Claude Code artifact conventions. Audit commands inject this content into Codex's `developer-instructions` so Codex can accurately validate Claude Code artifacts despite having no native knowledge of the platform.
>
> **Freshness**: Last updated 2026-03-25 from context7 (`/websites/code_claude_en_plugins-reference`, `/websites/code_claude_en_plugins`). Run `/cc-suite:refresh-knowledge` to refresh.

## When to Use

Load this skill when:
- Auditing Claude Code plugin artifacts (commands, agents, skills, hooks, plugin.json)
- Validating frontmatter fields against the official schema
- Checking hook event names, types, and output formats
- Authoring new plugin artifacts and need the canonical field reference
- Running `/cc-suite:audit-plugin`, `/cc-suite:audit-command`, `/cc-suite:audit-agent`, or `/cc-suite:audit-skill`

## plugin.json Schema

**Only `name` is strictly required.** Version and description are strongly recommended but optional.

Required:
- `name` (string): plugin identifier, kebab-case. Used for namespacing (e.g., `plugin-dev:agent-creator`)

Recommended:
- `version` (string): semver `X.Y.Z`. If also set in marketplace entry, plugin.json takes precedence
- `description` (string): brief purpose

Optional metadata:
- `author` (object): `{ "name": "string", "email": "string", "url": "string" }`
- `homepage` (string): URL to plugin docs
- `repository` (string): URL to source code
- `license` (string): SPDX identifier (e.g., `"MIT"`, `"Apache-2.0"`)
- `keywords` (string[]): discovery tags

Component path fields (string, string[], or inline object):
- `commands` — path(s) to command files. Default: `./commands/` (auto-discovered)
- `agents` — path(s) to agent files. Default: `./agents/` (auto-discovered)
- `skills` — path(s) to skill directories. Default: `./skills/` (auto-discovered)
- `hooks` — path to hooks config OR inline hooks object. Default: `./hooks/hooks.json`
- `mcpServers` — path to MCP config OR inline object. Default: `./.mcp.json`
- `lspServers` — path to LSP config. Default: `./.lsp.json`
- `outputStyles` — path to output style definitions

If omitted, components are auto-discovered from default locations.

## Command Frontmatter

Location: `commands/<name>.md` (auto-discovered from `commands/` directory)

Required fields:
- `description` (string): shown in `/help`, must be specific and actionable

Optional fields:
- `argument-hint` (string): usage pattern (e.g., `"<file> [--flag]"`)
- `allowed-tools` (string[]): restrict available tools. Omit for all tools
- `model` (string): override session model (`haiku`, `sonnet`, `opus`)
- `user-invocable` (boolean): `false` for shared partials in `commands/shared/`

Body: imperative instructions FOR Claude, not documentation TO user.

## Shared Partial Frontmatter

Location: `commands/shared/<name>.md`

Required:
- `user-invocable: false`

Referenced by commands to eliminate boilerplate. Not shown in `/help`.

## Agent Frontmatter

Location: `agents/<name>.md` (auto-discovered)

Official documented fields:
- `name` (string): agent identifier
- `description` (string): what the agent does and when to invoke it

Widely-used convention fields (not in official docs but used by all xiaolai plugins and numerous community plugins):
- `model` (string): `haiku`, `sonnet`, `opus`
- `color` (string): UI color hint — `cyan`, `blue`, `magenta`, `yellow`, `green`, `red`
- `tools` (string[] or comma-separated): tools available to the agent
- `skills` (string[]): skills loaded into context, format `plugin-name:skill-name`
- `allowed-tools` (string[]): alternative to `tools`

Agents can also embed inline hooks in frontmatter for `PreToolUse`/`PostToolUse` within their scope.

Body: system prompt defining mission, instructions, and output format. Best practice: include `<example>` blocks in description showing when/how to trigger.

## Skill Structure

Location: `skills/<skill-name>/SKILL.md` (or `skills/<plugin-name>/<skill-name>/SKILL.md`)

Required frontmatter:
- `name` (string): skill identifier
- `description` (string): when/why to use — acts as trigger for auto-loading

Optional frontmatter:
- `version` (string): semver
- `globs` (string or string[]): file patterns that scope this skill

Body: reference material. Keep under 500 lines for context efficiency.

Supporting files alongside SKILL.md:
- `references/` — detailed reference material
- `examples/` — working code examples
- `scripts/` — utility scripts

Skills in `commands/` directory work identically (legacy layout). Both are auto-discovered.

## Hook Events

Location: `hooks/hooks.json` (can have multiple files: `hooks.json`, `security-hooks.json`, etc.), inline in `plugin.json` hooks field, or inline in agent frontmatter.

Valid event types:
- `PreToolUse` — before a tool executes (can block via permission decision)
- `PostToolUse` — after a tool executes successfully
- `PostToolUseFailure` — after a tool execution fails
- `PermissionRequest` — when tool permission is needed
- `UserPromptSubmit` — when user sends a message
- `Stop` — when Claude stops responding
- `SubagentStop` — when a subagent completes
- `SessionStart` — when a session begins
- `SessionEnd` — when a session ends
- `PreCompact` — before context compression
- `Notification` — for notifications
- `InstructionsLoaded` — after CLAUDE.md files are loaded

**Note**: Event names are case-sensitive.

Hook types:
- `command` — run a shell command, receives JSON on stdin
- `prompt` — evaluate a prompt with the LLM
- `agent` — spawn an agentic verifier for complex verification tasks

Hook output (for `command` type blocking decisions):
```json
{
  "hookSpecificOutput": {
    "permissionDecision": "allow" | "deny",
    "permissionDecisionReason": "explanation"
  }
}
```

Matcher: regex pattern for tool name (e.g., `"Bash"`, `"Write|Edit"`, `"mcp__.*"`)

## hooks.json Format

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/format-code.sh"
          }
        ]
      }
    ]
  }
}
```

Multiple hook config files are supported in the `hooks/` directory.

## .mcp.json Format

```json
{
  "mcpServers": {
    "server-name": {
      "command": "executable",
      "args": ["arg1", "arg2"],
      "cwd": "${CLAUDE_PLUGIN_ROOT}",
      "env": { "KEY": "value" }
    }
  }
}
```

## marketplace.json Format

Per-plugin marketplace (for `claude plugin marketplace add`):

```json
{
  "name": "marketplace-name",
  "owner": { "name": "author-name" },
  "plugins": [
    {
      "name": "plugin-name",
      "source": { "source": "github", "repo": "owner/repo" },
      "description": "...",
      "version": "X.Y.Z",
      "author": { "name": "..." },
      "category": "developer-tools"
    }
  ]
}
```

`owner` with `name` is required for marketplace validation.

Source types: `github`, `git`, `url`, `npm`, `file`, `directory`, `hostPattern`

## Plugin Directory Layout

```
plugin-name/
├── .claude-plugin/
│   ├── plugin.json           # manifest (name required, rest optional)
│   └── marketplace.json      # optional
├── commands/                  # auto-discovered
│   ├── command-name.md
│   └── shared/               # non-invocable partials
│       └── partial-name.md
├── agents/                    # auto-discovered
│   └── agent-name.md
├── skills/                    # auto-discovered
│   └── skill-name/
│       ├── SKILL.md
│       ├── references/        # optional
│       ├── examples/          # optional
│       └── scripts/           # optional
├── hooks/                     # can have multiple .json files
│   ├── hooks.json
│   └── security-hooks.json   # additional hook configs
├── scripts/                   # utility scripts
├── settings.json              # default plugin settings (optional)
├── .mcp.json                  # optional MCP servers
├── .lsp.json                  # optional LSP servers
├── CLAUDE.md                  # project instructions
├── README.md
└── LICENSE
```

`${CLAUDE_PLUGIN_ROOT}` resolves to the plugin's root directory at runtime. Use it in all script paths for portability.

## Naming Conventions

- Plugin names: kebab-case (`reading-assistant`, `codex-toolkit`)
- Command files: kebab-case `.md` (`audit-plugin.md`)
- Agent files: kebab-case `.md` (`qc-coordinator.md`)
- Skill directories: `skill-name/SKILL.md` or `plugin-name/skill-name/SKILL.md`
- Script files: kebab-case with extension (`codex-preflight.sh`, `parse_epub.py`)

## Settings

- `settings.json` at plugin root — default settings shipped with the plugin
- `~/.claude/settings.json` — global user settings
- `{project}/.claude/settings.json` — project settings (committed)
- `{project}/.claude/settings.local.json` — local settings (gitignored)
- `.claude/<plugin-name>.local.md` — per-plugin config with YAML frontmatter

## CLAUDE.md

- Project-level instructions for Claude Code
- Supports `@` import syntax to reference other files
- Loaded from: project root, `.claude/`, `~/.claude/`, parent directories
- Priority: closer to project root wins
- `claudeMdExcludes` setting can ignore specific CLAUDE.md files

## Quality Standards

### Commands
- Description: specific and actionable
- Steps: numbered, unambiguous, all paths covered
- Tools: match `allowed-tools`, least-privilege
- Output: format defined (report template)
- Errors: fallback paths specified

### Agents
- Description: include `<example>` blocks for triggering
- Model: match task complexity (haiku mechanical, sonnet reasoning, opus judgment)
- Tools: least-privilege
- Body: mission, instructions, output format

### Skills
- Description: trigger phrases matching user queries
- Body: under 500 lines, patterns over theory
- Code examples: runnable, not pseudocode
- Scope: clear boundaries, cross-references to related skills

### Rules (.claude/rules/)
- YAML frontmatter: `description` (required), `paths` (optional glob array)
- Budget: <500 lines total across all rule files
- Format: bold imperative + rationale + positive framing
- Enforceable: testable, specific, observable
- No duplication of linter/formatter/CI enforcement
