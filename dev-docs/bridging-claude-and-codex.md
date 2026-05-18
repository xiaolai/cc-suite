# Bridging Claude Code and Codex CLI

A deep technical reference for `cc-bridge`: how Claude Code and Codex CLI represent shared concepts, where they align, where they diverge, and the exact mechanics for each bridge strategy.

Covers Claude Code, Codex CLI, and Gemini CLI (as a secondary target). Verified against primary sources as of May 2026.

---

## Table of Contents

1. [Compatibility at a glance](#1-compatibility-at-a-glance)
2. [AGENTS.md — the shared source of truth](#2-agentsmd--the-shared-source-of-truth)
3. [Skills bridge](#3-skills-bridge)
4. [Commands bridge (the hard gap)](#4-commands-bridge-the-hard-gap)
5. [Hooks bridge](#5-hooks-bridge)
6. [MCP bridge (the other hard gap)](#6-mcp-bridge-the-other-hard-gap)
7. [Rules — not bridgeable](#7-rules--not-bridgeable)
8. [Subagents / Agents](#8-subagents--agents)
9. [Plugins](#9-plugins)
10. [Codex trust model](#10-codex-trust-model)
11. [Gemini CLI specifics](#11-gemini-cli-specifics)
12. [Discovery paths reference](#12-discovery-paths-reference)
13. [Footguns and silent failures](#13-footguns-and-silent-failures)
14. [Prior art](#14-prior-art)
15. [Sources](#15-sources)

---

## 1. Compatibility at a glance

| Artifact | Claude Code | Codex CLI | Gemini CLI | Bridge strategy |
|---|---|---|---|---|
| Project instructions | `CLAUDE.md` | `AGENTS.md` | `GEMINI.md` | Thin `@AGENTS.md` import in both; AGENTS.md is the canonical source |
| Skills | `.claude/skills/<name>/SKILL.md` | `.agents/skills/<name>/SKILL.md` | `.agents/skills/<name>/SKILL.md` | Symlink `.agents/skills` → `.claude/skills` |
| Slash commands | `.claude/commands/<name>.md` | `~/.codex/prompts/<name>.md` (user-scope only) | `.gemini/commands/<name>.toml` | **No clean bridge.** Expose as Skills instead |
| Hooks | `.claude/settings.json` → `hooks` | `.codex/hooks.json` | Not supported | Mirror 5 shared events; skip 3 Claude-only |
| MCP servers | `.mcp.json` → `mcpServers` | `.codex/config.toml` → `[mcp_servers.*]` | Extension manifest | **No cross-read.** Must write both files |
| Rules | `.claude/rules/*.md` (prose) | `.codex/rules/*.rules` (Starlark exec-policy) | Not supported | **Not bridgeable.** Different concepts entirely |
| Subagents | `.claude/agents/*.md` | `[agents]` in `config.toml` + Skills | Not supported | Fold into Skills with explicit `$name` invocation |
| Plugins | `.claude-plugin/plugin.json` | `.codex-plugin/plugin.json` | Not supported | Separate manifests in same repo |

---

## 2. AGENTS.md — the shared source of truth

### What it is

`AGENTS.md` is an open cross-tool convention (spec: [agents.md](https://agents.md)) adopted by OpenAI (Codex), Google (Gemini), Cursor, Sourcegraph Amp, Factory, Aider, OpenCode, and others. It is plain Markdown with no required schema, placed at the project root or in subdirectories.

Claude Code does **not** read `AGENTS.md` natively. It reads `CLAUDE.md`. The bridge uses Claude's `@`-import syntax:

```markdown
@AGENTS.md
```

This single line in `CLAUDE.md` makes Claude inject the full content of `AGENTS.md` as context at session start. Codex reads `AGENTS.md` directly. Both tools see the same instructions.

### Multi-directory behavior (Codex)

Codex **concatenates** all `AGENTS.md` files it finds, scanning from `~/.codex/AGENTS.md` (global) down to the most-specific subdirectory. Closer files appear later in the combined prompt, so they effectively override earlier guidance through recency.

```
~/.codex/AGENTS.md                      → injected first (lowest priority)
<repo>/AGENTS.md                        → injected second
<repo>/services/api/AGENTS.md           → injected last (highest priority)
```

**`AGENTS.override.md`:** If present in any directory, it replaces `AGENTS.md` at that level only. The override does not suppress ancestor or descendant files. Use case: temporary worktree instructions without modifying the canonical file.

**Fallback filenames:** Codex can be configured to also scan `CLAUDE.md`, `.cursorrules`, etc., as fallbacks:

```toml
# ~/.codex/config.toml
project_doc_fallback_filenames = ["CLAUDE.md", ".cursorrules"]
```

This is an escape hatch for repos with substantive `CLAUDE.md` content that isn't ready to migrate to `AGENTS.md`.

### Byte cap

Codex silently truncates each document at `project_doc_max_bytes` (default: **32,768 bytes / 32 KiB**). There is no warning when this happens. `cc-bridge:status` should flag `AGENTS.md` files that exceed this limit.

### Recommended AGENTS.md structure

```markdown
# Project Instructions

> One-line project description.

## Build & Test

## Architecture

## Conventions

## Security

## Git Workflow

## Shared Memory

**Write new instructions, rules, and memory to `AGENTS.md` only.**
Never edit `CLAUDE.md` or `GEMINI.md` directly — they import from here.
```

---

## 3. Skills bridge

### Why skills are the most portable artifact

Skills use the same SKILL.md format across Codex and Gemini CLI, and Claude Code also reads the same format (from `.claude/skills/`). The scan paths differ by tool, but the file content is identical.

| Tool | Scans | User-scoped fallback |
|---|---|---|
| Claude Code | `.claude/skills/<name>/SKILL.md` | `~/.claude/skills/` |
| Codex CLI | `.agents/skills/<name>/SKILL.md` | `~/.agents/skills/` |
| Gemini CLI | `.agents/skills/<name>/SKILL.md` (priority) or `.gemini/skills/` | `~/.agents/skills/` or `~/.gemini/skills/` |

The bridge is a single symlink:

```bash
ln -s ../.claude/skills .agents/skills
```

This makes every Claude skill visible to Codex and Gemini CLI without duplication.

### SKILL.md format (portable across all three tools)

```markdown
---
name: skill-name
description: When this skill should and should not trigger. Be specific — this text
             is what the model uses to decide when to auto-invoke the skill.
---

## Instructions

Markdown body that becomes the skill's injected context.
```

Required frontmatter: `name`, `description`. Nothing else is required at the SKILL.md level.

### Codex-specific metadata (`agents/openai.yaml`)

For skills that ship as part of a Codex plugin (or need UI customization), place an `agents/openai.yaml` alongside `SKILL.md`:

```yaml
interface:
  display_name: "User-facing name in /skills menu"
  short_description: "One liner"
  icon_small: "./assets/small-logo.svg"   # recommended: 64×64 SVG
  icon_large: "./assets/large-logo.png"   # recommended: 512×512 PNG
  brand_color: "#3B82F6"
  default_prompt: "Surrounding prompt template shown in UI"

policy:
  allow_implicit_invocation: true   # false = user must type $skill-name explicitly

dependencies:
  tools:
    - type: "mcp"
      value: "serverName"
      description: "What this tool does"
      transport: "streamable_http"
      url: "https://example.com/mcp"
```

Claude Code ignores `agents/openai.yaml`; it only reads `SKILL.md`. This file is safe to include in bridged repos.

### Invocation — the UX divergence

| Tool | Explicit invocation | Implicit (auto) invocation |
|---|---|---|
| Claude Code | `/skill-name` slash command | Based on `description` match |
| Codex CLI | `$skill-name` in prompt | Based on `description` match (controlled by `allow_implicit_invocation`) |
| Gemini CLI | `/skills enable <name>`, then model auto-selects | Via internal `activate_skill` tool |

SKILL.md is portable. The invocation syntax is not. Document this in any user-facing instructions.

### Context budget (Codex)

Codex caps the total injected skill list at approximately **2% of the model's context window, or 8,000 characters when the window is unknown**. Repos with many skills should keep SKILL.md bodies concise.

### Scan order (Codex, most-specific wins)

1. `$CWD/.agents/skills/` (walked up to repo root)
2. `$REPO_ROOT/.agents/skills/`
3. `~/.agents/skills/`
4. `/etc/codex/skills/`
5. Built-in skills (`$plan`, `$skill-creator`, etc.)

---

## 4. Commands bridge (the hard gap)

### The fundamental mismatch

| Tool | Command path | Scope |
|---|---|---|
| Claude Code | `.claude/commands/<name>.md` | Project (per-repo, committed) |
| Codex CLI | `~/.codex/prompts/<name>.md` | **User-scope only** — not repo-scoped |
| Gemini CLI | `.gemini/commands/<name>.toml` | Project |

Codex **does not scan `<repo>/.codex/prompts/`** for slash commands. The `.codex/prompts/` scaffolding directory `cc-bridge:init` creates is for users to populate manually with their own personal prompts — Codex picks it up from there only if the user also has it mapped to their `$CODEX_HOME`. This limitation is by design; OpenAI explicitly recommends Skills over prompts for any repo-shareable workflow.

Custom prompts are also documented as **deprecated** in Codex. Do not build new workflows on them.

### Format details (for reference)

Claude Code command frontmatter:

```yaml
---
description: "What this command does"
argument-hint: "[--flag] [value]"
allowed-tools:
  - Bash
  - Read
---
```

Codex custom prompt frontmatter:

```yaml
---
description: "What this slash command does"
argument-hint: "[FILES=<paths>] [TITLE=<title>]"
---
```

Available body variables in Codex prompts: `$1`…`$9` (positional), `$ARGUMENTS` (all args), `$NAMED` (any uppercase name supplied as `KEY=value`). `$CWD`, `$GIT_ROOT`, and similar env-derived tokens are **not** documented — do not rely on them.

Both tools support `description` and `argument-hint` in frontmatter. The body variable syntax is similar but not identical.

### Recommended bridge strategy: expose as Skills

Since Skills are repo-scoped and survive clones, the correct Codex equivalent for a Claude command is a Skill with `allow_implicit_invocation: false`:

**Claude command (`.claude/commands/summarize-pr.md`):**

```markdown
---
description: Summarize the current PR diff in bullet points.
argument-hint: "[--short]"
allowed-tools:
  - Bash
---

Summarize the current git diff vs. main. If `--short` is in $ARGUMENTS, limit to 5 bullets.
```

**Codex skill equivalent (`.agents/skills/cmd-summarize-pr/SKILL.md`):**

```markdown
---
name: cmd-summarize-pr
description: Summarize the current PR diff in bullet points. Invoke explicitly with $cmd-summarize-pr.
---

Summarize the current git diff vs. main. If the user passes --short, limit to 5 bullets.
```

With `allow_implicit_invocation: false` in `agents/openai.yaml`, the skill only activates when the user types `$cmd-summarize-pr`. This replicates the explicit-invocation behavior of Claude slash commands.

A future `cc-bridge:bridge-commands` script could automate this conversion: read `.claude/commands/<name>.md`, strip Claude-specific frontmatter fields (`allowed-tools`), adapt the description, and emit `.agents/skills/cmd-<name>/SKILL.md`.

---

## 5. Hooks bridge

### Event coverage

| Event | Claude Code | Codex CLI | Bridgeable |
|---|---|---|---|
| `SessionStart` | ✓ | ✓ | Yes |
| `UserPromptSubmit` | ✓ | ✓ | Yes |
| `PreToolUse` | ✓ | ✓ | Yes |
| `PostToolUse` | ✓ | ✓ | Yes |
| `Stop` | ✓ | ✓ | Yes |
| `Notification` | ✓ | — | Claude-only |
| `SubagentStop` | ✓ | — | Claude-only |
| `SessionEnd` | ✓ | — | Claude-only |
| `PermissionRequest` | — | ✓ | Codex-only |

### Wire format (identical on both sides)

The hook envelope is the same JSON structure in both tools:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 .claude/hooks/pre_tool.py",
            "statusMessage": "Checking command...",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

The stdin/stdout contracts are also equivalent: stdin receives a JSON object with `session_id`, `cwd`, `hook_event_name`, `model`, `permission_mode`, plus event-specific fields (e.g. `tool_name`, `tool_input` for `PreToolUse`). Exit 0 = success; exit 2 + stderr = block. The same Python/Bash hook scripts run unmodified on both tools.

### What the bridge does

`bridge_hooks.py` reads `.claude/settings.json`, extracts the five shared events, and writes them to `.codex/hooks.json`. Claude-only events (`Notification`, `SubagentStop`, `SessionEnd`) are skipped with a printed notice. The Codex-only `PermissionRequest` event is not written (it has no Claude analog).

If `.codex/hooks.json` already exists, the output goes to `.codex/hooks.cc-bridge.json` for manual review — no silent overwrite.

### Trust and feature-flag gates

Project hooks in `.codex/hooks.json` **only fire if the project is trusted** (see §10). They also require the user to have `[features] plugin_hooks = true` in `~/.codex/config.toml` if the hooks were shipped as part of a plugin. On a fresh clone, both conditions may be false, causing bridged hooks to silently no-op. `cc-bridge:status` should detect and warn on both.

---

## 6. MCP bridge (the other hard gap)

### The fundamental mismatch

| Tool | MCP config location | Format |
|---|---|---|
| Claude Code | `.mcp.json` → `mcpServers` | JSON |
| Codex CLI | `.codex/config.toml` → `[mcp_servers.<id>]` | TOML |
| Gemini CLI | Extension manifest | JSON |

**Codex does not read `.mcp.json`.** Claude Code does not read `.codex/config.toml`. Neither tool provides cross-read. Any project-level MCP server must be declared in both files to be available to both tools.

### Claude Code `.mcp.json` format

```json
{
  "mcpServers": {
    "server-name": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "package-name"]
    }
  }
}
```

### Codex CLI `.codex/config.toml` format

**Stdio server:**

```toml
[mcp_servers.server-name]
command = "npx"
args = ["-y", "package-name"]
startup_timeout_sec = 10
enabled = true

[mcp_servers.server-name.env]
API_KEY = "..."
```

**Streamable HTTP server:**

```toml
[mcp_servers.remote-api]
url = "https://api.example.com/mcp"
bearer_token_env_var = "REMOTE_API_TOKEN"
http_headers = { "X-Tenant" = "acme" }
enabled_tools = ["search", "read"]
```

**All optional fields:**

| Field | Type | Default | Purpose |
|---|---|---|---|
| `enabled` | bool | `true` | Toggle without removing |
| `required` | bool | `false` | Fail startup if unavailable |
| `startup_timeout_sec` | int | `10` | How long to wait for server ready |
| `tool_timeout_sec` | int | `60` | Per-tool call timeout |
| `enabled_tools` | string[] | — | Allowlist specific tools |
| `disabled_tools` | string[] | — | Denylist specific tools |
| `cwd` | string | — | Working directory for stdio |
| `env_vars` | array | — | Pass-through env var names |

SSE transport is **not documented** by Codex; do not use it.

### Recommended bridge strategy

The current `mcp_codex.sh` writes to `.mcp.json` only, exposing Codex-as-MCP to Claude Code. The reverse direction is missing: if a project has MCP servers in `.mcp.json`, they are invisible to Codex.

The complete bridge requires a second script (`bridge_mcp.sh` or extending `mcp_codex.sh`) that:

1. Reads `.mcp.json` → `mcpServers`
2. For each entry, emits a `[mcp_servers.<id>]` block in `.codex/config.toml`
3. Uses idempotent sentinel markers so re-runs don't duplicate entries
4. Skips entries that already exist in `config.toml`
5. Warns about fields that have no TOML equivalent (e.g. complex `env` objects)

Note: `.codex/config.toml` only loads when the project is trusted (see §10). MCP servers declared there are silently unavailable on untrusted projects.

---

## 7. Rules — not bridgeable

### What each tool means by "rules"

**Claude Code** `.claude/rules/*.md` — prose Markdown injected as context. Authoring guidance: conventions, style preferences, workflow expectations. Read at session start, treated as standing instructions.

**Codex CLI** `.codex/rules/*.rules` — Starlark (Python-subset) exec-policy files. Machine-parsed, not LLM-read. They govern what shell commands the agent is allowed to run, prompt the user about, or block entirely:

```python
# .codex/rules/project.rules
prefix_rule(
    pattern=["rm -rf", "sudo"],
    decision="forbidden",
    justification="Destructive commands require manual execution",
)

prefix_rule(
    pattern=["git push"],
    decision="prompt",
    justification="Confirm before pushing to remote",
)
```

Validated with: `codex execpolicy check --pretty`

These are semantically incompatible. Claude rules express intent to an LLM; Codex rules constrain a command executor at the OS level. Attempting to auto-convert one to the other would produce either meaningless exec-policy or prose that doesn't reflect actual constraints.

**The right approach:** Put shared authoring guidance in `AGENTS.md`. Write tool-specific `exec-policy` rules manually in `.codex/rules/` to match whatever safety constraints apply to the project.

---

## 8. Subagents / Agents

### Claude Code subagents

Defined as `.claude/agents/<name>.md` — Markdown files with YAML frontmatter (similar to skills) that describe a specialized agent with its own system prompt, tool permissions, and context constraints. Invoked by the orchestrator agent when a task matches the subagent's description.

### Codex CLI agents (subagents)

Defined in `config.toml` under `[agents.<name>]`:

```toml
[agents.reviewer]
description = "Performs code review on staged changes"
developer_instructions = "Focus on security and test coverage"
nickname_candidates = ["review", "check"]
model = "o3"
sandbox_mode = "strict"
skills = { config = ".codex/reviewer-skills.toml" }
mcp_servers = ["context7"]

[agents]
max_threads = 6          # parallel agents (default 6)
max_depth = 1            # nesting depth (default 1)
job_max_runtime_seconds = 600
```

Subagent invocation in Codex: `/mention @reviewer` or via the `mention` feature in chat.

### Bridge strategy

There is no 1:1 mapping. The closest approximation:

1. For simple subagents (defined by description + instructions), create a Skill with `allow_implicit_invocation: false` and detailed instructions. The user invokes with `$agent-name`.
2. For subagents that need their own model, tool set, or sandbox mode, write a `[agents.<name>]` stanza manually in `.codex/config.toml`. No automation is appropriate here — these carry security-relevant settings.

Do not try to auto-convert `.claude/agents/*.md` to `[agents.*]` TOML. The semantic gap is too wide for mechanical conversion to be safe.

---

## 9. Plugins

### The two-manifest pattern

Both tools have independent plugin systems. The same repository can ship both:

```
plugin-repo/
├── .claude-plugin/
│   └── plugin.json          # Claude Code plugin manifest
├── .codex-plugin/
│   └── plugin.json          # Codex plugin manifest
├── commands/                # Claude commands
├── skills/                  # Shared skills (both tools)
├── codex/                   # Codex-specific artifacts
│   └── skills/
└── scripts/                 # Implementation scripts
```

### Claude plugin manifest (`.claude-plugin/plugin.json`)

Required: `name`, `version`, `description`.

Skills, commands, agents, hooks, and rules are discovered by path convention — no explicit pointers needed in the manifest.

### Codex plugin manifest (`.codex-plugin/plugin.json`)

Required: `name` (kebab-case), `version` (semver), `description`.

Supports explicit component pointers:

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "What this plugin does",
  "skills": "./skills/",
  "hooks": "./hooks/hooks.json",
  "mcpServers": "./.mcp.json",
  "interface": {
    "display_name": "My Plugin",
    "short_description": "...",
    "brand_color": "#3B82F6",
    "icon_small": "./assets/small.svg",
    "default_prompt": "Run $my-plugin to..."
  }
}
```

**Plugin hooks gate:** Hooks bundled in a Codex plugin only fire if `[features] plugin_hooks = true` is set in the user's `~/.codex/config.toml`. This is off by default. Plugins that rely on hooks must document this requirement.

---

## 10. Codex trust model

### What trust controls

When Codex opens a new working directory, it checks whether the directory is "trusted." If not trusted, the following project-scoped layers are **silently skipped**:

- `.codex/config.toml` (project)
- `.codex/hooks.json` (project hooks)
- `.codex/rules/` (exec-policy)
- MCP servers declared in `.codex/config.toml`

Skills under `.agents/skills/` are **not** gated by trust — they are deliberately on the neutral path, outside `.codex/`. This is the primary reason the symlink bridge is robust: skills work on an untrusted project; hooks and MCP do not.

### How trust state is stored

In the user-level config file `~/.codex/config.toml`, under a `[projects.<absolute-path>]` table:

```toml
[projects."/Users/alice/projects/my-repo"]
trust_level = "trusted"
```

### How a project becomes trusted

1. **Interactive prompt** — Codex asks on first run in a new directory. The user must accept.
2. **Manual pre-trust** — add the `[projects."<path>"] trust_level = "trusted"` stanza to `~/.codex/config.toml` before launching. There is no `codex trust <path>` CLI subcommand (as of May 2026).

### Practical implications for cc-bridge

- `cc-bridge:init` creates `.codex/hooks.json` and `.codex/config.toml` artifacts, but they will be inert until the project is trusted.
- On a fresh clone, a collaborator must trust the project before hooks and MCP fire.
- `cc-bridge:status` should detect the trust state and warn when hooks/MCP would be silently inert.
- Skills are the only bridge artifact that works on day one without trust.

---

## 11. Gemini CLI specifics

### How Gemini reads shared instructions

Gemini CLI reads `GEMINI.md`, not `AGENTS.md`. Two ways to make it consume `AGENTS.md`:

**Option A (cc-bridge default): `@`-import in GEMINI.md**

```markdown
@AGENTS.md
```

The `@file.md` import syntax is depth-capped at 5 levels, circular-import-safe, and works for `.md` files only. Non-`.md` imports emit a `[WARN] [ImportProcessor]` and silently fail.

**Option B: configure `context.fileName`**

In `~/.gemini/settings.json`:

```json
{
  "context": {
    "fileName": ["AGENTS.md", "GEMINI.md"]
  }
}
```

With this, Gemini CLI scans for `AGENTS.md` directly, in the same hierarchical locations it would scan `GEMINI.md`. This is more robust than the import approach for repos where the root `GEMINI.md` might be replaced.

### Gemini CLI skills

Gemini scans `.agents/skills/` with higher priority than `.gemini/skills/`:

| Priority | User scope | Project scope |
|---|---|---|
| Higher | `~/.agents/skills/` | `.agents/skills/` |
| Lower | `~/.gemini/skills/` | `.gemini/skills/` |

The `.agents/skills/` symlink created by `cc-bridge:bridge-skills` makes Claude skills visible to Gemini CLI automatically.

### Gemini commands

Gemini CLI commands use a TOML format (`.gemini/commands/<name>.toml`), not Markdown. They have no counterpart in Claude Code or Codex. Write them independently if needed.

### Gemini skill invocation

Unlike Codex (`$skill-name`), Gemini uses `/skills enable <name>` to activate a skill for a session, then the model auto-invokes it. There is no `$`-prefix syntax. SKILL.md is portable; the invocation is not.

---

## 12. Discovery paths reference

### Claude Code

| Artifact | Path |
|---|---|
| Project instructions | `CLAUDE.md` (root + subdirs), `@`-imports within |
| Skills | `.claude/skills/<name>/SKILL.md` |
| Commands | `.claude/commands/<name>.md` |
| Agents | `.claude/agents/<name>.md` |
| Rules | `.claude/rules/<name>.md` |
| Hooks | `.claude/settings.json` → `hooks` |
| MCP servers | `.mcp.json` → `mcpServers` |
| Plugins | `.claude-plugin/plugin.json` |
| User settings | `~/.claude/settings.json` |

### Codex CLI

| Artifact | Path | Scope |
|---|---|---|
| Project instructions | `AGENTS.md` (walked root→cwd, concatenated) | Project + User (`~/.codex/AGENTS.md`) |
| Skills | `.agents/skills/<name>/SKILL.md` (walked) | Project + User + System |
| Slash commands | `~/.codex/prompts/<name>.md` | User-scope only |
| Exec-policy rules | `.codex/rules/*.rules` | Project (trust-gated) + User |
| Hooks | `.codex/hooks.json` | Project (trust-gated) + User |
| MCP servers | `.codex/config.toml` → `[mcp_servers.*]` | Project (trust-gated) + User |
| Subagents | `.codex/config.toml` → `[agents.*]` | Project (trust-gated) |
| Config | `~/.codex/config.toml`, `.codex/config.toml` | Merged; project trust-gated |
| Plugins | `.codex-plugin/plugin.json` | Plugin root |

### Gemini CLI

| Artifact | Path | Scope |
|---|---|---|
| Project instructions | `GEMINI.md` (or `@AGENTS.md` import) | Project + User (`~/.gemini/GEMINI.md`) |
| Skills | `.agents/skills/` (priority) or `.gemini/skills/` | Project + User |
| Commands | `.gemini/commands/<name>.toml` | Project |
| Config | `~/.gemini/settings.json` | User |

---

## 13. Footguns and silent failures

These are the most common ways the bridge appears to work but doesn't.

### 1. Untrusted project — hooks and MCP are inert

**Symptom:** Hooks defined in `.codex/hooks.json` never fire on a fresh clone. MCP servers in `.codex/config.toml` are unavailable.

**Cause:** Project is not trusted in `~/.codex/config.toml`.

**Detection:** Check `~/.codex/config.toml` for `[projects."<abs-path>"] trust_level = "trusted"`.

**Fix:** Either let Codex prompt you on first run, or manually add the stanza.

### 2. Plugin hooks silently disabled

**Symptom:** Hooks bundled in a Codex plugin never fire, even in a trusted project.

**Cause:** `[features] plugin_hooks = true` is not set in `~/.codex/config.toml`.

**Fix:**

```toml
# ~/.codex/config.toml
[features]
plugin_hooks = true
```

### 3. AGENTS.md silently truncated

**Symptom:** Instructions near the end of `AGENTS.md` are ignored by Codex; the model behaves as if it didn't read them.

**Cause:** File exceeds `project_doc_max_bytes` (default 32 KiB). No warning is emitted.

**Detection:** `wc -c AGENTS.md` — flag if > 32768.

**Fix:** Split into root `AGENTS.md` + subdirectory-specific `AGENTS.md` files, or increase the limit:

```toml
# ~/.codex/config.toml
project_doc_max_bytes = 65536
```

### 4. `.codex/prompts/` is not a project-scope command directory

**Symptom:** Markdown files placed in `<repo>/.codex/prompts/` never become Codex slash commands.

**Cause:** Codex only scans `~/.codex/prompts/` for custom prompts. The project-level directory is scaffolded for future use or for users to symlink, but Codex itself does not discover it.

**Fix:** Use Skills instead (see §4).

### 5. `.mcp.json` invisible to Codex

**Symptom:** MCP servers available to Claude Code are not available to Codex in the same repo.

**Cause:** Codex reads `[mcp_servers.*]` in `config.toml`, not `.mcp.json`.

**Fix:** Mirror `.mcp.json` entries into `.codex/config.toml` manually or via a bridge script.

### 6. Gemini `@import` on non-`.md` files fails silently

**Symptom:** Gemini CLI GEMINI.md imports a `.sh` or `.json` file; content is never injected.

**Cause:** Gemini's `@`-import only processes `.md` files. Non-`.md` imports emit a warning but do not fail visibly.

**Fix:** Only use `@`-import with `.md` targets.

### 7. `CLAUDE.md` has substantive content but AGENTS.md is also present

**Symptom:** After running `cc-bridge:init`, Claude Code only sees `AGENTS.md` content; custom CLAUDE.md content is lost.

**Cause:** `init.sh` only migrates CLAUDE.md → AGENTS.md if it detects that the CLAUDE.md content matches what it would have put in AGENTS.md. Unique CLAUDE.md content is left alone with a warning.

**Fix:** Manually merge unique CLAUDE.md content into AGENTS.md, then replace CLAUDE.md with `@AGENTS.md`.

---

## 14. Prior art

These projects occupy adjacent niches but do not bridge the repo configuration surface the way `cc-bridge` does.

| Project | Direction | What it does |
|---|---|---|
| [`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc) | Claude Code → Codex | Claude Code plugin that delegates review/rescue tasks to Codex via tool call |
| [`sendbird/cc-plugin-codex`](https://github.com/sendbird/cc-plugin-codex) | Codex → Claude Code | Codex plugin that launches Claude Code for specific tasks |
| [`ProAlexUSC/cc-plugin-to-codex`](https://github.com/ProAlexUSC/cc-plugin-to-codex) | One-time port | Converts entire Claude Code marketplace plugins to Codex format; not a live sync |
| [`SeemSeam/claude_code_bridge`](https://github.com/bfly123/claude_code_bridge) | Multi-agent orchestration | tmux supervisor for running Claude/Codex/Gemini/OpenCode as named peers |

`cc-bridge`'s distinct contribution: it bridges the **repo configuration surface itself** — both tools cooperate on the same workspace files without one delegating to the other.

---

## 15. Sources

Primary sources verified May 2026:

- [Codex: Custom instructions with AGENTS.md](https://developers.openai.com/codex/guides/agents-md)
- [Codex: Config basic](https://developers.openai.com/codex/config-basic)
- [Codex: Config advanced](https://developers.openai.com/codex/config-advanced)
- [Codex: Config reference](https://developers.openai.com/codex/config-reference)
- [Codex: MCP](https://developers.openai.com/codex/mcp)
- [Codex: Skills](https://developers.openai.com/codex/skills)
- [Codex: Subagents](https://developers.openai.com/codex/subagents)
- [Codex: Custom prompts](https://developers.openai.com/codex/custom-prompts)
- [Codex: Hooks](https://developers.openai.com/codex/hooks)
- [Codex: Plugins](https://developers.openai.com/codex/plugins)
- [Codex: Rules (execpolicy)](https://github.com/openai/codex/blob/main/codex-rs/execpolicy/README.md)
- [Codex CLI reference](https://developers.openai.com/codex/cli/reference)
- [openai/codex issue #10389 — trust prompt](https://github.com/openai/codex/issues/10389)
- [AGENTS.md open spec](https://agents.md/)
- [agentsmd/agents.md](https://github.com/agentsmd/agents.md)
- [Gemini CLI: GEMINI.md docs](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/gemini-md.md)
- [Gemini CLI: Skills](https://geminicli.com/docs/cli/skills/)
- [gemini-cli discussion #1471 — AGENTS.md](https://github.com/google-gemini/gemini-cli/discussions/1471)
- [gemini-cli issue #2983 — .md-only imports](https://github.com/google-gemini/gemini-cli/issues/2983)
